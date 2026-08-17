`include "pnm_defs.vh"

// =============================================================================
// kv_cache_bank — Per-direction KV cache bank (Paper §2.6, §3.3)
//
// Attached between the xyz_repeater's NoB output and the first xy_turn gate.
// Each layer has 4 banks (one per board direction: X+, X-, Y+, Y-) to provide
// distributed KV storage with low-latency access from the fabric.
//
// The bank snoops all incoming traffic on the NoB link.  When a flit carries
// a KV_STORE command (CTRL opcode = 2'b10), the bank captures the Key and
// Value tensors into its SRAM.  When a KV_LOAD command arrives, the bank
// injects the cached KV data back onto the NoB link.
//
// When the bank is full, it asserts kv_full and the offload controller
// (kv_offload.v) evicts the oldest entries back to the host via the spine.
//
// Wire interface: transparent pass-through with sideband snooping/injection.
// The bank adds 0 or 1 cycles of latency depending on whether it injects.
// =============================================================================
module kv_cache_bank #(
    parameter BANK_DEPTH   = 1024,   // number of KV entries (seq positions)
    parameter ENTRY_BYTES  = 512,    // bytes per KV entry (2 * hidden_size * dtype)
    parameter ADDR_BITS    = 10,     // log2(BANK_DEPTH)
    parameter PIPE_STAGES  = 2       // SRAM read latency
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- NoB pass-through (from xyz_repeater to first xy_turn) -----------
    input  wire [7:0]  nob_in_data,
    input  wire        nob_in_valid,
    input  wire        nob_in_sop,
    input  wire        nob_in_eop,
    output wire        nob_in_ready,
    input  wire [1:0]  nob_in_vc,

    output wire [7:0]  nob_out_data,
    output wire        nob_out_valid,
    output wire        nob_out_sop,
    output wire        nob_out_eop,
    input  wire        nob_out_ready,
    output wire [1:0]  nob_out_vc,

    // -- KV store/load sideband (from PE tile) --------------------------
    // Store: PE writes K/V data into the bank
    input  wire [7:0]  kv_store_data,
    input  wire        kv_store_valid,
    input  wire        kv_store_sop,
    input  wire        kv_store_eop,
    output wire        kv_store_ready,

    // Load: bank reads K/V data back to PE
    output wire [7:0]  kv_load_data,
    output wire        kv_load_valid,
    output wire        kv_load_sop,
    output wire        kv_load_eop,
    input  wire        kv_load_ready,

    // -- Offload interface (to kv_offload.v) ----------------------------
    output wire        kv_full,        // bank cannot accept more entries
    output wire        kv_empty,       // bank has no valid entries
    output wire [ADDR_BITS-1:0] kv_occupancy, // entries currently stored
    input  wire        evict_req,      // offload controller requests eviction
    input  wire [ADDR_BITS-1:0] evict_addr,   // address to evict
    output wire        evict_done,     // eviction complete (pulse)
    output wire [7:0]  evict_data,     // evicted data stream
    output wire        evict_valid,
    input  wire        evict_ready,

    // -- Reclaim interface (from offload controller) ---------------------
    input  wire        reclaim_req,    // host re-injects evicted entry
    input  wire [7:0]  reclaim_data,
    input  wire        reclaim_valid,
    input  wire        reclaim_sop,
    input  wire        reclaim_eop,
    output wire        reclaim_ready
);

    // =========================================================================
    // KV cache command opcodes (in the CTRL field rsvd bits)
    // =========================================================================
    localparam KV_OP_NONE   = 2'b00;  // normal traffic, pass through
    localparam KV_OP_STORE  = 2'b10;  // store K/V entry into bank
    localparam KV_OP_LOAD   = 2'b11;  // load K/V entry from bank

    // =========================================================================
    // Internal state
    // =========================================================================
    reg [ADDR_BITS-1:0] write_ptr;    // next write address
    reg [ADDR_BITS-1:0] read_ptr;     // next read address
    reg [ADDR_BITS-1:0] occupancy;    // entries currently stored
    reg                  full_r;
    reg                  empty_r;

    assign kv_full  = full_r;
    assign kv_empty = empty_r;
    assign kv_occupancy = occupancy;

    // =========================================================================
    // KV store SRAM (simplified: byte-addressed for flexibility)
    // In production, this would be LPDDR6 CAMM2 or on-chip SRAM
    // =========================================================================
    reg [7:0] kv_sram [0:BANK_DEPTH*ENTRY_BYTES-1];

    // =========================================================================
    // Command detection: inspect CTRL field on SOP byte
    // Wire format: LAYER_ID | MODULE_ID | CTRL | ...
    // The KV op is encoded in CTRL[1:0] (rsvd bits)
    // =========================================================================
    wire [1:0] kv_op_in = nob_in_data[1:0]; // CTRL byte, bits [1:0]
    wire       is_kv_store = nob_in_valid && nob_in_sop && (kv_op_in == KV_OP_STORE);
    wire       is_kv_load  = nob_in_valid && nob_in_sop && (kv_op_in == KV_OP_LOAD);

    // =========================================================================
    // Pass-through logic: KV flits are consumed (not forwarded);
    // normal flits pass through with 1-cycle latency (pipeline register)
    // =========================================================================
    reg        pt_valid;
    reg        pt_sop;
    reg        pt_eop;
    reg [7:0]  pt_data;
    reg [1:0]  pt_vc;
    reg        pt_active;  // currently passing through a non-KV flit

    // KV load injection: when the bank injects, it overrides the pass-through
    wire kv_injecting = (kl_state != KL_IDLE);
    assign nob_out_data  = kv_injecting ? kl_out_data  : pt_data;
    assign nob_out_valid = kv_injecting ? kl_out_valid : pt_valid;
    assign nob_out_sop   = kv_injecting ? kl_out_sop   : pt_sop;
    assign nob_out_eop   = kv_injecting ? kl_out_eop   : pt_eop;
    assign nob_out_vc    = kv_injecting ? 2'b11        : pt_vc;

    // Accept when pipeline slot is free or consumer is ready
    assign nob_in_ready = (nob_out_ready || !pt_valid) && !is_kv_store && !is_kv_load;

    // =========================================================================
    // KV store FSM: captures incoming KV data into SRAM
    // =========================================================================
    localparam KS_IDLE   = 2'd0;
    localparam KS_HEADER = 2'd1;  // consume header (DEST, CTRL, LEN)
    localparam KS_DATA   = 2'd2;  // capture payload into SRAM

    reg [1:0]  ks_state;
    reg [15:0] ks_len;
    reg [15:0] ks_pos;
    reg [ADDR_BITS-1:0] ks_addr;

    // =========================================================================
    // KV load FSM: reads SRAM and injects onto the NoB link
    // =========================================================================
    localparam KL_IDLE   = 2'd0;
    localparam KL_HEADER = 2'd1;  // emit header
    localparam KL_DATA   = 2'd2;  // emit SRAM data

    reg [1:0]  kl_state;
    reg [15:0] kl_len;
    reg [15:0] kl_pos;
    reg [ADDR_BITS-1:0] kl_addr;
    reg [7:0]  kl_out_data;
    reg        kl_out_valid;
    reg        kl_out_sop;
    reg        kl_out_eop;

    // KV load injection: when the bank injects, it overrides the pass-through
    wire kv_injecting = (kl_state != KL_IDLE);
    assign nob_out_data  = kv_injecting ? kl_out_data  : pt_data;
    assign nob_out_valid = kv_injecting ? kl_out_valid : pt_valid;
    assign nob_out_sop   = kv_injecting ? kl_out_sop   : pt_sop;
    assign nob_out_eop   = kv_injecting ? kl_out_eop   : pt_eop;

    // KV load data from SRAM
    reg [7:0]  kv_load_sram_data;
    reg        kv_load_sram_valid;
    reg        kv_load_sram_sop;
    reg        kv_load_sram_eop;

    assign kv_load_data  = kv_load_sram_data;
    assign kv_load_valid = kv_load_sram_valid;
    assign kv_load_sop   = kv_load_sram_sop;
    assign kv_load_eop   = kv_load_sram_eop;

    // KV store input
    assign kv_store_ready = (ks_state == KS_DATA);

    // =========================================================================
    // Eviction interface
    // =========================================================================
    reg        evict_done_r;
    reg [7:0]  evict_data_r;
    reg        evict_valid_r;

    assign evict_done  = evict_done_r;
    assign evict_data  = evict_data_r;
    assign evict_valid = evict_valid_r;

    // Reclaim input
    assign reclaim_ready = (ks_state == KS_IDLE);

    // =========================================================================
    // Main pipeline and KV logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr   <= 0;
            read_ptr    <= 0;
            occupancy   <= 0;
            full_r      <= 0;
            empty_r     <= 1;

            pt_valid    <= 0;
            pt_sop      <= 0;
            pt_eop      <= 0;
            pt_data     <= 0;
            pt_vc       <= 0;
            pt_active   <= 0;

            ks_state    <= KS_IDLE;
            ks_len      <= 0;
            ks_pos      <= 0;
            ks_addr     <= 0;

            kl_state    <= KL_IDLE;
            kl_len      <= 0;
            kl_pos      <= 0;
            kl_addr     <= 0;
            kl_out_data  <= 0;
            kl_out_valid <= 0;
            kl_out_sop   <= 0;
            kl_out_eop   <= 0;

            kv_load_sram_data  <= 0;
            kv_load_sram_valid <= 0;
            kv_load_sram_sop   <= 0;
            kv_load_sram_eop   <= 0;

            evict_done_r  <= 0;
            evict_data_r  <= 0;
            evict_valid_r <= 0;
        end else begin
            // Defaults
            pt_valid     <= 0;
            pt_sop       <= 0;
            pt_eop       <= 0;
            kv_load_sram_valid <= 0;
            kv_load_sram_sop   <= 0;
            kv_load_sram_eop   <= 0;
            evict_done_r  <= 0;
            evict_valid_r <= 0;

            // =================================================================
            // Pass-through pipeline: 1-cycle register for normal flits
            // =================================================================
            if (!kv_injecting && (nob_out_ready || !pt_valid)) begin
                if (nob_in_valid && nob_in_ready) begin
                    pt_data   <= nob_in_data;
                    pt_valid  <= 1;
                    pt_sop    <= nob_in_sop;
                    pt_eop    <= nob_in_eop;
                    pt_vc     <= nob_in_vc;
                    pt_active <= 1;
                end else begin
                    pt_valid  <= 0;
                    pt_active <= 0;
                end
            end

            // =================================================================
            // KV store FSM: capture KV data into SRAM
            // =================================================================
            case (ks_state)
                KS_IDLE: begin
                    if (is_kv_store && !full_r) begin
                        ks_state <= KS_HEADER;
                        ks_pos   <= 0;
                        ks_addr  <= write_ptr * ENTRY_BYTES;
                        // Consume the SOP byte (it's the CTRL byte)
                        ks_len   <= {nob_in_data, 8'h00}; // placeholder len
                    end
                    // Also accept reclaim requests
                    if (reclaim_req && reclaim_valid && !full_r) begin
                        ks_state <= KS_DATA;
                        ks_pos   <= 0;
                        ks_addr  <= write_ptr * ENTRY_BYTES;
                        ks_len   <= ENTRY_BYTES[15:0];
                    end
                end

                KS_HEADER: begin
                    // Consume DEST, CTRL, LEN bytes (3 bytes after SOP)
                    if (nob_in_valid && nob_in_ready) begin
                        ks_pos <= ks_pos + 1;
                        if (ks_pos == 2) begin
                            ks_len <= {8'h00, nob_in_data}; // LEN_LO
                            ks_state <= KS_DATA;
                            ks_pos <= 0;
                        end
                    end
                end

                KS_DATA: begin
                    // Capture payload bytes into SRAM
                    if ((kv_store_valid && kv_store_ready) ||
                        (reclaim_valid && reclaim_ready)) begin
                        reg [7:0] inj_data;
                        if (reclaim_valid && reclaim_ready)
                            inj_data = reclaim_data;
                        else
                            inj_data = kv_store_data;

                        if (ks_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kv_sram[ks_addr] <= inj_data;
                            ks_addr <= ks_addr + 1;
                        end

                        if ((reclaim_valid && reclaim_ready && reclaim_eop) ||
                            (kv_store_valid && kv_store_ready && kv_store_eop)) begin
                            // Entry complete
                            write_ptr <= (write_ptr == BANK_DEPTH-1) ? 0 : write_ptr + 1;
                            occupancy <= occupancy + 1;
                            full_r    <= (occupancy == BANK_DEPTH-2);
                            empty_r   <= 0;
                            ks_state  <= KS_IDLE;
                        end
                    end
                end

                default: ks_state <= KS_IDLE;
            endcase

            // =================================================================
            // KV load FSM: read SRAM and inject onto NoB link
            // =================================================================
            case (kl_state)
                KL_IDLE: begin
                    if (is_kv_load && !empty_r) begin
                        kl_state <= KL_HEADER;
                        kl_pos   <= 0;
                        kl_addr  <= read_ptr * ENTRY_BYTES;
                        kl_len   <= ENTRY_BYTES[15:0];
                        // Emit header: DEST (0xEE = requester), CTRL, LEN
                        kl_out_data  <= 8'hEE; // REQ_MODULE
                        kl_out_valid <= 1;
                        kl_out_sop   <= 1;
                        kl_out_eop   <= 0;
                    end
                    // Also support eviction reads
                    if (evict_req && !empty_r) begin
                        kl_state  <= KL_DATA;
                        kl_pos    <= 0;
                        kl_addr   <= evict_addr * ENTRY_BYTES;
                        kl_len    <= ENTRY_BYTES[15:0];
                        // Eviction data goes to offload controller, not NoB
                    end
                end

                KL_HEADER: begin
                    // Emit CTRL and LEN bytes
                    if (nob_out_ready) begin
                        kl_pos <= kl_pos + 1;
                        case (kl_pos)
                            0: begin kl_out_data <= 8'h80; kl_out_sop <= 0; end  // CTRL
                            1: begin kl_out_data <= kl_len[7:0];  end  // LEN_LO
                            2: begin kl_out_data <= kl_len[15:8]; end  // LEN_HI
                        endcase
                        if (kl_pos == 2) begin
                            kl_state <= KL_DATA;
                            kl_pos   <= 0;
                        end
                    end
                end

                KL_DATA: begin
                    // Read SRAM and emit payload
                    if (nob_out_ready || evict_ready) begin
                        if (kl_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kv_load_sram_data  <= kv_sram[kl_addr];
                            kv_load_sram_valid <= 1;
                            evict_data_r       <= kv_sram[kl_addr];
                            evict_valid_r      <= 1;
                            kl_addr <= kl_addr + 1;
                            kl_pos  <= kl_pos + 1;
                        end

                        if (kl_pos == kl_len - 1) begin
                            // Entry complete: emit CRC placeholder and finish
                            kv_load_sram_eop <= 1;
                            kl_out_eop       <= 1;
                            kl_out_valid     <= 1;
                            kl_out_data      <= 8'h00; // CRC_HI placeholder

                            read_ptr <= (read_ptr == BANK_DEPTH-1) ? 0 : read_ptr + 1;
                            occupancy <= occupancy - 1;
                            full_r    <= 0;
                            empty_r   <= (occupancy <= 1);
                            kl_state  <= KL_IDLE;
                            evict_done_r <= evict_req;
                        end
                    end
                end

                default: kl_state <= KL_IDLE;
            endcase

            // =================================================================
            // Occupancy tracking
            // =================================================================
            if (write_ptr == read_ptr && ks_state == KS_IDLE && kl_state == KL_IDLE) begin
                if (occupancy > 0 && kl_state == KL_IDLE)
                    empty_r <= 0;
            end
        end
    end

endmodule
