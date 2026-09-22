`timescale 1ns/1ps

// =============================================================================
// fp16_fma — IEEE 754 half-precision (binary16) Fused Multiply-Add unit.
// Thin wrapper over the parameterized fma_core (EXP=5, MAN=10, bias=15,
// 22-bit alignment window, subnormal results flushed to zero).
// Computes: result = (a * b) + c.  Pipeline latency: 3 cycles.
// =============================================================================

module fp16_fma (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire [15:0] c,
    input  wire       valid_in,
    output wire [15:0] result,
    output wire       valid_out
);

    fma_core #(
        .W(16), .E(5), .M(10), .B(15), .AW(22), .FTZ(1)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

endmodule