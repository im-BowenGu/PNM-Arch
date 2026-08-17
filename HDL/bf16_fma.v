`timescale 1ns/1ps

// =============================================================================
// bf16_fma — Brain Floating Point 16 Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in BF16 (Brain Float 16) format.
// Pipeline latency: 3 cycles.
//
// BF16 format (Google Brain):
//   [15]    sign
//   [14:7]  exponent (8 bits, bias = 127)
//   [6:0]   mantissa (7 bits, implicit leading 1)
//
// BF16 has the same exponent range as FP32 (8-bit exponent) but lower
// precision (7-bit mantissa vs FP32's 23-bit).  This makes it ideal for
// deep learning training/inference where range matters more than precision.
//
// NOTE: iverilog drops the MSB of {1'b1, wire} concatenations.
//       Workaround: use bit-slice assignment for the mantissa field.
// =============================================================================

module bf16_fma (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands (BF16 encoded)
    input  wire [15:0] a,       // multiplicand
    input  wire [15:0] b,       // multiplier
    input  wire [15:0] c,       // addend
    input  wire        valid_in,

    // Output result
    output reg  [15:0] result,
    output reg         valid_out
);

    // =========================================================================
    // Internal constants
    // =========================================================================
    localparam BF16_BIAS   = 127;
    localparam BF16_ZERO   = 16'h0000;
    localparam BF16_ONE    = 16'h3F80;  // 1.0
    localparam BF16_INF    = 16'h7F80;
    localparam BF16_NAN    = 16'h7FC0;

    // =========================================================================
    // Pipeline stage 1: unpack and multiply
    // =========================================================================
    reg [15:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    // Unpack a
    wire        a_sign = a[15];
    wire [7:0]  a_exp  = a[14:7];
    wire [6:0]  a_man  = a[6:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_den  = (a_exp == 0) && (a_man != 0);

    // Build mantissa via bit-slice (avoids iverilog {1'b1, wire} MSB drop)
    wire [7:0]  a_mantissa;
    assign a_mantissa[7]   = a_zero ? 1'b0 : (a_den ? 1'b0 : 1'b1);
    assign a_mantissa[6:0] = a_zero ? 7'd0 : (a_den ? {1'b0, a_man} : a_man);
    wire [8:0]  a_exponent = a_zero ? 9'd0 : (a_den ? 9'd1 : {1'b0, a_exp});

    // Unpack b
    wire        b_sign = b[15];
    wire [7:0]  b_exp  = b[14:7];
    wire [6:0]  b_man  = b[6:0];
    wire        b_zero = (b_exp == 0) && (b_man == 0);
    wire        b_den  = (b_exp == 0) && (b_man != 0);

    wire [7:0]  b_mantissa;
    assign b_mantissa[7]   = b_zero ? 1'b0 : (b_den ? 1'b0 : 1'b1);
    assign b_mantissa[6:0] = b_zero ? 7'd0 : (b_den ? {1'b0, b_man} : b_man);
    wire [8:0]  b_exponent = b_zero ? 9'd0 : (b_den ? 9'd1 : {1'b0, b_exp});

    // Multiply
    wire        mul_sign = a_sign ^ b_sign;
    wire [8:0]  mul_exp  = a_exponent + b_exponent - BF16_BIAS;
    wire [15:0] mul_man  = a_mantissa * b_mantissa;  // 8x8 = 16 bits

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
    // Pipeline stage 2: align and add
    // =========================================================================
    reg [15:0] s2_result;
    reg        s2_valid;

    // Unpack c (the addend)
    wire        c_sign = s1_c[15];
    wire [7:0]  c_exp  = s1_c[14:7];
    wire [6:0]  c_man  = s1_c[6:0];
    wire        c_zero = (c_exp == 0) && (c_man == 0);
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [7:0]  c_mantissa;
    assign c_mantissa[7]   = c_zero ? 1'b0 : (c_den ? 1'b0 : 1'b1);
    assign c_mantissa[6:0] = c_zero ? 7'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [8:0]  c_exponent = c_zero ? 9'd0 : (c_den ? 9'd1 : {1'b0, c_exp});

    // BF16 mantissa product: 8-bit x 8-bit = 16-bit product.
    // Both inputs have implicit 1 at bit 7, so the product has implicit 1
    // at bit 14.  Left-shift by 1 to align with c_mantissa (implicit 1 at bit 15).
    // If the shift overflows (mul_man[15]=1), the effective exponent is mul_exp+1.
    wire        mul_overflow = mul_man[15];
    wire [8:0]  mul_eff_exp  = mul_overflow ? (mul_exp + 9'd1) : mul_exp;

    // Determine result exponent
    wire [8:0]  add_exp = (mul_eff_exp > c_exponent) ? mul_eff_exp : c_exponent;

    // Align mantissas: both now have implicit 1 at bit 15
    wire [15:0] mul_man_aligned = (mul_eff_exp >= c_exponent) ?
        (mul_man << 1) : (mul_man << 1) >> (c_exponent - mul_eff_exp);
    wire [15:0] c_man_aligned   = (c_exponent > mul_eff_exp) ?
        {c_mantissa, 8'd0} : {c_mantissa, 8'd0} >> (mul_eff_exp - c_exponent);

    // Add (with sign/magnitude handling)
    wire        add_sign;
    wire [16:0] add_result;

    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [16:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    assign add_sign = (mul_sign == c_sign) ? mul_sign :
                      mul_ge_c ? mul_sign : c_sign;
    assign add_result = (mul_sign == c_sign) ?
        {1'b0, mul_man_aligned} + {1'b0, c_man_aligned} :
        abs_diff;

    // Normalize
    reg [15:0] norm_man;
    reg [8:0]  norm_exp;
    reg        norm_sign;
    reg [3:0]  lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[16]) begin
            // Overflow: shift right by 1, increment exponent
            norm_man = add_result[16:1];
            norm_exp = add_exp + 1;
        end else begin
            norm_man = add_result[15:0];
            norm_exp = add_exp;
            if (!norm_man[15]) begin
                lead_pos = 0;
                if (norm_man[14]) lead_pos = 1;
                else if (norm_man[13]) lead_pos = 2;
                else if (norm_man[12]) lead_pos = 3;
                else if (norm_man[11]) lead_pos = 4;
                else if (norm_man[10]) lead_pos = 5;
                else if (norm_man[9])  lead_pos = 6;
                else if (norm_man[8])  lead_pos = 7;
                else if (norm_man[7])  lead_pos = 8;
                else if (norm_man[6])  lead_pos = 9;
                else if (norm_man[5])  lead_pos = 10;
                else if (norm_man[4])  lead_pos = 11;
                else if (norm_man[3])  lead_pos = 12;
                else if (norm_man[2])  lead_pos = 13;
                else if (norm_man[1])  lead_pos = 14;
                else                   lead_pos = 15;
                shift = lead_pos;
                norm_man = norm_man << shift;
                norm_exp = add_exp - shift;
            end
        end
    end

    // Pack result
    wire [15:0] packed_result;
    assign packed_result = (norm_exp <= 0) ? BF16_ZERO :
                          (norm_exp >= 255) ? BF16_INF :
                          {norm_sign, norm_exp[7:0], norm_man[14:8]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_result <= 0;
            s2_valid  <= 0;
        end else begin
            s2_result <= packed_result;
            s2_valid  <= s1_valid;
        end
    end

    // =========================================================================
    // Pipeline stage 3: output register
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result    <= 0;
            valid_out <= 0;
        end else begin
            result    <= s2_result;
            valid_out <= s2_valid;
        end
    end

endmodule
