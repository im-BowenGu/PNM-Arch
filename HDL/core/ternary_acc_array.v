`timescale 1ns/1ps

// =============================================================================
// ternary_acc_array -- Ternary (BitNet b1.58) Systolic Multiply-Accumulate Array
//
// A weight-stationary systolic array of ternary select-add units
// (paper §3.6): a ternary weight against an INT8 activation,
// accumulated into signed INT32.  The weight codes select {+a, -a,
// 0}, so the PE is a conditional add rather than a multiplier.
//
// This is a thin wrapper over quant_mac_array (CU = 11, the ternary
// datapath), the same way bf16_mac_array.v and fp16_mac_array.v wrap
// fp_mac_array.v.  The array shell is shared by the four quantized
// arrays; only the PE differs.  The block scale ports exist only in
// the MXFP4 array, so they are left unconnected here.
// =============================================================================

module ternary_acc_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2            // PE pipeline stages
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Activation input (INT8, one value per row) ------------------------
    input  wire [ARRAY_SIZE*8-1:0] act_in,     // activation vector (8b each)
    input  wire                    act_valid,
    input  wire                    act_sop,
    input  wire                    act_eop,

    // -- Weight input (pre-loaded, stationary) -----------------------------
    input  wire [7:0]              weight_in,  // INT8 weight value
    input  wire                    weight_load,
    input  wire [7:0]              weight_row,
    input  wire [7:0]              weight_col,

    // -- Result output (emerges at bottom) ---------------------------------
    output wire [ARRAY_SIZE*32-1:0] result_out, // result vector (32b each)
    output wire                     result_valid,
    output wire                     result_sop,
    output wire                     result_eop,

    // -- Status ------------------------------------------------------------
    output wire                     busy
);
    quant_mac_array #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .PIPE_DEPTH (PIPE_DEPTH),
        .CU         (11)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .act_in     (act_in),
        .act_valid  (act_valid),
        .act_sop    (act_sop),
        .act_eop    (act_eop),
        .weight_in  (weight_in),
        .weight_load(weight_load),
        .weight_row (weight_row),
        .weight_col (weight_col),
        .scale_in   (8'd0),      // unused: no block scale on this unit
        .scale_load (1'b0),
        .result_out (result_out),
        .result_valid(result_valid),
        .result_sop (result_sop),
        .result_eop (result_eop),
        .busy       (busy)
    );

endmodule
