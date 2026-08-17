`timescale 1ns/1ps

// =============================================================================
// fp16_fma — IEEE 754 half-precision Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in FP16 (binary16) format.
// Pipeline latency: 3 cycles (matching MULT_LATENCY in pe_tile_stub.v).
//
// IEEE 754 half-precision format:
//   [15]    sign
//   [14:10] exponent (5 bits, bias = 15)
//   [9:0]   mantissa (10 bits, implicit leading 1)
//
// Denormals, NaN, and infinity are handled.  Round-to-nearest-even is used.
//
// NOTE: iverilog drops the MSB of {1'b1, wire[9:0]} concatenations.
//       Workaround: use bit-by-bit assignment for the mantissa field.
// =============================================================================

module fp16_fma (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands (FP16 encoded)
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
    localparam FP16_BIAS    = 15;
    localparam FP16_ZERO    = 16'h0000;
    localparam FP16_ONE     = 16'h3C00;  // 1.0
    localparam FP16_INF     = 16'h7C00;
    localparam FP16_NAN     = 16'h7E00;

    // =========================================================================
    // Pipeline stage 1: unpack and multiply
    // =========================================================================
    reg [15:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    // Unpack a
    wire        a_sign = a[15];
    wire [4:0]  a_exp  = a[14:10];
    wire [9:0]  a_man  = a[9:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_inf  = (a_exp == 31) && (a_man == 0);
    wire        a_nan  = (a_exp == 31) && (a_man != 0);
    wire        a_den  = (a_exp == 0) && (a_man != 0);

    // Build mantissa: 11 bits (bit 10 = implicit 1, bits 9:0 = fraction)
    // This mirrors bf16_fma's 8-bit mantissa (bit 7 = implicit 1, bits 6:0 = fraction)
    wire [10:0] a_mantissa;
    assign a_mantissa[10]   = a_zero ? 1'b0 : (a_den ? 1'b0 : 1'b1);
    assign a_mantissa[9:0]  = a_zero ? 10'd0 : (a_den ? {1'b0, a_man} : a_man);
    wire [5:0]  a_exponent = a_zero ? 6'd0   : (a_den ? 6'd1 : {1'b0, a_exp});

    // Unpack b
    wire        b_sign = b[15];
    wire [4:0]  b_exp  = b[14:10];
    wire [9:0]  b_man  = b[9:0];
    wire        b_zero = (b_exp == 0) && (b_man == 0);
    wire        b_inf  = (b_exp == 31) && (b_man == 0);
    wire        b_nan  = (b_exp == 31) && (b_man != 0);
    wire        b_den  = (b_exp == 0) && (b_man != 0);

    wire [10:0] b_mantissa;
    assign b_mantissa[10]   = b_zero ? 1'b0 : (b_den ? 1'b0 : 1'b1);
    assign b_mantissa[9:0]  = b_zero ? 10'd0 : (b_den ? {1'b0, b_man} : b_man);
    wire [5:0]  b_exponent = b_zero ? 6'd0   : (b_den ? 6'd1 : {1'b0, b_exp});

    // Multiply: sign, exponent add, mantissa multiply
    wire        mul_sign = a_sign ^ b_sign;
    wire [6:0]  mul_exp  = a_exponent + b_exponent - FP16_BIAS;
    wire [21:0] mul_man  = a_mantissa * b_mantissa;  // 11x11 = 22 bits

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
    wire [4:0]  c_exp  = s1_c[14:10];
    wire [9:0]  c_man  = s1_c[9:0];
    wire        c_zero = (c_exp == 0) && (c_man == 0);
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [10:0] c_mantissa;
    assign c_mantissa[10]   = c_zero ? 1'b0 : (c_den ? 1'b0 : 1'b1);
    assign c_mantissa[9:0]  = c_zero ? 10'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [5:0]  c_exponent = c_zero ? 6'd0   : (c_den ? 6'd1 : {1'b0, c_exp});

    // FP16 mantissa product: 11-bit x 11-bit = 22-bit product.
    // Both inputs have implicit 1 at bit 10, so the product has implicit 1
    // at bit 20.  Left-shift by 1 to align with c_mantissa (implicit 1 at bit 21).
    // If the shift overflows (mul_man[21]=1), the effective exponent is mul_exp+1.
    wire        mul_overflow = mul_man[21];
    wire [6:0]  mul_eff_exp  = mul_overflow ? (mul_exp + 7'd1) : mul_exp;

    // Determine result exponent
    wire [5:0]  add_exp = (mul_eff_exp > c_exponent) ? mul_eff_exp : c_exponent;

    // Align mantissas: both now have implicit 1 at bit 21
    wire [21:0] mul_man_aligned = (mul_eff_exp >= c_exponent) ?
        (mul_man << 1) : (mul_man << 1) >> (c_exponent - mul_eff_exp);
    wire [21:0] c_man_aligned   = (c_exponent > mul_eff_exp) ?
        {c_mantissa, 11'd0} : {c_mantissa, 11'd0} >> (mul_eff_exp - c_exponent);

    // Add (with sign/magnitude handling)
    wire        add_sign;
    wire [22:0] add_result;

    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [22:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    assign add_sign = (mul_sign == c_sign) ? mul_sign :
                      mul_ge_c ? mul_sign : c_sign;
    assign add_result = (mul_sign == c_sign) ?
        {1'b0, mul_man_aligned} + {1'b0, c_man_aligned} :
        abs_diff;

    // Normalize
    reg [21:0] norm_man;
    reg [5:0]  norm_exp;
    reg        norm_sign;
    reg [4:0]  lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[22]) begin
            // Overflow: shift right by 1, increment exponent
            norm_man = add_result[22:1];
            norm_exp = add_exp + 1;
        end else begin
            norm_man = add_result[21:0];
            norm_exp = add_exp;
            if (!norm_man[21]) begin
                lead_pos = 0;
                if (norm_man[20]) lead_pos = 1;
                else if (norm_man[19]) lead_pos = 2;
                else if (norm_man[18]) lead_pos = 3;
                else if (norm_man[17]) lead_pos = 4;
                else if (norm_man[16]) lead_pos = 5;
                else if (norm_man[15]) lead_pos = 6;
                else if (norm_man[14]) lead_pos = 7;
                else if (norm_man[13]) lead_pos = 8;
                else if (norm_man[12]) lead_pos = 9;
                else if (norm_man[11]) lead_pos = 10;
                else if (norm_man[10]) lead_pos = 11;
                else if (norm_man[9])  lead_pos = 12;
                else if (norm_man[8])  lead_pos = 13;
                else if (norm_man[7])  lead_pos = 14;
                else if (norm_man[6])  lead_pos = 15;
                else if (norm_man[5])  lead_pos = 16;
                else if (norm_man[4])  lead_pos = 17;
                else if (norm_man[3])  lead_pos = 18;
                else if (norm_man[2])  lead_pos = 19;
                else if (norm_man[1])  lead_pos = 20;
                else                   lead_pos = 21;
                shift = lead_pos;
                norm_man = norm_man << shift;
                norm_exp = add_exp - shift;
            end
        end
    end

    // Pack result
    wire [15:0] packed_result;
    assign packed_result = (norm_exp <= 0) ? FP16_ZERO :  // underflow -> zero
                          (norm_exp >= 31) ? FP16_INF :    // overflow -> infinity
                          {norm_sign, norm_exp[4:0], norm_man[20:11]};

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
            result   <= 0;
            valid_out <= 0;
        end else begin
            result   <= s2_result;
            valid_out <= s2_valid;
        end
    end

endmodule
