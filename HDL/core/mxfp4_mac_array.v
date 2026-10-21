`timescale 1ns/1ps

// =============================================================================
// mxfp4_mac_array -- MXFP4 Systolic Multiply-Accumulate Array
//
// A weight-stationary systolic array of FP4 MAC units with a shared
// per-row block scale (OCP Microscaling): every weight in a
// 32-element block is dequantized by the same 2^scale factor
// (paper §2.9, Table 5).
//
// This is a thin wrapper over quant_mac_array (CU = 7, the MXFP4
// datapath), the same way bf16_mac_array.v and fp16_mac_array.v wrap
// fp_mac_array.v.  The array shell is shared by the four quantized
// arrays; only the PE and the per-row scale differ.
//
// Per-row scale: scale[row] is loaded from scale_in/scale_load using
// weight_row as the row index, and applied as the weight's wshift,
// which lifts its weight dequant by 2^scale before the multiply, so a
// single accumulator value = sum(d8a * (d8b << scale))/64.
//
// Dot-product scale convention: physical result = result_out / 64.
// =============================================================================

module mxfp4_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2            // PE pipeline stages
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Activation input (packed FP4, two per byte per row) ---------------
    input  wire [ARRAY_SIZE*8-1:0] act_in,     // activation vector (2xFP4 each)
    input  wire                    act_valid,
    input  wire                    act_sop,
    input  wire                    act_eop,

    // -- Weight input (pre-loaded, stationary, packed FP4) -----------------
    input  wire [7:0]              weight_in,  // packed FP4 weight byte
    input  wire                    weight_load,
    input  wire [7:0]              weight_row,
    input  wire [7:0]              weight_col,

    // -- Block scale input (MXFP4 shared per-row exponent) -----------------
    input  wire [7:0]              scale_in,   // raw 8-bit scale
    input  wire                    scale_load, // load scale[row] from scale_in

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
        .CU         (7)
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
        .scale_in   (scale_in),
        .scale_load (scale_load),
        .result_out (result_out),
        .result_valid(result_valid),
        .result_sop (result_sop),
        .result_eop (result_eop),
        .busy       (busy)
    );

endmodule
