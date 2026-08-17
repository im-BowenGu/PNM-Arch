`include "pnm_defs.vh"

// =============================================================================
// kv_offload — KV Cache Offloading Controller (Paper §2.6, §3.3)
//
// Manages eviction and reclaim of KV cache entries between the on-chip bank
// and host memory (via the spine fabric).  When the bank is full, the oldest
// entries are evicted back to the host.  When the host needs them again, they
// are reloaded via the weight upload path.
//
// Eviction priority: oldest entries first (FIFO order matching the bank's
// write_ptr).  The controller uses the compile-time latency budget to
// estimate when evicted entries will be needed again and preloads them.
//
// Protocol:
//   1. Bank asserts kv_full → controller begins eviction
//   2. Controller reads oldest entry from bank via evict_req/evict_addr
//   3. Controller wraps evicted data in a KV_OFFLOAD flit and injects into spine
//   4. Host receives the flit and stores it in DRAM
//   5. When needed, host sends KV_RELOAD flit through the router chip
//   6. Controller captures the reload data and writes it back into the bank
// =============================================================================
module kv_offload #(
    parameter NUM_LAYERS  = 4,
    parameter BANK_DEPTH  = 1024,
    parameter ADDR_BITS   = 10
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Per-layer bank interface (one bank per layer) -------------------
    // Bank 0
    input  wire        kv_full_0,
    input  wire        kv_empty_0,
    input  wire [ADDR_BITS-1:0] kv_occupancy_0,
    output wire        evict_req_0,
    output wire [ADDR_BITS-1:0] evict_addr_0,
    input  wire        evict_done_0,
    input  wire [7:0]  evict_data_0,
    input  wire        evict_valid_0,
    output wire        evict_ready_0,
    output wire        reclaim_req_0,
    output wire [7:0]  reclaim_data_0,
    output wire        reclaim_valid_0,
    output wire        reclaim_sop_0,
    output wire        reclaim_eop_0,
    input  wire        reclaim_ready_0,

    // Bank 1
    input  wire        kv_full_1,
    input  wire        kv_empty_1,
    input  wire [ADDR_BITS-1:0] kv_occupancy_1,
    output wire        evict_req_1,
    output wire [ADDR_BITS-1:0] evict_addr_1,
    input  wire        evict_done_1,
    input  wire [7:0]  evict_data_1,
    input  wire        evict_valid_1,
    output wire        evict_ready_1,
    output wire        reclaim_req_1,
    output wire [7:0]  reclaim_data_1,
    output wire        reclaim_valid_1,
    output wire        reclaim_sop_1,
    output wire        reclaim_eop_1,
    input  wire        reclaim_ready_1,

    // Bank 2
    input  wire        kv_full_2,
    input  wire        kv_empty_2,
    input  wire [ADDR_BITS-1:0] kv_occupancy_2,
    output wire        evict_req_2,
    output wire [ADDR_BITS-1:0] evict_addr_2,
    input  wire        evict_done_2,
    input  wire [7:0]  evict_data_2,
    input  wire        evict_valid_2,
    output wire        evict_ready_2,
    output wire        reclaim_req_2,
    output wire [7:0]  reclaim_data_2,
    output wire        reclaim_valid_2,
    output wire        reclaim_sop_2,
    output wire        reclaim_eop_2,
    input  wire        reclaim_ready_2,

    // Bank 3
    input  wire        kv_full_3,
    input  wire        kv_empty_3,
    input  wire [ADDR_BITS-1:0] kv_occupancy_3,
    output wire        evict_req_3,
    output wire [ADDR_BITS-1:0] evict_addr_3,
    input  wire        evict_done_3,
    input  wire [7:0]  evict_data_3,
    input  wire        evict_valid_3,
    output wire        evict_ready_3,
    output wire        reclaim_req_3,
    output wire [7:0]  reclaim_data_3,
    output wire        reclaim_valid_3,
    output wire        reclaim_sop_3,
    output wire        reclaim_eop_3,
    input  wire        reclaim_ready_3,

    // -- Spine injection port (for eviction flits) ----------------------
    output wire [7:0]  spine_out_data,
    output wire        spine_out_valid,
    output wire        spine_out_sop,
    output wire        spine_out_eop,
    input  wire        spine_out_ready,
    output wire [1:0]  spine_out_vc,

    // -- Spine extraction port (for reclaim flits from host) ------------
    input  wire [7:0]  spine_in_data,
    input  wire        spine_in_valid,
    input  wire        spine_in_sop,
    input  wire        spine_in_eop,
    output wire        spine_in_ready,

    // -- Status ---------------------------------------------------------
    output reg  [31:0] evictions,
    output reg  [31:0] reloads,
    output reg  [31:0] errors
);

    // =========================================================================
    // Offload controller FSM
    // =========================================================================
    localparam OC_IDLE     = 3'd0;
    localparam OC_EVICT_RD = 3'd1;  // reading bank for eviction
    localparam OC_EVICT_WR = 3'd2;  // writing evicted data to spine
    localparam OC_RECLAIM  = 3'd3;  // receiving reloaded data from spine

    reg [2:0]  oc_state;
    reg [1:0]  oc_bank;     // which bank we're operating on
    reg [15:0] oc_pos;      // byte position within entry

    // =========================================================================
    // Bank output demux (one bank active at a time)
    // =========================================================================
    wire        any_full  = kv_full_0 | kv_full_1 | kv_full_2 | kv_full_3;
    wire        any_empty = kv_empty_0 & kv_empty_1 & kv_empty_2 & kv_empty_3;

    // Eviction request signals (active bank)
    reg         evict_req_r;
    reg [ADDR_BITS-1:0] evict_addr_r;
    wire        evict_done_active;
    wire [7:0]  evict_data_active;
    wire        evict_valid_active;

    assign evict_req_0  = (oc_bank == 0) ? evict_req_r : 1'b0;
    assign evict_req_1  = (oc_bank == 1) ? evict_req_r : 1'b0;
    assign evict_req_2  = (oc_bank == 2) ? evict_req_r : 1'b0;
    assign evict_req_3  = (oc_bank == 3) ? evict_req_r : 1'b0;

    assign evict_addr_0 = (oc_bank == 0) ? evict_addr_r : 0;
    assign evict_addr_1 = (oc_bank == 1) ? evict_addr_r : 0;
    assign evict_addr_2 = (oc_bank == 2) ? evict_addr_r : 0;
    assign evict_addr_3 = (oc_bank == 3) ? evict_addr_r : 0;

    assign evict_done_active  = (oc_bank == 0) ? evict_done_0  :
                                (oc_bank == 1) ? evict_done_1  :
                                (oc_bank == 2) ? evict_done_2  : evict_done_3;
    assign evict_data_active  = (oc_bank == 0) ? evict_data_0  :
                                (oc_bank == 1) ? evict_data_1  :
                                (oc_bank == 2) ? evict_data_2  : evict_data_3;
    assign evict_valid_active = (oc_bank == 0) ? evict_valid_0 :
                                (oc_bank == 1) ? evict_valid_1 :
                                (oc_bank == 2) ? evict_valid_2 : evict_valid_3;

    assign evict_ready_0 = (oc_bank == 0) ? spine_out_ready : 1'b0;
    assign evict_ready_1 = (oc_bank == 1) ? spine_out_ready : 1'b0;
    assign evict_ready_2 = (oc_bank == 2) ? spine_out_ready : 1'b0;
    assign evict_ready_3 = (oc_bank == 3) ? spine_out_ready : 1'b0;

    // Reclaim signals
    assign reclaim_req_0  = (oc_bank == 0 && oc_state == OC_RECLAIM);
    assign reclaim_req_1  = (oc_bank == 1 && oc_state == OC_RECLAIM);
    assign reclaim_req_2  = (oc_bank == 2 && oc_state == OC_RECLAIM);
    assign reclaim_req_3  = (oc_bank == 3 && oc_state == OC_RECLAIM);

    assign reclaim_data_0  = (oc_bank == 0) ? spine_in_data : 8'h00;
    assign reclaim_data_1  = (oc_bank == 1) ? spine_in_data : 8'h00;
    assign reclaim_data_2  = (oc_bank == 2) ? spine_in_data : 8'h00;
    assign reclaim_data_3  = (oc_bank == 3) ? spine_in_data : 8'h00;

    assign reclaim_valid_0 = (oc_bank == 0 && oc_state == OC_RECLAIM) ? spine_in_valid : 1'b0;
    assign reclaim_valid_1 = (oc_bank == 1 && oc_state == OC_RECLAIM) ? spine_in_valid : 1'b0;
    assign reclaim_valid_2 = (oc_bank == 2 && oc_state == OC_RECLAIM) ? spine_in_valid : 1'b0;
    assign reclaim_valid_3 = (oc_bank == 3 && oc_state == OC_RECLAIM) ? spine_in_valid : 1'b0;

    assign reclaim_sop_0  = (oc_bank == 0) ? spine_in_sop : 1'b0;
    assign reclaim_sop_1  = (oc_bank == 1) ? spine_in_sop : 1'b0;
    assign reclaim_sop_2  = (oc_bank == 2) ? spine_in_sop : 1'b0;
    assign reclaim_sop_3  = (oc_bank == 3) ? spine_in_sop : 1'b0;

    assign reclaim_eop_0  = (oc_bank == 0) ? spine_in_eop : 1'b0;
    assign reclaim_eop_1  = (oc_bank == 1) ? spine_in_eop : 1'b0;
    assign reclaim_eop_2  = (oc_bank == 2) ? spine_in_eop : 1'b0;
    assign reclaim_eop_3  = (oc_bank == 3) ? spine_in_eop : 1'b0;

    assign reclaim_ready_0 = (oc_bank == 0) ? spine_in_ready : 1'b0;
    assign reclaim_ready_1 = (oc_bank == 1) ? spine_in_ready : 1'b0;
    assign reclaim_ready_2 = (oc_bank == 2) ? spine_in_ready : 1'b0;
    assign reclaim_ready_3 = (oc_bank == 3) ? spine_in_ready : 1'b0;

    // Spine injection: eviction flits use VC_SPINE_ASCENT (class 1)
    assign spine_out_data  = evict_data_active;
    assign spine_out_valid = (oc_state == OC_EVICT_WR) ? evict_valid_active : 1'b0;
    assign spine_out_sop   = (oc_pos == 0);
    assign spine_out_eop   = (oc_pos == 511); // ENTRY_BYTES - 1
    assign spine_out_vc    = 2'b01;  // VC_SPINE_ASCENT

    assign spine_in_ready = (oc_state == OC_RECLAIM);

    // =========================================================================
    // Offload controller main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oc_state  <= OC_IDLE;
            oc_bank   <= 0;
            oc_pos    <= 0;
            evict_req_r  <= 0;
            evict_addr_r <= 0;
            evictions    <= 0;
            reloads      <= 0;
            errors       <= 0;
        end else begin
            evict_req_r <= 0;

            case (oc_state)
                OC_IDLE: begin
                    // Priority: evict from fullest bank
                    if (kv_full_0) begin
                        oc_bank   <= 0;
                        oc_state  <= OC_EVICT_RD;
                        evict_req_r <= 1;
                        evict_addr_r <= 0; // evict oldest (addr 0)
                        oc_pos    <= 0;
                    end else if (kv_full_1) begin
                        oc_bank   <= 1;
                        oc_state  <= OC_EVICT_RD;
                        evict_req_r <= 1;
                        evict_addr_r <= 0;
                        oc_pos    <= 0;
                    end else if (kv_full_2) begin
                        oc_bank   <= 2;
                        oc_state  <= OC_EVICT_RD;
                        evict_req_r <= 1;
                        evict_addr_r <= 0;
                        oc_pos    <= 0;
                    end else if (kv_full_3) begin
                        oc_bank   <= 3;
                        oc_state  <= OC_EVICT_RD;
                        evict_req_r <= 1;
                        evict_addr_r <= 0;
                        oc_pos    <= 0;
                    end
                    // Reclaim handled by spine_in extraction (see below)
                end

                OC_EVICT_RD: begin
                    // Wait for bank to start providing data
                    if (evict_valid_active) begin
                        oc_state <= OC_EVICT_WR;
                        oc_pos   <= 0;
                    end
                end

                OC_EVICT_WR: begin
                    // Stream evicted data to spine
                    if (spine_out_ready && evict_valid_active) begin
                        oc_pos <= oc_pos + 1;
                        if (oc_pos == 511) begin // ENTRY_BYTES - 1
                            evictions <= evictions + 1;
                            oc_state  <= OC_IDLE;
                        end
                    end
                end

                OC_RECLAIM: begin
                    // Receive reloaded data from spine and write back to bank
                    if (spine_in_valid && spine_in_ready) begin
                        if (spine_in_eop) begin
                            reloads  <= reloads + 1;
                            oc_state <= OC_IDLE;
                        end
                    end
                end

                default: oc_state <= OC_IDLE;
            endcase
        end
    end

endmodule
