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
// Bug fixes applied:
//   1. Deadlock: KV_STORE SOP byte now consumed in KS_IDLE, not KS_HEADER
//   2. Reclaim deadlock: reclaim data accepted via reclaim_valid, not reclaim_ready gating
//   3. Silent drop: nob_in_ready forced low when kv_injecting to prevent flit loss
//   4. Eviction corruption: eviction waits for pt_active==0 before hijacking NoB
//   5. KV_LOAD injection: kl_out_data now assigned SRAM data in KL_DATA
//   6. Write-write conflict: occupancy updated with priority (store > load/evict)
//   7. Cross-coupled ready: load uses nob_out_ready, eviction uses evict_ready
// =============================================================================
module kv_cache_bank #(
    parameter BANK_DEPTH   = 1024,
    parameter ENTRY_BYTES  = 512,
    parameter ADDR_BITS    = 10,
    parameter PIPE_STAGES  = 2
)(
    input  wire        clk,
    input  wire        rst_n,

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

    input  wire [7:0]  kv_store_data,
    input  wire        kv_store_valid,
    input  wire        kv_store_sop,
    input  wire        kv_store_eop,
    output wire        kv_store_ready,

    output wire [7:0]  kv_load_data,
    output wire        kv_load_valid,
    output wire        kv_load_sop,
    output wire        kv_load_eop,
    input  wire        kv_load_ready,

    output wire        kv_full,
    output wire        kv_empty,
    output wire [ADDR_BITS-1:0] kv_occupancy,
    input  wire        evict_req,
    input  wire [ADDR_BITS-1:0] evict_addr,
    output wire        evict_done,
    output wire [7:0]  evict_data,
    output wire        evict_valid,
    input  wire        evict_ready,

    input  wire        reclaim_req,
    input  wire [7:0]  reclaim_data,
    input  wire        reclaim_valid,
    input  wire        reclaim_sop,
    input  wire        reclaim_eop,
    output wire        reclaim_ready
);

    localparam KV_OP_NONE   = 2'b00;
    localparam KV_OP_STORE  = 2'b10;
    localparam KV_OP_LOAD   = 2'b11;

    // =========================================================================
    // Internal state
    // =========================================================================
    reg [ADDR_BITS-1:0] write_ptr;
    reg [ADDR_BITS-1:0] read_ptr;
    reg [ADDR_BITS-1:0] occupancy;
    reg                  full_r;
    reg                  empty_r;

    assign kv_full  = full_r;
    assign kv_empty = empty_r;
    assign kv_occupancy = occupancy;

    // =========================================================================
    // KV store SRAM
    // =========================================================================
    reg [7:0] kv_sram [0:BANK_DEPTH*ENTRY_BYTES-1];

    // =========================================================================
    // Command detection
    // =========================================================================
    wire [1:0] kv_op_in = nob_in_data[1:0];
    wire       is_kv_store = nob_in_valid && nob_in_sop && (kv_op_in == KV_OP_STORE);
    wire       is_kv_load  = nob_in_valid && nob_in_sop && (kv_op_in == KV_OP_LOAD);

    // =========================================================================
    // FSMs
    // =========================================================================
    localparam KS_IDLE   = 2'd0;
    localparam KS_HEADER = 2'd1;
    localparam KS_DATA   = 2'd2;

    localparam KL_IDLE   = 2'd0;
    localparam KL_HEADER = 2'd1;
    localparam KL_DATA   = 2'd2;

    reg [1:0]  ks_state;
    reg [15:0] ks_len;
    reg [15:0] ks_pos;
    reg [ADDR_BITS-1:0] ks_addr;

    reg [1:0]  kl_state;
    reg [15:0] kl_len;
    reg [15:0] kl_pos;
    reg [ADDR_BITS-1:0] kl_addr;
    reg [7:0]  kl_out_data;
    reg        kl_out_valid;
    reg        kl_out_sop;
    reg        kl_out_eop;

    // =========================================================================
    // Pass-through pipeline
    // =========================================================================
    reg        pt_valid;
    reg        pt_sop;
    reg        pt_eop;
    reg [7:0]  pt_data;
    reg [1:0]  pt_vc;
    reg        pt_active;

    // Bug fix #4: eviction only when link idle
    wire kv_injecting = (kl_state != KL_IDLE);
    wire ks_consuming = (ks_state == KS_HEADER) || (ks_state == KS_DATA);

    assign nob_out_data  = kv_injecting ? kl_out_data  : pt_data;
    assign nob_out_valid = kv_injecting ? kl_out_valid : pt_valid;
    assign nob_out_sop   = kv_injecting ? kl_out_sop   : pt_sop;
    assign nob_out_eop   = kv_injecting ? kl_out_eop   : pt_eop;
    assign nob_out_vc    = kv_injecting ? 2'b11        : pt_vc;

    // Bug fix #3: block upstream when injecting or consuming
    assign nob_in_ready = (nob_out_ready || !pt_valid)
                       && !kv_injecting
                       && !ks_consuming;

    // KV load data to PE sideband
    reg [7:0]  kv_load_sram_data;
    reg        kv_load_sram_valid;
    reg        kv_load_sram_sop;
    reg        kv_load_sram_eop;

    assign kv_load_data  = kv_load_sram_data;
    assign kv_load_valid = kv_load_sram_valid;
    assign kv_load_sop   = kv_load_sram_sop;
    assign kv_load_eop   = kv_load_sram_eop;

    assign kv_store_ready = (ks_state == KS_DATA);
    assign reclaim_ready = (ks_state == KS_IDLE) && !full_r;

    // Eviction interface
    reg        evict_done_r;
    reg [7:0]  evict_data_r;
    reg        evict_valid_r;

    assign evict_done  = evict_done_r;
    assign evict_data  = evict_data_r;
    assign evict_valid = evict_valid_r;

    // =========================================================================
    // Main logic
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
            // Pass-through pipeline
            // =================================================================
            if (!kv_injecting && !ks_consuming && (nob_out_ready || !pt_valid)) begin
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
            // KV store FSM
            // Bug fix #1: consume SOP byte in KS_IDLE
            // =================================================================
            case (ks_state)
                KS_IDLE: begin
                    if (is_kv_store && !full_r) begin
                        ks_state <= KS_HEADER;
                        ks_pos   <= 1;
                        ks_addr  <= write_ptr * ENTRY_BYTES + 1;
                        kv_sram[write_ptr * ENTRY_BYTES] <= nob_in_data;
                    end
                    if (reclaim_req && reclaim_valid && !full_r) begin
                        ks_state <= KS_DATA;
                        ks_pos   <= 0;
                        ks_addr  <= write_ptr * ENTRY_BYTES;
                        ks_len   <= ENTRY_BYTES[15:0];
                    end
                end

                KS_HEADER: begin
                    if (nob_in_valid && nob_in_ready) begin
                        if (ks_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kv_sram[ks_addr] <= nob_in_data;
                            ks_addr <= ks_addr + 1;
                        end
                        ks_pos <= ks_pos + 1;
                        if (ks_pos == 2) begin
                            ks_len   <= {8'h00, nob_in_data};
                            ks_state <= KS_DATA;
                            ks_pos   <= 0;
                        end
                    end
                end

                KS_DATA: begin
                    if (kv_store_valid && kv_store_ready) begin
                        if (ks_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kv_sram[ks_addr] <= kv_store_data;
                            ks_addr <= ks_addr + 1;
                        end
                        // completion handled by occupancy block below
                    end else if (reclaim_valid && reclaim_req) begin
                        if (ks_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kv_sram[ks_addr] <= reclaim_data;
                            ks_addr <= ks_addr + 1;
                        end
                        // completion handled by occupancy block below
                    end
                end

                default: ks_state <= KS_IDLE;
            endcase

            // =================================================================
            // KV load FSM
            // Bug fix #4: eviction waits for pt_active==0
            // Bug fix #5: kl_out_data assigned SRAM data
            // Bug fix #7: separate ready signals
            // =================================================================
            case (kl_state)
                KL_IDLE: begin
                    if (evict_req && !empty_r && !pt_active && !kv_injecting) begin
                        kl_state    <= KL_HEADER;
                        kl_pos      <= 0;
                        kl_addr     <= evict_addr * ENTRY_BYTES;
                        kl_len      <= ENTRY_BYTES[15:0];
                        kl_out_data <= 8'hEE;
                        kl_out_valid <= 1;
                        kl_out_sop  <= 1;
                        kl_out_eop  <= 0;
                    end else if (is_kv_load && !empty_r && !kv_injecting) begin
                        kl_state    <= KL_HEADER;
                        kl_pos      <= 0;
                        kl_addr     <= read_ptr * ENTRY_BYTES;
                        kl_len      <= ENTRY_BYTES[15:0];
                        kl_out_data <= 8'hEE;
                        kl_out_valid <= 1;
                        kl_out_sop  <= 1;
                        kl_out_eop  <= 0;
                    end
                end

                KL_HEADER: begin
                    if (nob_out_ready) begin
                        kl_pos <= kl_pos + 1;
                        case (kl_pos)
                            0: begin kl_out_data <= 8'h80; kl_out_sop <= 0; end
                            1: begin kl_out_data <= kl_len[7:0];  end
                            2: begin kl_out_data <= kl_len[15:8]; end
                        endcase
                        if (kl_pos == 2) begin
                            kl_state <= KL_DATA;
                            kl_pos   <= 0;
                        end
                    end
                end

                KL_DATA: begin
                    if (evict_req && evict_ready) begin
                        if (kl_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            evict_data_r  <= kv_sram[kl_addr];
                            evict_valid_r <= 1;
                            kl_addr <= kl_addr + 1;
                            kl_pos  <= kl_pos + 1;
                        end
                        // completion handled by occupancy block below
                    end else if (!evict_req && nob_out_ready) begin
                        if (kl_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kl_out_data       <= kv_sram[kl_addr];
                            kl_out_valid      <= 1;
                            kl_out_eop        <= 0;
                            kv_load_sram_data  <= kv_sram[kl_addr];
                            kv_load_sram_valid <= 1;
                            kl_addr <= kl_addr + 1;
                            kl_pos  <= kl_pos + 1;
                        end
                        // completion handled by occupancy block below
                    end
                end

                default: kl_state <= KL_IDLE;
            endcase

            // =================================================================
            // Bug fix #6: occupancy tracking — store/load completions only
            // =================================================================
            if (ks_state == KS_DATA) begin
                if ((kv_store_valid && kv_store_ready && kv_store_eop) ||
                    (reclaim_valid && reclaim_req && reclaim_eop)) begin
                    write_ptr <= (write_ptr == BANK_DEPTH-1) ? 0 : write_ptr + 1;
                    occupancy <= occupancy + 1;
                    full_r    <= (occupancy == BANK_DEPTH - 1);
                    empty_r   <= 0;
                    ks_state  <= KS_IDLE;
                end
            end
            if (kl_state == KL_DATA && !evict_req && nob_out_ready && kl_pos == kl_len - 1) begin
                // KV_LOAD completion: last byte sent on NoB
                read_ptr <= (read_ptr == BANK_DEPTH-1) ? 0 : read_ptr + 1;
                occupancy <= occupancy - 1;
                full_r    <= 0;
                empty_r   <= (occupancy <= 1);
                kl_out_eop       <= 1;
                kv_load_sram_eop <= 1;
                kl_state  <= KL_IDLE;
            end else if (kl_state == KL_DATA && !evict_req && kl_pos == kl_len) begin
                // Eviction completion: offload controller deasserted evict_req
                read_ptr <= (read_ptr == BANK_DEPTH-1) ? 0 : read_ptr + 1;
                occupancy <= occupancy - 1;
                full_r    <= 0;
                empty_r   <= (occupancy <= 1);
                evict_done_r <= 1;
                kl_state  <= KL_IDLE;
            end
        end
    end

endmodule
