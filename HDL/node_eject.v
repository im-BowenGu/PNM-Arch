`include "pnm_defs.vh"

// =============================================================================
// node_eject — Y-lane → node DMA ejection gate (one per CAMM socket)
// Paper §2.2 (dimension-order routing) / §2.9 (doorbell)
//
// Compares full MODULE_ID against LOCAL_MODULE. Matching packets eject into
// the node DMA path (doorbell WATCH loop arms on the resulting stream).
// Non-matching packets continue along the Y-lane.
//
// MODULE_ID is NOT stripped on the match path: it is forwarded as the DEST
// byte of the DMA stream so that the end-to-end CRC (doorbell.v, Paper §2.10)
// covers the destination field, letting the doorbell reject a misdelivered
// message even when the routing fabric erred.  DMA stream layout:
//   DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
// =============================================================================
module node_eject #(
    parameter [7:0] LOCAL_MODULE = 8'h00
)(
    input  wire       clk,
    input  wire       rst_n,

    // Y-lane in
    input  wire [7:0] yin_data,
    input  wire       yin_valid,
    input  wire       yin_sop,
    input  wire       yin_eop,
    output wire       yin_ready,

    // Y-lane out (continue along column)
    output wire [7:0] yout_data,
    output wire       yout_valid,
    output wire       yout_sop,
    output wire       yout_eop,
    input  wire       yout_ready,

    // to node DMA / doorbell
    output wire [7:0] node_data,
    output wire       node_valid,
    output wire       node_sop,
    output wire       node_eop,
    input  wire       node_ready
);

    flit_gate #(
        .MATCH_VALUE   (LOCAL_MODULE),
        .MATCH_MASK    (8'hFF),
        .STRIP_ON_MATCH(0)
    ) gate (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_data    (yin_data),
        .in_valid   (yin_valid),
        .in_sop     (yin_sop),
        .in_eop     (yin_eop),
        .in_ready   (yin_ready),
        .match_data (node_data),
        .match_valid(node_valid),
        .match_sop  (node_sop),
        .match_eop  (node_eop),
        .match_ready(node_ready),
        .pass_data  (yout_data),
        .pass_valid (yout_valid),
        .pass_sop   (yout_sop),
        .pass_eop   (yout_eop),
        .pass_ready (yout_ready)
    );

endmodule
