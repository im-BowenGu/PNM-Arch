`timescale 1ns/1ps

// =============================================================================
// int4_mac_array — INT4/INT8 Systolic Multiply-Accumulate Array
//
// A weight-stationary systolic array of INT8 MAC units operating on INT4
// packed activations, providing 4x packing density vs BF16 (paper §2.9).
//
// This is a thin wrapper over quant_mac_array (CU = 4, the INT8 MAC), the
// same way bf16_mac_array.v and fp16_mac_array.v wrap fp_mac_array.v.  The
// array shell -- the weight-stationary dataflow, the time-staggered vertical
// accumulation and the output collector -- is shared by the four quantized
// arrays; only the PE differs.
//
// The block scale ports exist only in the MXFP4 array, so they are left
// unconnected here.
// =============================================================================

module int4_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2            // int8_mac pipeline stages
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
        .CU         (4)          // CU_INT8_MAC
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
