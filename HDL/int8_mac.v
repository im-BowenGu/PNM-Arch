`timescale 1ns/1ps

// =============================================================================
// int8_mac — Signed INT8 Multiply-Accumulate unit
//
// Computes: result = (a * b) + c  using signed 8-bit integers.
// Pipeline latency: 2 cycles (no normalization needed for integers).
//
// Input format:
//   a, b: signed 8-bit integers (-128 to +127)
//   c:    signed 32-bit accumulator
//
// Output format:
//   result: signed 32-bit integer (sufficient range for accumulate)
//
// This unit is used for INT8 quantized inference where activations and
// weights are quantized to 8-bit integers, and accumulation uses 32-bit
// to prevent overflow.
// =============================================================================

module int8_mac (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands
    input  wire [7:0]  a,       // multiplicand (signed INT8)
    input  wire [7:0]  b,       // multiplier (signed INT8)
    input  wire [31:0] c,       // addend/accumulator (signed INT32)
    input  wire        valid_in,

    // Output result
    output reg  [31:0] result,
    output reg         valid_out
);

    // =========================================================================
    // Pipeline stage 1: multiply
    // =========================================================================
    reg [7:0]  s1_a, s1_b;
    reg [31:0] s1_c;
    reg        s1_valid;

    // Sign-extend and multiply: 8x8 = 16 bits (signed)
    wire signed [7:0]  a_signed = a;
    wire signed [7:0]  b_signed = b;
    wire signed [15:0] product  = a_signed * b_signed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_a <= 0; s1_b <= 0; s1_c <= 0;
            s1_valid <= 0;
        end else begin
            s1_a <= a; s1_b <= b; s1_c <= c;
            s1_valid <= valid_in;
        end
    end

    // =========================================================================
    // Pipeline stage 2: accumulate
    // =========================================================================
    // Sign-extend product to 32 bits and add accumulator
    wire signed [31:0] product_ext = {{16{product[15]}}, product};
    wire signed [31:0] sum = product_ext + s1_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result   <= 0;
            valid_out <= 0;
        end else begin
            result   <= sum;
            valid_out <= s1_valid;
        end
    end

endmodule
