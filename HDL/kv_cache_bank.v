`include "pnm_defs.vh"

// =============================================================================
// kv_cache_bank — Per-direction KV cache bank (Paper §2.6, §3.3)
//
// Attached between the lxy_repeater's NoB output and the xy_turn gate of one
// board column (LOCAL_X).  Each layer has one bank per column; the X-lane
// feeds every column's bank in turn, so a bank only intercepts a command
// whose MODULE_ID X nibble matches LOCAL_X and passes everything else
// through.  Together the columns provide distributed KV storage with
// low-latency access from the fabric.
//
// The bank snoops all incoming traffic on the NoB link.  A KV cache command
// is a normal wormhole flit whose CTRL byte carries a KV opcode: the bank
// intercepts it at the head (MODULE_ID | CTRL) before either byte is
// forwarded, so commands never reach the compute node.
//
//   KV_STORE (CTRL op = OP_KV_STORE, 0xA0 on class 2):
//     MODULE_ID | CTRL | LEN_LO | LEN_HI | <ENTRY_BYTES payload> | CRC
//     The bank absorbs the flit, validates the end-to-end CRC over
//     [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload], and on match appends the
//     payload to its FIFO SRAM (write_ptr).  A corrupt or wrong-length
//     command is drained and discarded: occupancy never changes.
//
//   KV_LOAD  (CTRL op = OP_KV_LOAD, 0xB0 on class 2):
//     MODULE_ID | CTRL | LEN_LO(=2) | LEN_HI(=0) | idx_lo | idx_hi | CRC
//     The payload is the entry index (sequence position) into the bank's
//     live FIFO window [read_ptr, read_ptr+occupancy).  The bank absorbs
//     the request, validates its CRC, and injects a response back onto the
//     NoB toward the node:
//     MODULE_ID(echoed) | 0x80 | LEN_LO | LEN_HI | <entry> | CRC
//     The response is a fully-formed compute flit (CRC over
//     [MODULE..payload]) so the node doorbell accepts it and the MAC stub
//     processes it exactly like a dispatched token.  Loads are reads: the
//     FIFO read_ptr only advances on eviction.
//
// When the bank is full it refuses stores (the flit passes through to the
// node unmodified instead of being absorbed) and asserts kv_full for the
// offload controller (kv_offload.v), which evicts the oldest entries back
// to the host via the spine.  Eviction streams the evicted entry out the
// evict_data/valid port and advances read_ptr.
//
// Reclaim (kv_offload refill) writes entries through the sideband
// reclaim_data/valid/sop/eop port with the same FIFO commit semantics as a
// CRC-valid NoB store (no CRC: the controller is trusted).
//
// Opcode decode: the opcode lives in the CTRL byte (wire byte 2), observed
// in the head window while the MODULE_ID sits in pass-through stage 1 and
// the CTRL byte is on the wire.  Both head bytes are absorbed together, so
// a command is never partially forwarded downstream.
//
// Bug fixes applied (audit rounds 22, 24, 32, 33 + KV co-sim enablement):
//   1. Deadlock: KV_STORE SOP byte consumed in KS_IDLE, not KS_HEADER
//   2. Reclaim deadlock: reclaim data accepted via reclaim_valid
//   3. Silent drop: nob_in_ready forced low when kv_injecting
//   4. Eviction corruption: eviction waits for pt_active==0 before hijacking
//   5. KV_LOAD injection: injected data sourced from SRAM
//   6. Write-write conflict: occupancy updated with priority (store > evict)
//   7. Cross-coupled ready: load uses nob_out_ready, eviction uses evict_ready
//   8. KV opcode decoded from the CTRL byte (was MODULE_ID low nibbles —
//      MEDIUM #32: the old decode sampled node coordinates)
//   9. Two-stage pass-through head so the CTRL byte is snooped before either
//      head byte is forwarded (a lone MODULE_ID can never leak downstream)
//   10. KV_LOAD response echoes the request MODULE_ID (was hardcoded 0xEE
//      pass-through, which node_eject would never eject) and carries a CRC
//      the node doorbell validates
//   11. Store and load commands CRC-validated before commit/serve; corrupt
//      commands drained and discarded instead of wedging the bank
//   12. CRC engine delegated to core/crc16.v (was an inline copy — the
//      wire-format sync rule must not have hidden in-module duplicates)
// =============================================================================
module kv_cache_bank #(
    parameter BANK_DEPTH   = 1024,
    parameter ENTRY_BYTES  = 512,
    parameter ADDR_BITS    = 10,
    parameter PIPE_STAGES  = 2,
    parameter LOCAL_X      = 4'hF   // board column this bank serves; the
                                    // MODULE_ID's X nibble must match, or the
                                    // command passes through (the X-lane feeds
                                    // every column's bank in turn, so a blind
                                    // bank at column 0 would intercept all of
                                    // the layer's traffic).  4'hF = any column.
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
    output wire [ADDR_BITS:0] kv_occupancy,
    output wire [ADDR_BITS-1:0] kv_read_ptr,
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

    localparam CRC_INIT   = 16'hFFFF;

    function integer clog2;
        input integer x;
        integer n;
        begin
            n = 0;
            while ((1 << n) < x) n = n + 1;
            clog2 = n;
        end
    endfunction
    localparam SRAM_AW = clog2(BANK_DEPTH * ENTRY_BYTES);

    // =========================================================================
    // Internal state
    // =========================================================================
    reg [ADDR_BITS-1:0] write_ptr;
    reg [ADDR_BITS-1:0] read_ptr;
    reg [ADDR_BITS:0] occupancy;   // 0..BANK_DEPTH
    reg                  full_r;
    reg                  empty_r;

    assign kv_full  = full_r;
    assign kv_empty = empty_r;
    assign kv_occupancy = occupancy;
    assign kv_read_ptr = read_ptr;

    reg [7:0] kv_sram [0:BANK_DEPTH*ENTRY_BYTES-1];

    // =========================================================================
    // CRC engine — delegated to core/crc16.v (the fabric-wide hardware twin
    // of sim/internal/pnm/crc.go: init 0xFFFF, poly 0x1021, MSB-first, no
    // final XOR).  Keeping the algorithm in one module means the wire-format
    // sync rule (pnm_defs.vh / crc16.v / doorbell.v / crc.go) has no hidden
    // in-module copies.
    // =========================================================================
    // init chains
    wire [15:0] c_abs1, c_abs2;      // (MODULE, CTRL) for store/load heads
    wire [15:0] c_ri1, c_ri2, c_ri3, c_ri4; // (dest, 0x80, LEN_LO, LEN_HI)
    crc16 u_crc_abs1 (.crc_in(CRC_INIT), .data_in(pt_data),       .crc_out(c_abs1));
    crc16 u_crc_abs2 (.crc_in(c_abs1),   .data_in(nob_in_data),   .crc_out(c_abs2));
    crc16 u_crc_ri1  (.crc_in(CRC_INIT), .data_in(lq_dest),       .crc_out(c_ri1));
    crc16 u_crc_ri2  (.crc_in(c_ri1),    .data_in(8'h80),         .crc_out(c_ri2));
    crc16 u_crc_ri3  (.crc_in(c_ri2),    .data_in(ENTRY_BYTES[7:0]),  .crc_out(c_ri3));
    crc16 u_crc_ri4  (.crc_in(c_ri3),    .data_in(ENTRY_BYTES[15:8]), .crc_out(c_ri4));
    // running folds (one per accumulator; the data is always the input byte)
    wire [15:0] ks_crc_nxt, lq_crc_nxt, ri_crc_nxt;
    crc16 u_crc_ks (.crc_in(ks_crc), .data_in(nob_in_data),     .crc_out(ks_crc_nxt));
    crc16 u_crc_lq (.crc_in(lq_crc), .data_in(nob_in_data),     .crc_out(lq_crc_nxt));
    crc16 u_crc_ri (.crc_in(ri_crc), .data_in(kv_sram[ri_addr]), .crc_out(ri_crc_nxt));

    // =========================================================================
    // Pass-through pipeline (two stages). Stage 2 is presented on nob_out.
    // A MODULE_ID (SOP) in stage 1 is held until its CTRL byte has been
    // inspected, so a KV command is absorbed whole before either byte could
    // leak downstream.
    // =========================================================================
    reg        pt_valid;
    reg        pt_sop;
    reg        pt_eop;
    reg [7:0]  pt_data;
    reg [1:0]  pt_vc;
    reg        pt_active;

    reg        pt2_valid;
    reg        pt2_sop;
    reg        pt2_eop;
    reg [7:0]  pt2_data;
    reg [1:0]  pt2_vc;

    wire       absorb_ok = (ks_state == KS_IDLE) && (lq_state == LQ_IDLE) &&
                           (ev_state == EV_IDLE) && !full_r;
    // Head window: MODULE_ID in stage 1 with CTRL on the wire.  Stage 2 may
    // hold the previous flit's tail byte (back-to-back injection): the bank
    // absorbs only once that byte is being accepted downstream this cycle
    // (pt2_eop && nob_out_ready), so the tail is never lost and every KV
    // command is still caught even when flits stream without a bubble.
    wire       col_match  = (LOCAL_X == 4'hF) || (pt_data[7:4] == LOCAL_X);
    wire       head_window = col_match && pt_valid && pt_sop && !pt_eop &&
                             nob_in_valid &&
                             (!pt2_valid || (pt2_eop && nob_out_ready));
    wire       is_kv_store = absorb_ok && head_window &&
                             (nob_in_data[5:4] == `OP_KV_STORE);
    wire       is_kv_load  = absorb_ok && head_window &&
                             (nob_in_data[5:4] == `OP_KV_LOAD);

    // =========================================================================
    // KV store FSM (NoB-absorbed STORE command)
    // =========================================================================
    localparam KS_IDLE   = 3'd0;
    localparam KS_LEN    = 3'd1;  // consume LEN_LO, LEN_HI
    localparam KS_SDATA  = 3'd2;  // consume ENTRY_BYTES payload into SRAM
    localparam KS_SCRC   = 3'd3;  // consume 2 CRC bytes, compare
    localparam KS_DRAIN  = 3'd4;  // malformed command: absorb until EOP, discard
    localparam KS_RDATA  = 3'd5;  // reclaim sideband write

    reg [2:0]  ks_state;
    reg [15:0] ks_pos;
    reg [SRAM_AW-1:0] ks_addr;
    reg [15:0] ks_crc;
    reg [15:0] ks_len;
    reg [7:0]  ks_dest;
    reg        ks_commit;      // CRC matched; commit pending in KS_SCRC
    reg        kv_absorb_block; // blocking flag: a NoB command was absorbed
                                // this cycle (visible to the case statements)

    // =========================================================================
    // KV load request FSM (NoB-absorbed LOAD command)
    // =========================================================================
    localparam LQ_IDLE   = 3'd0;
    localparam LQ_LEN    = 3'd1;  // consume LEN_LO, LEN_HI (must be 2)
    localparam LQ_PAYL   = 3'd2;  // consume 2 index bytes
    localparam LQ_CRC    = 3'd3;  // consume 2 CRC bytes, compare
    localparam LQ_DRAIN  = 3'd4;  // malformed request: absorb until EOP
    localparam LQ_DONE   = 3'd5;  // request consumed; settle one cycle before
                                  // the response starts (keeps nob_in_ready
                                  // high through the final-byte handshake)

    reg [2:0]  lq_state;
    reg [1:0]  lq_pos;
    reg [15:0] lq_crc;
    reg [7:0]  lq_dest;
    reg [15:0] lq_idx;
    reg        lq_ok;

    // =========================================================================
    // Response injection FSM (KV_LOAD result toward the node)
    // =========================================================================
    localparam RI_IDLE = 2'd0;
    localparam RI_HDR  = 2'd1;
    localparam RI_DATA = 2'd2;
    localparam RI_CRC  = 2'd3;

    reg [1:0]  ri_state;
    reg [15:0] ri_pos;
    reg [SRAM_AW-1:0] ri_addr;
    reg [15:0] ri_crc;
    reg [7:0]  ri_data;
    reg        ri_valid;
    reg        ri_sop;
    reg        ri_eop;
    reg        ri_triggered;  // blocking flag: response armed this cycle

    // =========================================================================
    // Eviction FSM (host offload stream via kv_offload controller)
    // =========================================================================
    localparam EV_IDLE = 2'd0;
    localparam EV_DATA = 2'd1;
    localparam EV_TAIL = 2'd2;

    reg [1:0]  ev_state;
    reg [15:0] ev_pos;
    reg [SRAM_AW-1:0] ev_addr;
    reg        ev_done_r;
    reg [7:0]  ev_data_r;
    reg        ev_valid_r;

    assign evict_done  = ev_done_r;
    assign evict_data  = ev_data_r;
    assign evict_valid = ev_valid_r;

    reg        kv_load_sram_valid;
    reg        kv_load_sram_sop;
    reg        kv_load_sram_eop;
    reg [7:0]  kv_load_sram_data;

    assign kv_load_data  = kv_load_sram_data;
    assign kv_load_valid = kv_load_sram_valid;
    assign kv_load_sop   = kv_load_sram_sop;
    assign kv_load_eop   = kv_load_sram_eop;

    assign kv_store_ready = (ks_state == KS_RDATA) && !full_r;
    assign reclaim_ready  = (ks_state == KS_RDATA);

    wire ks_active = (ks_state == KS_LEN) || (ks_state == KS_SDATA) ||
                     (ks_state == KS_SCRC) || (ks_state == KS_DRAIN);
    wire lq_active = (lq_state == LQ_LEN) || (lq_state == LQ_PAYL) ||
                     (lq_state == LQ_CRC) || (lq_state == LQ_DRAIN) ||
                     (lq_state == LQ_DONE);
    wire kv_injecting = (ri_state != RI_IDLE) || (ev_state != EV_IDLE);

    // While absorbing we are the consumer: accept every byte.
    assign nob_in_ready = (ks_active || lq_active) ? 1'b1
                        : (!kv_injecting && (nob_out_ready || !pt2_valid));

    assign nob_out_data  = kv_injecting ? (ri_state != RI_IDLE ? ri_data  : 8'h00) : pt2_data;
    assign nob_out_valid = kv_injecting ? (ri_state != RI_IDLE ? ri_valid : 1'b0)  : pt2_valid;
    assign nob_out_sop   = kv_injecting ? (ri_state != RI_IDLE ? ri_sop   : 1'b0)  : pt2_sop;
    assign nob_out_eop   = kv_injecting ? (ri_state != RI_IDLE ? ri_eop   : 1'b0)  : pt2_eop;
    assign nob_out_vc    = kv_injecting ? 2'b11                                   : pt2_vc;

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

            pt2_valid   <= 0;
            pt2_sop     <= 0;
            pt2_eop     <= 0;
            pt2_data    <= 0;
            pt2_vc      <= 0;

            ks_state    <= KS_IDLE;
            ks_pos      <= 0;
            ks_addr     <= 0;
            ks_crc      <= CRC_INIT;
            ks_len      <= 0;
            ks_dest     <= 0;
            ks_commit   <= 0;

            lq_state    <= LQ_IDLE;
            lq_pos      <= 0;
            lq_crc      <= CRC_INIT;
            lq_dest     <= 0;
            lq_idx      <= 0;
            lq_ok       <= 0;

            ri_state    <= RI_IDLE;
            ri_pos      <= 0;
            ri_addr     <= 0;
            ri_crc      <= CRC_INIT;
            ri_data     <= 0;
            ri_valid    <= 0;
            ri_sop      <= 0;
            ri_eop      <= 0;

            ev_state    <= EV_IDLE;
            ev_pos      <= 0;
            ev_addr     <= 0;
            ev_done_r   <= 0;
            ev_data_r   <= 0;
            ev_valid_r  <= 0;

            kv_load_sram_data  <= 0;
            kv_load_sram_valid <= 0;
            kv_load_sram_sop   <= 0;
            kv_load_sram_eop   <= 0;
        end else begin
            // Defaults: one-cycle pulses
            kv_load_sram_valid <= 0;
            kv_load_sram_sop   <= 0;
            kv_load_sram_eop   <= 0;
            ev_done_r  <= 0;
            ev_valid_r <= 0;
            kv_absorb_block = 0;
            ri_triggered    = 0;

            // =================================================================
            // Pass-through / head absorption (pt, pt2 are held untouched when
            // the bank is injecting or absorbing).
            // =================================================================
            if (!kv_injecting && !ks_active && !lq_active) begin
                if (is_kv_store) begin
                    // MODULE_ID is in pt, CTRL is on the wire: absorb both.
                    kv_absorb_block = 1;
                    ks_state <= KS_LEN;
                    ks_pos   <= 0;
                    ks_dest  <= pt_data;
                    ks_addr  <= write_ptr * ENTRY_BYTES;
                    ks_crc   <= c_abs2;
                    ks_commit <= 0;
                    pt_valid  <= 0;
                    pt2_valid <= 0;   // tail (if any) was accepted this cycle
                    pt_active <= 0;
                end else if (is_kv_load) begin
                    kv_absorb_block = 1;
                    lq_state <= LQ_LEN;
                    lq_pos   <= 0;
                    lq_dest  <= pt_data;
                    lq_crc   <= c_abs2;
                    lq_ok    <= 0;
                    pt_valid  <= 0;
                    pt2_valid <= 0;   // tail (if any) was accepted this cycle
                    pt_active <= 0;
                end else if (pt_valid && pt_sop && !pt_eop && !nob_in_valid) begin
                    // SOP head waiting for its CTRL byte: hold stage 1.
                end else if (nob_out_ready || !pt2_valid) begin
                    if (nob_in_valid) begin
                        pt2_data   <= pt_data;
                        pt2_valid  <= pt_valid;
                        pt2_sop    <= pt_sop;
                        pt2_eop    <= pt_eop;
                        pt2_vc     <= pt_vc;
                        pt_data    <= nob_in_data;
                        pt_valid   <= 1;
                        pt_sop     <= nob_in_sop;
                        pt_eop     <= nob_in_eop;
                        pt_vc      <= nob_in_vc;
                        pt_active  <= 1;
                    end else if (pt_valid) begin
                        // stage 2 drained and stage 1 holds the last byte:
                        // move it downstream.
                        pt2_data   <= pt_data;
                        pt2_valid  <= pt_valid;
                        pt2_sop    <= pt_sop;
                        pt2_eop    <= pt_eop;
                        pt2_vc     <= pt_vc;
                        pt_valid   <= 0;
                        pt_active  <= 0;
                    end else begin
                        pt2_valid  <= 0;
                        pt_active  <= 0;
                    end
                end
                // else: downstream backpressure — hold both stages.
            end

            // =================================================================
            // KV store FSM
            // =================================================================
            case (ks_state)
                KS_IDLE: begin
                    if (!kv_absorb_block && !full_r && reclaim_req && reclaim_valid) begin
                        ks_state <= KS_RDATA;
                        ks_pos   <= 0;
                        ks_addr  <= write_ptr * ENTRY_BYTES + 1;
                        kv_sram[write_ptr * ENTRY_BYTES] <= reclaim_data;
                    end
                end

                KS_LEN: begin
                    if (nob_in_valid) begin
                        ks_crc <= ks_crc_nxt;
                        if (ks_pos == 0) begin
                            ks_len[7:0] <= nob_in_data;
                            ks_pos     <= 1;
                        end else begin
                            ks_len[15:8] <= nob_in_data;
                            if (ks_len[7:0] != ENTRY_BYTES[7:0] ||
                                nob_in_data != ENTRY_BYTES[15:8]) begin
                                ks_state <= KS_DRAIN;   // wrong length: discard
                                ks_pos   <= 0;
                            end else begin
                                ks_state <= KS_SDATA;
                                ks_pos   <= ENTRY_BYTES[15:0];
                                ks_addr  <= write_ptr * ENTRY_BYTES;
                            end
                        end
                    end
                end

                KS_SDATA: begin
                    if (nob_in_valid) begin
                        if (ks_pos > 0) begin
                            ks_crc <= ks_crc_nxt;
                            if (ks_addr < BANK_DEPTH * ENTRY_BYTES)
                                kv_sram[ks_addr] <= nob_in_data;
                            ks_addr <= ks_addr + 1;
                            if (ks_pos == 1) begin
                                ks_state <= KS_SCRC;
                                ks_pos   <= 0;
                            end else begin
                                ks_pos <= ks_pos - 1;
                            end
                        end
                    end
                end

                KS_SCRC: begin
                    if (nob_in_valid) begin
                        if (ks_pos == 0) begin
                            ks_commit <= (nob_in_data == ks_crc[15:8]);
                            ks_pos    <= 1;
                        end else begin
                            if (ks_commit && nob_in_data == ks_crc[7:0]) begin
                                // CRC valid: commit the entry.
                                write_ptr <= (write_ptr == {ADDR_BITS{1'b1}}) ? 0 : write_ptr + 1;
                                occupancy <= occupancy + 1;
                                full_r    <= (occupancy == BANK_DEPTH - 1);
                                empty_r   <= 0;
                                // -- DEBUG DUMP --
                                if (ks_dest == 8'h30) begin : dbg_store
                                    integer dbg_j;
                                    for (dbg_j = 0; dbg_j < 16; dbg_j = dbg_j + 1)
                                        $display("DBGSTORE idx=%0d d=%02x", dbg_j, kv_sram[write_ptr*ENTRY_BYTES+dbg_j]);
                                end
                            end
                            // (corrupt: entry region left for the next store)
                            ks_state  <= KS_IDLE;
                            ks_pos    <= 0;
                            ks_commit <= 0;
                        end
                    end
                end

                KS_DRAIN: begin
                    if (nob_in_valid && nob_in_eop) begin
                        ks_state <= KS_IDLE;
                        ks_pos   <= 0;
                    end
                end

                KS_RDATA: begin
                    if (reclaim_valid && reclaim_req) begin
                        if (ks_addr < BANK_DEPTH * ENTRY_BYTES) begin
                            kv_sram[ks_addr] <= reclaim_data;
                            ks_addr  <= ks_addr + 1;
                        end
                        if (reclaim_eop || ks_pos == ENTRY_BYTES - 1) begin
                            write_ptr <= (write_ptr == {ADDR_BITS{1'b1}}) ? 0 : write_ptr + 1;
                            occupancy <= occupancy + 1;
                            full_r    <= (occupancy == BANK_DEPTH - 1);
                            empty_r   <= 0;
                            ks_state  <= KS_IDLE;
                            ks_pos    <= 0;
                        end else begin
                            ks_pos <= ks_pos + 1;
                        end
                    end
                end

                default: ks_state <= KS_IDLE;
            endcase

            // =================================================================
            // KV load request FSM
            // =================================================================
            case (lq_state)
                LQ_IDLE: ;
                LQ_LEN: begin
                    if (nob_in_valid) begin
                        lq_crc <= lq_crc_nxt;
                        if (lq_pos == 0) begin
                            lq_ok  <= (nob_in_data == 8'h02);
                            lq_pos <= 1;
                        end else begin
                            if (!lq_ok || nob_in_data != 8'h00) begin
                                lq_state <= LQ_DRAIN;
                            end else begin
                                lq_state <= LQ_PAYL;
                                lq_pos   <= 0;
                            end
                        end
                    end
                end
                LQ_PAYL: begin
                    if (nob_in_valid) begin
                        lq_crc <= lq_crc_nxt;
                        if (lq_pos == 0) begin
                            lq_idx[7:0] <= nob_in_data;
                            lq_pos     <= 1;
                        end else begin
                            lq_idx[15:8] <= nob_in_data;
                            lq_state <= LQ_CRC;
                            lq_pos   <= 0;
                        end
                    end
                end
                LQ_CRC: begin
                    if (nob_in_valid) begin
                        if (lq_pos == 0) begin
                            lq_ok  <= (nob_in_data == lq_crc[15:8]);
                            lq_pos <= 1;
                        end else begin
                            if (!(lq_ok && nob_in_data == lq_crc[7:0])) begin
                                // Corrupt request.  The CRC_LO byte is the
                                // flit's EOP: if it just arrived here, the
                                // drain has nothing left to absorb (draining
                                // would wait forever for an EOP that is
                                // already consumed).
                                if (nob_in_eop)
                                    lq_state <= LQ_IDLE;
                                else
                                    lq_state <= LQ_DRAIN;
                            end else if (empty_r || lq_idx >= occupancy) begin
                                lq_state <= LQ_IDLE;   // nothing to serve
                            end else begin
                                // CRC valid and in-window: settle one cycle so
                                // the final-byte acceptance handshake clears,
                                // then start the response.
                                lq_state <= LQ_DONE;
                            end
                        end
                    end
                end
                LQ_DONE: begin
                    // The request is fully absorbed.  Start the response now
                    // that the upstream has drained its final byte.
                    ri_triggered = 1;
                    ri_state <= RI_HDR;
                    ri_pos   <= 0;
                    ri_addr  <= ((read_ptr + lq_idx) %
                                 BANK_DEPTH) * ENTRY_BYTES;
                    ri_crc   <= c_ri4;
                    ri_data  <= lq_dest;
                    ri_valid <= 1;
                    ri_sop   <= 1;
                    ri_eop   <= 0;
                    lq_state <= LQ_IDLE;
                end
                LQ_DRAIN: begin
                    if (nob_in_valid && nob_in_eop) begin
                        lq_state <= LQ_IDLE;
                        lq_pos   <= 0;
                    end
                end
                default: lq_state <= LQ_IDLE;
            endcase

            // =================================================================
            // Response injection FSM (KV_LOAD result toward the node)
            // =================================================================
            case (ri_state)
                RI_IDLE: begin
                    if (!ri_triggered) begin
                        ri_valid <= 0;
                        ri_sop   <= 0;
                        ri_eop   <= 0;
                    end
                end
                RI_HDR: begin
                    if (nob_out_ready) begin
                        case (ri_pos)
                            0: begin ri_data <= 8'h80;  ri_sop <= 0; ri_pos <= 1; end
                            1: begin ri_data <= ENTRY_BYTES[7:0];  ri_pos <= 2; end
                            2: begin ri_data <= ENTRY_BYTES[15:8];
                                     ri_pos  <= 0;
                                     ri_state <= RI_DATA;
                               end
                        endcase
                    end
                end
                RI_DATA: begin
                    if (nob_out_ready) begin
                        ri_data  <= kv_sram[ri_addr];
                        ri_crc   <= ri_crc_nxt;
                        if (ri_pos == ENTRY_BYTES - 1) begin
                            ri_state <= RI_CRC;
                            ri_pos   <= 0;
                        end else begin
                            ri_addr  <= ri_addr + 1;
                            ri_pos   <= ri_pos + 1;
                        end
                    end
                end
                RI_CRC: begin
                    if (nob_out_ready) begin
                        if (ri_pos == 0) begin
                            ri_data <= ri_crc[15:8];
                            ri_pos  <= 1;
                        end else if (ri_pos == 1) begin
                            ri_data <= ri_crc[7:0];
                            ri_eop  <= 1;
                            ri_pos  <= 2;
                        end else begin
                            ri_state <= RI_IDLE;
                            ri_valid <= 0;
                            ri_eop   <= 0;
                            ri_pos   <= 0;
                        end
                    end
                end
                default: ri_state <= RI_IDLE;
            endcase

            // =================================================================
            // Eviction FSM (host offload stream)
            // =================================================================
            case (ev_state)
                EV_IDLE: begin
                    if (evict_req && !empty_r && !pt_active && !pt2_valid) begin
                        ev_state  <= EV_DATA;
                        ev_pos    <= 0;
                        ev_addr   <= evict_addr * ENTRY_BYTES;
                    end
                end
                EV_DATA: begin
                    if (evict_ready) begin
                        ev_data_r  <= kv_sram[ev_addr];
                        ev_valid_r <= 1;
                        ev_addr    <= ev_addr + 1;
                        if (ev_pos == ENTRY_BYTES - 1) begin
                            ev_done_r <= 1;
                            read_ptr   <= (read_ptr == {ADDR_BITS{1'b1}}) ? 0 : read_ptr + 1;
                            occupancy  <= occupancy - 1;
                            full_r     <= 0;
                            empty_r    <= (occupancy <= 1);
                            ev_state  <= EV_TAIL;
                            ev_pos    <= 0;
                        end else begin
                            ev_pos <= ev_pos + 1;
                        end
                    end
                end
                EV_TAIL: begin
                    // wait for the controller to deassert before returning,
                    // or the edge-triggered EV_IDLE entry would re-fire.
                    if (!evict_req) begin
                        ev_state <= EV_IDLE;
                    end
                end
                default: ev_state <= EV_IDLE;
            endcase
        end
    end

endmodule