`timescale 1ns/1ps

// =============================================================================
// fp16_mac_array — thin wrapper over fp_mac_array (CU 1 = FP16).
// Keeps the legacy module name/ports so the testbench is unchanged.
// =============================================================================
module fp16_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 3
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [ARRAY_SIZE*16-1:0] act_in,
    input  wire                     act_valid,
    input  wire                     act_sop,
    input  wire                     act_eop,
    input  wire [15:0]              weight_in,
    input  wire                     weight_load,
    input  wire [7:0]               weight_row,
    input  wire [7:0]               weight_col,
    output wire [ARRAY_SIZE*16-1:0] result_out,
    output wire                     result_valid,
    output wire                     result_sop,
    output wire                     result_eop,
    output wire                     busy
);
    fp_mac_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PIPE_DEPTH(PIPE_DEPTH),
        .CU(1)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .act_in(act_in), .act_valid(act_valid),
        .act_sop(act_sop), .act_eop(act_eop),
        .weight_in(weight_in),
        .weight_load(weight_load), .weight_row(weight_row), .weight_col(weight_col),
        .result_out(result_out), .result_valid(result_valid),
        .result_sop(result_sop), .result_eop(result_eop), .busy(busy)
    );
endmodule
