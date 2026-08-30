`timescale 1ns/1ps

// =============================================================================
// fp4_mac — FP4 (E2M1) Multiply-Accumulate Unit
//
// Computes: result = (a * b) + c
// where a and b are 4-bit FP4 (E2M1 microscaling) values.
//
// Two FP4 values are packed per byte for storage efficiency (like INT4):
//   - Byte format: {a_hi[3:0], a_lo[3:0]} (lo in lower nibble)
//   - pack_select chooses which nibble to use.
//
// E2M1 (per OCP Microscaling): 1 sign + 2 exponent + 1 mantissa, bias 1,
// no infinity/NaN, subnormals supported.  Dequant uses a direct lookup table
// (d8 = value * 8, i.e. 3 fractional bits); magnitudes follow the OCP MXFP4
// table:
//     0000:  0         0100:  2.0
//     0001:  0.5       0101:  3.0
//     0010:  1.0       0110:  4.0
//     0011:  1.5       0111:  6.0
//     1xxx: -1 * the 0xxx row
//
// The product a*b is carried in fixed point: d8a * d8b, so the physical
// value of a single product is result / 64.  FP4 is too narrow to multiply
// directly — convention is to dequantize to a wider fixed point, multiply,
// and accumulate to INT32 (paper §2.9 quantized inference path).
//
// Pipeline latency: 2 cycles (same as int8_mac / int4_mac).
//
// Use case: FP4 quantized inference, 4x packing density vs BF16 (same as
// INT4) when the wider fixed-point accumulation can absorb the reduced input
// precision.
// =============================================================================

module fp4_mac (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands
    input  wire [7:0]  a,             // packed FP4 operand (two 4-bit values)
    input  wire        pack_select,   // 0 = low nibble, 1 = high nibble
    input  wire [7:0]  b,             // packed FP4 multiplier
    input  wire        b_pack_select, // 0 = low nibble, 1 = high nibble
    input  wire [31:0] c,             // addend/accumulator (signed INT32)
    input  wire [3:0]  wshift,        // unsigned power-of-two left shift on b's
                                      // dequant (MXFP4 block scale); 0 for plain FP4
    input  wire        valid_in,

    // Output result
    output reg  [31:0] result,
    output reg         valid_out
);

    // =========================================================================
    // Nibble extraction
    // =========================================================================
    wire [3:0] a_nibble = pack_select ? a[7:4] : a[3:0];
    wire [3:0] b_nibble = b_pack_select ? b[7:4] : b[3:0];

    // =========================================================================
    // E2M1 → fixed point dequant (value * 8), via lookup table (OCP MX table)
    // =========================================================================
    // d8 is the signed magnitude with 3 fractional bits.  MXFP4 block scale
    // (b_scale below) lifts the weight's d8 by 2^wshift before the multiply,
    // so a single product = result / 64 (d8a * (d8b << wshift)).
    reg signed [11:0] a_d8;
    reg signed [11:0] b_d8;
    reg signed [31:0] b_scaled;

    always @(*) begin
        case (a_nibble[2:0])
            3'd0: a_d8 = 12'sd0;
            3'd1: a_d8 = 12'sd4;    // 0.5
            3'd2: a_d8 = 12'sd8;    // 1.0
            3'd3: a_d8 = 12'sd12;   // 1.5
            3'd4: a_d8 = 12'sd16;   // 2.0
            3'd5: a_d8 = 12'sd24;   // 3.0
            3'd6: a_d8 = 12'sd32;   // 4.0
            3'd7: a_d8 = 12'sd48;   // 6.0
        endcase
        if (a_nibble[3]) a_d8 = -a_d8;
        case (b_nibble[2:0])
            3'd0: b_d8 = 12'sd0;
            3'd1: b_d8 = 12'sd4;    // 0.5
            3'd2: b_d8 = 12'sd8;    // 1.0
            3'd3: b_d8 = 12'sd12;   // 1.5
            3'd4: b_d8 = 12'sd16;   // 2.0
            3'd5: b_d8 = 12'sd24;   // 3.0
            3'd6: b_d8 = 12'sd32;   // 4.0
            3'd7: b_d8 = 12'sd48;   // 6.0
        endcase
        if (b_nibble[3]) b_d8 = -b_d8;
        // 32-bit so a legal MXFP4 block scale (wshift up to 15) cannot wrap:
        // 48 << 15 = 1,572,864, well within range.
        b_scaled = b_d8 << wshift;
    end

    // =========================================================================
    // Pipeline Stage 1: Multiply
    // =========================================================================
    reg signed [31:0] s1_product;
    reg signed [31:0] s1_c;
    reg               s1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_product <= 32'sd0;
            s1_c       <= 32'sd0;
            s1_valid   <= 1'b0;
        end else begin
            s1_product <= a_d8 * b_scaled;
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
