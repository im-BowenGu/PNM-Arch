`timescale 1ns/1ps

// =============================================================================
// fp32_fma — IEEE 754 single-precision Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in FP32 (binary32) format.
// Pipeline latency: 3 cycles (matching MULT_LATENCY in pe_tile_stub.v).
//
// IEEE 754 single-precision format:
//   [31]    sign
//   [30:23] exponent (8 bits, bias = 127)
//   [22:0]  mantissa (23 bits, implicit leading 1)
//
// Denormals, NaN, and infinity are handled.  Round-to-nearest-even is used.
// =============================================================================

module fp32_fma (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands (FP32 encoded)
    input  wire [31:0] a,       // multiplicand
    input  wire [31:0] b,       // multiplier
    input  wire [31:0] c,       // addend
    input  wire        valid_in,

    // Output result
    output reg  [31:0] result,
    output reg         valid_out
);

    // =========================================================================
    // Internal constants
    // =========================================================================
    localparam FP32_BIAS    = 127;
    localparam FP32_ZERO    = 32'h00000000;
    localparam FP32_ONE     = 32'h3F800000;  // 1.0
    localparam FP32_INF     = 32'h7F800000;
    localparam FP32_NAN     = 32'h7FC00000;

    // =========================================================================
    // Pipeline stage 1: unpack and multiply
    // =========================================================================
    reg [31:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    // Unpack a
    wire        a_sign = a[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [22:0] a_man  = a[22:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_inf  = (a_exp == 255) && (a_man == 0);
    wire        a_nan  = (a_exp == 255) && (a_man != 0);
    wire        a_den  = (a_exp == 0) && (a_man != 0);

    // Build mantissa: 24 bits (bit 23 = implicit 1, bits 22:0 = fraction)
    wire [23:0] a_mantissa;
    assign a_mantissa[23]    = a_zero ? 1'b0 : (a_den ? 1'b0 : 1'b1);
    assign a_mantissa[22:0]  = a_zero ? 23'd0 : (a_den ? {1'b0, a_man} : a_man);
    wire [8:0]  a_exponent = a_zero ? 9'd0 : (a_den ? 9'd1 : {1'b0, a_exp});

    // Unpack b
    wire        b_sign = b[31];
    wire [7:0]  b_exp  = b[30:23];
    wire [22:0] b_man  = b[22:0];
    wire        b_zero = (b_exp == 0) && (b_man == 0);
    wire        b_inf  = (b_exp == 255) && (b_man == 0);
    wire        b_nan  = (b_exp == 255) && (b_man != 0);
    wire        b_den  = (b_exp == 0) && (b_man != 0);

    wire [23:0] b_mantissa;
    assign b_mantissa[23]    = b_zero ? 1'b0 : (b_den ? 1'b0 : 1'b1);
    assign b_mantissa[22:0]  = b_zero ? 23'd0 : (b_den ? {1'b0, b_man} : b_man);
    wire [8:0]  b_exponent = b_zero ? 9'd0 : (b_den ? 9'd1 : {1'b0, b_exp});

    // Multiply: sign, exponent add, mantissa multiply
    wire        mul_sign = a_sign ^ b_sign;
    wire [8:0]  mul_exp  = a_exponent + b_exponent - FP32_BIAS;
    wire [47:0] mul_man  = a_mantissa * b_mantissa;  // 24x24 = 48 bits

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
    reg [31:0] s2_result;
    reg        s2_valid;

    // Unpack c (the addend)
    wire        c_sign = s1_c[31];
    wire [7:0]  c_exp  = s1_c[30:23];
    wire [22:0] c_man  = s1_c[22:0];
    wire        c_zero = (c_exp == 0) && (c_man == 0);
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [23:0] c_mantissa;
    assign c_mantissa[23]    = c_zero ? 1'b0 : (c_den ? 1'b0 : 1'b1);
    assign c_mantissa[22:0]  = c_zero ? 23'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [8:0]  c_exponent = c_zero ? 9'd0 : (c_den ? 9'd1 : {1'b0, c_exp});

    // FP32 mantissa product: 24-bit x 24-bit = 48-bit product.
    // Both inputs have implicit 1 at bit 23, so the product has implicit 1
    // at bit 46.  Left-shift by 1 to align with c_mantissa (implicit 1 at bit 47).
    // If the shift overflows (mul_man[47]=1), the effective exponent is mul_exp+1.
    wire        mul_overflow = mul_man[47];
    wire [8:0]  mul_eff_exp  = mul_overflow ? (mul_exp + 9'd1) : mul_exp;

    // Determine result exponent
    wire [8:0]  add_exp = (mul_eff_exp > c_exponent) ? mul_eff_exp : c_exponent;

    // Align mantissas: both now have implicit 1 at bit 47
    wire [47:0] mul_man_aligned = (mul_eff_exp >= c_exponent) ?
        (mul_man << 1) : (mul_man << 1) >> (c_exponent - mul_eff_exp);
    wire [47:0] c_man_aligned   = (c_exponent > mul_eff_exp) ?
        {c_mantissa, 24'd0} : {c_mantissa, 24'd0} >> (mul_eff_exp - c_exponent);

    // Add (with sign/magnitude handling)
    wire        add_sign;
    wire [48:0] add_result;

    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [48:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    assign add_sign = (mul_sign == c_sign) ? mul_sign :
                      mul_ge_c ? mul_sign : c_sign;
    assign add_result = (mul_sign == c_sign) ?
        {1'b0, mul_man_aligned} + {1'b0, c_man_aligned} :
        abs_diff;

    // Normalize
    reg [47:0] norm_man;
    reg [8:0]  norm_exp;
    reg        norm_sign;
    reg [5:0]  lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[48]) begin
            // Overflow: shift right by 1, increment exponent
            norm_man = add_result[48:1];
            norm_exp = add_exp + 1;
        end else begin
            norm_man = add_result[47:0];
            norm_exp = add_exp;
            if (!norm_man[47]) begin
                lead_pos = 0;
                if (norm_man[46]) lead_pos = 1;
                else if (norm_man[45]) lead_pos = 2;
                else if (norm_man[44]) lead_pos = 3;
                else if (norm_man[43]) lead_pos = 4;
                else if (norm_man[42]) lead_pos = 5;
                else if (norm_man[41]) lead_pos = 6;
                else if (norm_man[40]) lead_pos = 7;
                else if (norm_man[39]) lead_pos = 8;
                else if (norm_man[38]) lead_pos = 9;
                else if (norm_man[37]) lead_pos = 10;
                else if (norm_man[36]) lead_pos = 11;
                else if (norm_man[35]) lead_pos = 12;
                else if (norm_man[34]) lead_pos = 13;
                else if (norm_man[33]) lead_pos = 14;
                else if (norm_man[32]) lead_pos = 15;
                else if (norm_man[31]) lead_pos = 16;
                else if (norm_man[30]) lead_pos = 17;
                else if (norm_man[29]) lead_pos = 18;
                else if (norm_man[28]) lead_pos = 19;
                else if (norm_man[27]) lead_pos = 20;
                else if (norm_man[26]) lead_pos = 21;
                else if (norm_man[25]) lead_pos = 22;
                else if (norm_man[24]) lead_pos = 23;
                else if (norm_man[23]) lead_pos = 24;
                else if (norm_man[22]) lead_pos = 25;
                else if (norm_man[21]) lead_pos = 26;
                else if (norm_man[20]) lead_pos = 27;
                else if (norm_man[19]) lead_pos = 28;
                else if (norm_man[18]) lead_pos = 29;
                else if (norm_man[17]) lead_pos = 30;
                else if (norm_man[16]) lead_pos = 31;
                else if (norm_man[15]) lead_pos = 32;
                else if (norm_man[14]) lead_pos = 33;
                else if (norm_man[13]) lead_pos = 34;
                else if (norm_man[12]) lead_pos = 35;
                else if (norm_man[11]) lead_pos = 36;
                else if (norm_man[10]) lead_pos = 37;
                else if (norm_man[9])  lead_pos = 38;
                else if (norm_man[8])  lead_pos = 39;
                else if (norm_man[7])  lead_pos = 40;
                else if (norm_man[6])  lead_pos = 41;
                else if (norm_man[5])  lead_pos = 42;
                else if (norm_man[4])  lead_pos = 43;
                else if (norm_man[3])  lead_pos = 44;
                else if (norm_man[2])  lead_pos = 45;
                else if (norm_man[1])  lead_pos = 46;
                else                   lead_pos = 47;
                shift = lead_pos;
                norm_man = norm_man << shift;
                norm_exp = add_exp - shift;
            end
        end
    end

    // Pack result
    wire [31:0] packed_result;
    assign packed_result = (norm_exp <= 0) ? FP32_ZERO :  // underflow -> zero
                          (norm_exp >= 255) ? FP32_INF :   // overflow -> infinity
                          {norm_sign, norm_exp[7:0], norm_man[46:24]};

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
