`timescale 1ns/1ps

// =============================================================================
// int8_mac — INT8 Multiply-Accumulate Unit
//
// Computes: result = (a * b) + c
// Pipeline latency: 2 cycles
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
    // Pipeline Stage 1: Multiply
    // =========================================================================
    reg signed [15:0] s1_product;
    reg signed [31:0] s1_c;
    reg               s1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_product <= 16'sd0;
            s1_c       <= 32'sd0;
            s1_valid   <= 1'b0;
        end else begin
            s1_product <= $signed(a) * $signed(b);
            s1_c       <= $signed(c);
            s1_valid   <= valid_in;
        end
    end

    // =========================================================================
    // Pipeline Stage 2: Accumulate
    // =========================================================================
    // Verilog sign-extends s1_product to 32 bits because both operands
    // are declared as signed.
    wire signed [31:0] sum = s1_product + s1_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result    <= 32'd0;
            valid_out <= 1'b0;
        end else begin
            result    <= sum;
            valid_out <= s1_valid;
        end
    end

endmodule
