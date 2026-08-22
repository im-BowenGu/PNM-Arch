`include "pnm_defs.vh"

// =============================================================================
// flit_gate — universal combinational-match wormhole demux
// Paper §2.1 (Z-axis ingress) / §2.2 (dimension-order NoB)
//
// On the head byte of a packet (sop), a combinational XOR/AND tree compares
// the incoming byte against match_value under match_mask
// (~50–100 ps on 14nm DUV; no clocks in the compare path).  The match
// value/mask are runtime inputs — the pre-loaded routing-table entry of
// Paper §2.1 — instead of compile-time parameters, so a repeater's routing
// decision can be programmed at boot like the paper's immutable tables.
//
// The decision gates the whole packet to the MATCH port or the PASS port.
// It is registered at the clock edge and held until eop.
//
// STRIP_ON_MATCH=1 consumes the head byte on the match path (source-routing
// header peel): the next byte becomes the new sop for the downstream hop.
// =============================================================================
module flit_gate #(
    parameter       STRIP_ON_MATCH = 0
)(
    input  wire       clk,
    input  wire       rst_n,

    // bit-mask comparator inputs: head byte matches when
    // ((in_data ^ match_value) & match_mask) == 8'h0
    input  wire [7:0] match_value,
    input  wire [7:0] match_mask,

    // virtual-channel class filter (paper §4.3): a flit matches only if its
    // head byte arrives on the class this gate routes (vc_accept); the 2-bit
    // per-link VC sideband passes through on both output ports.
    input  wire [1:0] vc_accept,
    input  wire [1:0] in_vc,
    output wire [1:0] match_vc,
    output wire [1:0] pass_vc,

    // upstream
    input  wire [7:0] in_data,
    input  wire       in_valid,
    input  wire       in_sop,
    input  wire       in_eop,
    output wire       in_ready,

    // MATCH port (local NoB / Y-lane / node DMA)
    output wire [7:0] match_data,
    output wire       match_valid,
    output wire       match_sop,
    output wire       match_eop,
    input  wire       match_ready,

    // PASS port (down-spine / along X-lane / along Y-lane)
    output wire [7:0] pass_data,
    output wire       pass_valid,
    output wire       pass_sop,
    output wire       pass_eop,
    input  wire       pass_ready
);

    // --- combinational comparator: XOR then masked NOR-reduce, plus the
    // VC class check ---
    // Pure combo path — this is the ~50–100 ps DUV tree in the paper.
    wire cmp_match = (((in_data ^ match_value) & match_mask) == 8'b0)
                  && (in_vc == vc_accept);

    // Decision hold: head decision kept for the packet body.
    reg  route_match_q;
    wire route_match = in_sop ? cmp_match : route_match_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            route_match_q <= 1'b0;
        else if (in_valid && in_ready && in_sop)
            route_match_q <= cmp_match;
    end

    // Strip bookkeeping: next match-port byte becomes the new sop.
    reg  strip_next_q;
    wire match_drop = (STRIP_ON_MATCH != 0) && in_sop && route_match;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            strip_next_q <= 1'b0;
        else if (in_valid && in_ready) begin
            if (in_sop && route_match && (STRIP_ON_MATCH != 0))
                strip_next_q <= 1'b1;
            else if (route_match)
                strip_next_q <= 1'b0;
        end
    end

    // --- demux ---
    assign match_data  = in_data;
    assign match_valid = in_valid && route_match && !match_drop;
    assign match_sop   = (STRIP_ON_MATCH != 0) ? strip_next_q : in_sop;
    assign match_eop   = in_eop;
    assign match_vc    = in_vc;

    assign pass_data   = in_data;
    assign pass_valid  = in_valid && !route_match;
    assign pass_sop    = in_sop;
    assign pass_eop    = in_eop;
    assign pass_vc     = in_vc;

    // Dropped head byte is consumed by the gate itself (always ready).
    assign in_ready = route_match
                    ? (match_drop ? 1'b1 : match_ready)
                    : pass_ready;

endmodule
