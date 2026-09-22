`timescale 1ns/1ps

// =============================================================================
// fp32_fma — IEEE 754 single-precision (binary32) Fused Multiply-Add unit.
// Thin wrapper over the parameterized fma_core (EXP=8, MAN=23, bias=127,
// 48-bit alignment window, full denormal output with RNE).
// Computes: result = (a * b) + c.  Pipeline latency: 3 cycles.
// =============================================================================

module fp32_fma (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    input  wire       valid_in,
    output wire [31:0] result,
    output wire       valid_out
);

    fma_core #(
        .W(32), .E(8), .M(23), .B(127), .AW(48), .FTZ(0)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

endmodule