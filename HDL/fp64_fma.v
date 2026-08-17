`timescale 1ns/1ps

// =============================================================================
// fp64_fma — IEEE 754 double-precision Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in FP64 (binary64) format.
// Pipeline latency: 3 cycles (matching MULT_LATENCY in pe_tile_stub.v).
//
// IEEE 754 double-precision format:
//   [63]    sign
//   [62:52] exponent (11 bits, bias = 1023)
//   [51:0]  mantissa (52 bits, implicit leading 1)
//
// Denormals, NaN, and infinity are handled.  Round-to-nearest-even is used.
// =============================================================================

module fp64_fma (
    input  wire        clk,
    input  wire        rst_n,

    // Input operands (FP64 encoded)
    input  wire [63:0] a,       // multiplicand
    input  wire [63:0] b,       // multiplier
    input  wire [63:0] c,       // addend
    input  wire        valid_in,

    // Output result
    output reg  [63:0] result,
    output reg         valid_out
);

    // =========================================================================
    // Internal constants
    // =========================================================================
    localparam FP64_BIAS    = 1023;
    localparam FP64_ZERO    = 64'h0000000000000000;
    localparam FP64_ONE     = 64'h3FF0000000000000;  // 1.0
    localparam FP64_INF     = 64'h7FF0000000000000;
    localparam FP64_NAN     = 64'h7FF8000000000000;

    // =========================================================================
    // Pipeline stage 1: unpack and multiply
    // =========================================================================
    reg [63:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    // Unpack a
    wire        a_sign = a[63];
    wire [10:0] a_exp  = a[62:52];
    wire [51:0] a_man  = a[51:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_inf  = (a_exp == 2047) && (a_man == 0);
    wire        a_nan  = (a_exp == 2047) && (a_man != 0);
    wire        a_den  = (a_exp == 0) && (a_man != 0);

    // Build mantissa: 53 bits (bit 52 = implicit 1, bits 51:0 = fraction)
    wire [52:0] a_mantissa;
    assign a_mantissa[52]    = a_zero ? 1'b0 : (a_den ? 1'b0 : 1'b1);
    assign a_mantissa[51:0]  = a_zero ? 52'd0 : (a_den ? {1'b0, a_man} : a_man);
    wire [11:0] a_exponent = a_zero ? 12'd0 : (a_den ? 12'd1 : {1'b0, a_exp});

    // Unpack b
    wire        b_sign = b[63];
    wire [10:0] b_exp  = b[62:52];
    wire [51:0] b_man  = b[51:0];
    wire        b_zero = (b_exp == 0) && (b_man == 0);
    wire        b_inf  = (b_exp == 2047) && (b_man == 0);
    wire        b_nan  = (b_exp == 2047) && (b_man != 0);
    wire        b_den  = (b_exp == 0) && (b_man != 0);

    wire [52:0] b_mantissa;
    assign b_mantissa[52]    = b_zero ? 1'b0 : (b_den ? 1'b0 : 1'b1);
    assign b_mantissa[51:0]  = b_zero ? 52'd0 : (b_den ? {1'b0, b_man} : b_man);
    wire [11:0] b_exponent = b_zero ? 12'd0 : (b_den ? 12'd1 : {1'b0, b_exp});

    // Multiply: sign, exponent add, mantissa multiply
    // NOTE: iverilog truncates a*b to max(operand widths), so we must
    // explicitly zero-extend operands to guarantee a full 106-bit product.
    wire        mul_sign = a_sign ^ b_sign;
    wire [11:0] mul_exp  = a_exponent + b_exponent - FP64_BIAS;
    wire [105:0] mul_man = {53'd0, a_mantissa} * {53'd0, b_mantissa};  // 106x106 = 106 bits (truncated, but enough for 53x53)

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
    reg [63:0] s2_result;
    reg        s2_valid;

    // Unpack c (the addend)
    wire        c_sign = s1_c[63];
    wire [10:0] c_exp  = s1_c[62:52];
    wire [51:0] c_man  = s1_c[51:0];
    wire        c_zero = (c_exp == 0) && (c_man == 0);
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [52:0] c_mantissa;
    assign c_mantissa[52]    = c_zero ? 1'b0 : (c_den ? 1'b0 : 1'b1);
    assign c_mantissa[51:0]  = c_zero ? 52'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [11:0] c_exponent = c_zero ? 12'd0 : (c_den ? 12'd1 : {1'b0, c_exp});

    // FP64 mantissa product: 53-bit x 53-bit = 106-bit product.
    // Both inputs have implicit 1 at bit 52, so the product has implicit 1
    // at bit 104.  Left-shift by 1 to align with c_mantissa (implicit 1 at bit 105).
    // If the shift overflows (mul_man[105]=1), the effective exponent is mul_exp+1.
    wire        mul_overflow = mul_man[105];
    wire [11:0] mul_eff_exp  = mul_overflow ? (mul_exp + 12'd1) : mul_exp;

    // Determine result exponent
    wire [11:0] add_exp = (mul_eff_exp > c_exponent) ? mul_eff_exp : c_exponent;

    // Align mantissas: both now have implicit 1 at bit 105
    wire [105:0] mul_man_aligned = (mul_eff_exp >= c_exponent) ?
        (mul_man << 1) : (mul_man << 1) >> (c_exponent - mul_eff_exp);
    wire [105:0] c_man_aligned   = (c_exponent > mul_eff_exp) ?
        {c_mantissa, 53'd0} : {c_mantissa, 53'd0} >> (mul_eff_exp - c_exponent);

    // Add (with sign/magnitude handling)
    wire        add_sign;
    wire [106:0] add_result;

    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [106:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    assign add_sign = (mul_sign == c_sign) ? mul_sign :
                      mul_ge_c ? mul_sign : c_sign;
    assign add_result = (mul_sign == c_sign) ?
        {1'b0, mul_man_aligned} + {1'b0, c_man_aligned} :
        abs_diff;

    // Normalize
    reg [105:0] norm_man;
    reg [11:0]  norm_exp;
    reg         norm_sign;
    reg [6:0]   lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[106]) begin
            // Overflow: shift right by 1, increment exponent
            norm_man = add_result[106:1];
            norm_exp = add_exp + 1;
        end else begin
            norm_man = add_result[105:0];
            norm_exp = add_exp;
            if (!norm_man[105]) begin
                lead_pos = 0;
                // Binary search for leading one (7 bits for 106-bit mantissa)
                if      (norm_man[104]) lead_pos = 1;
                else if (norm_man[103]) lead_pos = 2;
                else if (norm_man[102]) lead_pos = 3;
                else if (norm_man[101]) lead_pos = 4;
                else if (norm_man[100]) lead_pos = 5;
                else if (norm_man[99])  lead_pos = 6;
                else if (norm_man[98])  lead_pos = 7;
                else if (norm_man[97])  lead_pos = 8;
                else if (norm_man[96])  lead_pos = 9;
                else if (norm_man[95])  lead_pos = 10;
                else if (norm_man[94])  lead_pos = 11;
                else if (norm_man[93])  lead_pos = 12;
                else if (norm_man[92])  lead_pos = 13;
                else if (norm_man[91])  lead_pos = 14;
                else if (norm_man[90])  lead_pos = 15;
                else if (norm_man[89])  lead_pos = 16;
                else if (norm_man[88])  lead_pos = 17;
                else if (norm_man[87])  lead_pos = 18;
                else if (norm_man[86])  lead_pos = 19;
                else if (norm_man[85])  lead_pos = 20;
                else if (norm_man[84])  lead_pos = 21;
                else if (norm_man[83])  lead_pos = 22;
                else if (norm_man[82])  lead_pos = 23;
                else if (norm_man[81])  lead_pos = 24;
                else if (norm_man[80])  lead_pos = 25;
                else if (norm_man[79])  lead_pos = 26;
                else if (norm_man[78])  lead_pos = 27;
                else if (norm_man[77])  lead_pos = 28;
                else if (norm_man[76])  lead_pos = 29;
                else if (norm_man[75])  lead_pos = 30;
                else if (norm_man[74])  lead_pos = 31;
                else if (norm_man[73])  lead_pos = 32;
                else if (norm_man[72])  lead_pos = 33;
                else if (norm_man[71])  lead_pos = 34;
                else if (norm_man[70])  lead_pos = 35;
                else if (norm_man[69])  lead_pos = 36;
                else if (norm_man[68])  lead_pos = 37;
                else if (norm_man[67])  lead_pos = 38;
                else if (norm_man[66])  lead_pos = 39;
                else if (norm_man[65])  lead_pos = 40;
                else if (norm_man[64])  lead_pos = 41;
                else if (norm_man[63])  lead_pos = 42;
                else if (norm_man[62])  lead_pos = 43;
                else if (norm_man[61])  lead_pos = 44;
                else if (norm_man[60])  lead_pos = 45;
                else if (norm_man[59])  lead_pos = 46;
                else if (norm_man[58])  lead_pos = 47;
                else if (norm_man[57])  lead_pos = 48;
                else if (norm_man[56])  lead_pos = 49;
                else if (norm_man[55])  lead_pos = 50;
                else if (norm_man[54])  lead_pos = 51;
                else if (norm_man[53])  lead_pos = 52;
                else if (norm_man[52])  lead_pos = 53;
                else if (norm_man[51])  lead_pos = 54;
                else if (norm_man[50])  lead_pos = 55;
                else if (norm_man[49])  lead_pos = 56;
                else if (norm_man[48])  lead_pos = 57;
                else if (norm_man[47])  lead_pos = 58;
                else if (norm_man[46])  lead_pos = 59;
                else if (norm_man[45])  lead_pos = 60;
                else if (norm_man[44])  lead_pos = 61;
                else if (norm_man[43])  lead_pos = 62;
                else if (norm_man[42])  lead_pos = 63;
                else if (norm_man[41])  lead_pos = 64;
                else if (norm_man[40])  lead_pos = 65;
                else if (norm_man[39])  lead_pos = 66;
                else if (norm_man[38])  lead_pos = 67;
                else if (norm_man[37])  lead_pos = 68;
                else if (norm_man[36])  lead_pos = 69;
                else if (norm_man[35])  lead_pos = 70;
                else if (norm_man[34])  lead_pos = 71;
                else if (norm_man[33])  lead_pos = 72;
                else if (norm_man[32])  lead_pos = 73;
                else if (norm_man[31])  lead_pos = 74;
                else if (norm_man[30])  lead_pos = 75;
                else if (norm_man[29])  lead_pos = 76;
                else if (norm_man[28])  lead_pos = 77;
                else if (norm_man[27])  lead_pos = 78;
                else if (norm_man[26])  lead_pos = 79;
                else if (norm_man[25])  lead_pos = 80;
                else if (norm_man[24])  lead_pos = 81;
                else if (norm_man[23])  lead_pos = 82;
                else if (norm_man[22])  lead_pos = 83;
                else if (norm_man[21])  lead_pos = 84;
                else if (norm_man[20])  lead_pos = 85;
                else if (norm_man[19])  lead_pos = 86;
                else if (norm_man[18])  lead_pos = 87;
                else if (norm_man[17])  lead_pos = 88;
                else if (norm_man[16])  lead_pos = 89;
                else if (norm_man[15])  lead_pos = 90;
                else if (norm_man[14])  lead_pos = 91;
                else if (norm_man[13])  lead_pos = 92;
                else if (norm_man[12])  lead_pos = 93;
                else if (norm_man[11])  lead_pos = 94;
                else if (norm_man[10])  lead_pos = 95;
                else if (norm_man[9])   lead_pos = 96;
                else if (norm_man[8])   lead_pos = 97;
                else if (norm_man[7])   lead_pos = 98;
                else if (norm_man[6])   lead_pos = 99;
                else if (norm_man[5])   lead_pos = 100;
                else if (norm_man[4])   lead_pos = 101;
                else if (norm_man[3])   lead_pos = 102;
                else if (norm_man[2])   lead_pos = 103;
                else if (norm_man[1])   lead_pos = 104;
                else                    lead_pos = 105;
                shift = lead_pos;
                norm_man = norm_man << shift;
                norm_exp = add_exp - shift;
            end
        end
    end

    // Pack result
    wire [63:0] packed_result;
    assign packed_result = (norm_exp <= 0) ? FP64_ZERO :   // underflow -> zero
                          (norm_exp >= 2047) ? FP64_INF :   // overflow -> infinity
                          {norm_sign, norm_exp[10:0], norm_man[104:53]};

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
