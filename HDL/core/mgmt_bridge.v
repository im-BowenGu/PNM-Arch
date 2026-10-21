`timescale 1ns/1ps

// =============================================================================
// mgmt_bridge — the node board's management path (mode A)
//
// The gating ASIC is a per-node device: it holds the router weights and
// produces the expert decision for every token that lands on its node.  In
// mode A the manager of that device is the *embedded management node* on the
// board -- an MCU or a Raspberry Pi Compute Module -- rather than the host.
//
// This module is the board's glue between that management node, the gating
// ASIC, and the fabric:
//
//   * the management node's register bus is forwarded to the gating ASIC's
//     management port (mgmt_*), so the node programs the router weights and
//     reads the decision without the decision ever leaving the board;
//   * the token arriving on the node's NoB is *tapped* into a small buffer
//     the management node can read -- this is how the node obtains the
//     token's hidden state to gate;
//   * the dispatch flit the management node builds is *injected* onto the
//     node's outgoing NoB, arbitrated against the repeater's stream.
//
// The arbitration is deliberately simple and priority-based: the management
// node's injection holds the lane while it is active, and the repeater's
// stream is held (through its ready) in the meantime.  The fabric is
// deterministic and the injection is the rare event, so a priority arbiter
// with no reordering is enough.
//
// The wire format is the fabric's (HDL/pnm_defs.vh): a byte stream with
// SOP/EOP framing, the DEST byte first, and the CRC-16 over the protected
// body.
// =============================================================================

module mgmt_bridge #(
    // The token buffer's depth in bytes.  A token's payload is at most a
    // 32-byte flit plus the header, so 64 bytes holds one comfortably.
    parameter TAP_BYTES  = 64,
    // The injection's depth in bytes.
    parameter INJ_BYTES  = 64
)(
    input  wire       clk,
    input  wire       rst_n,

    // -- The management node's register bus --------------------------------
    input  wire [15:0] mgr_addr,
    input  wire [15:0] mgr_wdata,
    output wire [15:0] mgr_rdata,
    input  wire        mgr_we,
    input  wire        mgr_valid,
    output wire        mgr_ready,

    // -- The gating ASIC's management port (forwarded) ---------------------
    output wire [15:0] asic_addr,
    output wire [15:0] asic_wdata,
    input  wire [15:0] asic_rdata,
    output wire        asic_we,
    output wire        asic_valid,
    input  wire        asic_ready,

    // -- The node's incoming NoB (the repeater's delivery) ----------------
    input  wire [7:0]  nob_in_data,
    input  wire        nob_in_valid,
    input  wire        nob_in_sop,
    input  wire        nob_in_eop,
    output wire        nob_in_ready,
    input  wire [1:0]  nob_in_vc,

    // -- The token tap: the bytes the management node can read -------------
    output wire [7:0]  tap_data,
    output wire        tap_valid,
    output wire        tap_sop,
    output wire        tap_eop,
    input  wire        tap_ready,
    output wire        tap_empty,
    output wire        tap_full,
    output wire [1:0]  tap_vc,

    // -- The management node's injection -----------------------------------
    input  wire [7:0]  inj_data,
    input  wire        inj_valid,
    input  wire        inj_sop,
    input  wire        inj_eop,
    output wire        inj_ready,
    input  wire [1:0]  inj_vc,

    // -- The node's outgoing NoB (towards the fabric) ----------------------
    output wire [7:0]  nob_out_data,
    output wire        nob_out_valid,
    output wire        nob_out_sop,
    output wire        nob_out_eop,
    input  wire        nob_out_ready,
    output wire [1:0]  nob_out_vc
);

    // =========================================================================
    // The management node's bus goes straight to the gating ASIC.  The
    // gating ASIC's ready is a registered copy of its valid, so a transaction
    // completes on the second edge of a valid window; the board's bus driver
    // holds valid that long.
    // =========================================================================
    assign asic_addr  = mgr_addr;
    assign asic_wdata = mgr_wdata;
    assign asic_we    = mgr_we;
    assign asic_valid = mgr_valid;
    assign mgr_rdata  = asic_rdata;
    assign mgr_ready  = asic_ready;

    // =========================================================================
    // The injection buffer: the management node's flit waits here for the
    // outgoing lane.
    // =========================================================================
    localparam INJ_AW = (INJ_BYTES <= 2)   ? 1 :
                         (INJ_BYTES <= 4)   ? 2 :
                         (INJ_BYTES <= 8)   ? 3 :
                         (INJ_BYTES <= 16)  ? 4 :
                         (INJ_BYTES <= 32)  ? 5 : 6;

    reg [7:0] inj_mem [0:INJ_BYTES-1];
    reg [INJ_AW-1:0] inj_rd;
    reg [INJ_AW-1:0] inj_wr;
    reg [INJ_AW:0]   inj_count;
    reg              inj_first;   // the next byte out is the frame's first
    reg [1:0]        inj_vc_r;

    wire inj_has   = (inj_count != 0);
    wire inj_space = (inj_count < INJ_BYTES);

    assign inj_ready = inj_space;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inj_rd    <= {INJ_AW{1'b0}};
            inj_wr    <= {INJ_AW{1'b0}};
            inj_count <= {(INJ_AW+1){1'b0}};
            inj_first <= 1'b1;
            inj_vc_r  <= 2'b00;
        end else begin
            if (inj_has && nob_out_ready) begin
                inj_rd    <= inj_rd + 1'b1;
                inj_count <= inj_count - 1'b1;
                inj_first <= 1'b0;
            end
            if (inj_valid && inj_ready) begin
                inj_mem[inj_wr[INJ_AW-1:0]] <= inj_data;
                inj_wr    <= inj_wr + 1'b1;
                inj_count <= inj_count + 1'b1;
                inj_vc_r  <= inj_vc;
            end
        end
    end

    // =========================================================================
    // The token tap: a byte FIFO fed from the node's incoming NoB.
    // =========================================================================
    localparam TAP_AW = (TAP_BYTES <= 2)   ? 1 :
                         (TAP_BYTES <= 4)   ? 2 :
                         (TAP_BYTES <= 8)   ? 3 :
                         (TAP_BYTES <= 16)  ? 4 :
                         (TAP_BYTES <= 32)  ? 5 : 6;

    reg [7:0] tap_mem [0:TAP_BYTES-1];
    reg [TAP_AW-1:0] tap_rd;
    reg [TAP_AW-1:0] tap_wr;
    reg [TAP_AW:0]   tap_count;

    wire tap_has = (tap_count != 0);
    wire tap_space = (tap_count < TAP_BYTES);

    assign tap_empty = !tap_has;
    assign tap_full  = !tap_space;
    assign tap_data  = tap_mem[tap_rd[TAP_AW-1:0]];
    assign tap_valid = tap_has;
    assign tap_sop   = (tap_count == 1) ? 1'b1 : 1'b0;   // the first byte out
    assign tap_eop   = 1'b0;                              // the tap is a stream
    assign tap_vc    = nob_in_vc;

    // The tap is drained by the management node; the incoming stream is
    // stalled while the tap is full, and while an injection owns the
    // outgoing lane.
    wire inj_active = inj_has;
    assign nob_in_ready = tap_space && !inj_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tap_rd    <= {TAP_AW{1'b0}};
            tap_wr    <= {TAP_AW{1'b0}};
            tap_count <= {(TAP_AW+1){1'b0}};
        end else begin
            // pop
            if (tap_has && tap_ready) begin
                tap_rd    <= tap_rd + 1'b1;
                tap_count <= tap_count - 1'b1;
            end
            // push
            if (nob_in_valid && nob_in_ready) begin
                tap_mem[tap_wr[TAP_AW-1:0]] <= nob_in_data;
                tap_wr    <= tap_wr + 1'b1;
                tap_count <= tap_count + 1'b1;
            end
        end
    end

    // =========================================================================
    // The outgoing lane: the management node's injection has priority over
    // the repeater's stream, because the injection is the rare event and
    // the repeater's stream is held by its ready in the meantime.
    // =========================================================================
    reg [7:0]  pass_data_r;
    reg        pass_valid_r;
    reg        pass_sop_r;
    reg        pass_eop_r;
    reg [1:0]  pass_vc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pass_data_r  <= 8'h00;
            pass_valid_r <= 1'b0;
            pass_sop_r   <= 1'b0;
            pass_eop_r   <= 1'b0;
            pass_vc_r    <= 2'b00;
        end else begin
            if (nob_in_valid && nob_in_ready) begin
                pass_data_r  <= nob_in_data;
                pass_valid_r <= 1'b1;
                pass_sop_r   <= nob_in_sop;
                pass_eop_r   <= nob_in_eop;
                pass_vc_r    <= nob_in_vc;
            end else if (pass_valid_r && nob_out_ready) begin
                pass_valid_r <= 1'b0;
                pass_sop_r   <= 1'b0;
                pass_eop_r   <= 1'b0;
            end
        end
    end

    assign nob_out_data  = inj_active ? inj_mem[inj_rd[INJ_AW-1:0]] : pass_data_r;
    assign nob_out_valid = inj_active ? 1'b1 : pass_valid_r;
    assign nob_out_sop   = inj_active ? (inj_first ? 1'b1 : 1'b0) : pass_sop_r;
    assign nob_out_eop   = inj_active ? 1'b0 : pass_eop_r;
    assign nob_out_vc    = inj_active ? inj_vc_r : pass_vc_r;

endmodule
