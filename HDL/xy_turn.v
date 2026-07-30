`include "pnm_defs.vh"

// =============================================================================
// xy_turn — X→Y dimension-order turn gate (one per column on the X-lane)
// Paper Section 4.2
//
// On the MODULE_ID head byte of an on-board stream, compares the X nibble
// against LOCAL_X. Matching packets turn into the Y-lane (column bus);
// non-matching packets continue along the X-lane.
//
// Does not strip MODULE_ID — the Y-lane still needs it for node ejection.
// =============================================================================
module xy_turn #(
    parameter [3:0] LOCAL_X = 4'h0
)(
    input  wire       clk,
    input  wire       rst_n,

    // X-lane in
    input  wire [7:0] xin_data,
    input  wire       xin_valid,
    input  wire       xin_sop,
    input  wire       xin_eop,
    output wire       xin_ready,

    // X-lane out (continue along row)
    output wire [7:0] xout_data,
    output wire       xout_valid,
    output wire       xout_sop,
    output wire       xout_eop,
    input  wire       xout_ready,

    // Y-lane out (turn into column)
    output wire [7:0] yout_data,
    output wire       yout_valid,
    output wire       yout_sop,
    output wire       yout_eop,
    input  wire       yout_ready
);

    flit_gate #(
        .MATCH_VALUE   ({LOCAL_X, 4'h0}),
        .MATCH_MASK    (8'hF0),
        .STRIP_ON_MATCH(0)
    ) gate (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_data    (xin_data),
        .in_valid   (xin_valid),
        .in_sop     (xin_sop),
        .in_eop     (xin_eop),
        .in_ready   (xin_ready),
        .match_data (yout_data),
        .match_valid(yout_valid),
        .match_sop  (yout_sop),
        .match_eop  (yout_eop),
        .match_ready(yout_ready),
        .pass_data  (xout_data),
        .pass_valid (xout_valid),
        .pass_sop   (xout_sop),
        .pass_eop   (xout_eop),
        .pass_ready (xout_ready)
    );

endmodule
