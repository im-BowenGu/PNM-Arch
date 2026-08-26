`timescale 1ns/1ps

// =============================================================================
// int4_mac — INT4 Multiply-Accumulate Unit
//
// Computes: result = (a * b) + c
// where a and b are signed 4-bit integers (range -8 to +7).
//
// Two INT4 values are packed per byte for storage efficiency:
//   - Byte format: {a_hi[3:0], a_lo[3:0]} (lo in lower nibble)
//   - The pack_select input chooses which nibble to use.
//
// Pipeline latency: 2 cycles (same as int8_mac)
//
// Use case: INT4 quantized inference for 2x density vs INT8.
// Weights are stored as INT4, activations may be INT4 or INT8.
// =============================================================================

module int4_mac (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands
    input  wire [7:0]  a,           // packed INT4 operand (two 4-bit values)
    input  wire        pack_select, // 0 = use low nibble, 1 = use high nibble
    input  wire [7:0]  b,           // packed INT4 multiplier
    input  wire        b_pack_select, // 0 = use low nibble, 1 = use high nibble
    input  wire [31:0] c,           // addend/accumulator (signed INT32)
    input  wire        valid_in,

    // Output result
    output reg  [31:0] result,
    output reg         valid_out
);

    // =========================================================================
    // Nibble extraction
    // =========================================================================
    wire signed [3:0] a_nibble = pack_select ? a[7:4] : a[3:0];
    wire signed [3:0] b_nibble = b_pack_select ? b[7:4] : b[3:0];

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
            s1_product <= $signed(a_nibble) * $signed(b_nibble);
            s1_c       <= $signed(c);
            s1_valid   <= valid_in;
        end
    end

    // =========================================================================
    // Pipeline Stage 2: Accumulate
    // =========================================================================
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
