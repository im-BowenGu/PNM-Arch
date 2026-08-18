`timescale 1ns/1ps

// =============================================================================
// fp64_fma — IEEE 754 double-precision Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in FP64 (binary64) format.
// Pipeline latency: 3 cycles.
//
// IEEE 754 double-precision format:
//   [63]    sign
//   [62:52] exponent (11 bits, bias = 1023)
//   [51:0]  mantissa (52 bits, implicit leading 1)
//
// Fixes applied:
//   1. Pipeline: multiply results registered into stage 1
//   2. Underflow: signed norm_exp prevents unsigned wrap
//   3. Rounding: round-to-nearest-even
//   4. Special cases: NaN, Inf, zero*Inf
// =============================================================================

module fp64_fma (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire [63:0] c,
    input  wire        valid_in,
    output reg  [63:0] result,
    output reg         valid_out
);

    localparam FP64_BIAS = 1023;
    localparam FP64_ZERO = 64'h0000000000000000;
    localparam FP64_INF  = 64'h7FF0000000000000;
    localparam FP64_NAN  = 64'h7FF8000000000000;

    // =========================================================================
    // Pipeline stage 1
    // =========================================================================
    reg [63:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    reg s1_a_nan, s1_b_nan, s1_c_nan;
    reg s1_a_inf, s1_b_inf, s1_c_inf;
    reg s1_a_zero, s1_b_zero, s1_c_zero;

    reg [105:0] s1_mul_man;
    reg [11:0]  s1_mul_exp;
    reg         s1_mul_sign;
    reg         s1_mul_overflow;

    // Unpack a
    wire         a_sign_w = a[63];
    wire [10:0]  a_exp_w  = a[62:52];
    wire [51:0]  a_man_w  = a[51:0];
    wire         a_zero_w = (a == 64'h0000000000000000);
    wire         a_den_w  = (a_exp_w == 0) && (a_man_w != 0);

    wire [52:0] a_mantissa_w;
    assign a_mantissa_w[52]   = (a_zero_w || a_den_w) ? 1'b0 : 1'b1;
    assign a_mantissa_w[51:0] = a_zero_w ? 52'd0 : (a_den_w ? {1'b0, a_man_w} : a_man_w);
    wire [11:0] a_exponent_w = a_zero_w ? 12'd0 : (a_den_w ? 12'd1 : {1'b0, a_exp_w});

    // Unpack b
    wire         b_sign_w = b[63];
    wire [10:0]  b_exp_w  = b[62:52];
    wire [51:0]  b_man_w  = b[51:0];
    wire         b_zero_w = (b == 64'h0000000000000000);
    wire         b_den_w  = (b_exp_w == 0) && (b_man_w != 0);

    wire [52:0] b_mantissa_w;
    assign b_mantissa_w[52]   = (b_zero_w || b_den_w) ? 1'b0 : 1'b1;
    assign b_mantissa_w[51:0] = b_zero_w ? 52'd0 : (b_den_w ? {1'b0, b_man_w} : b_man_w);
    wire [11:0] b_exponent_w = b_zero_w ? 12'd0 : (b_den_w ? 12'd1 : {1'b0, b_exp_w});

    // Multiply (explicit zero-extend for iverilog)
    wire         mul_sign_w = a_sign_w ^ b_sign_w;
    wire [11:0]  mul_exp_w  = a_exponent_w + b_exponent_w - FP64_BIAS;
    wire [105:0] mul_man_w  = {53'd0, a_mantissa_w} * {53'd0, b_mantissa_w};
    wire         mul_ovf_w  = mul_man_w[105];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_a <= 0; s1_b <= 0; s1_c <= 0;
            s1_valid <= 0;
            s1_a_nan <= 0; s1_b_nan <= 0; s1_c_nan <= 0;
            s1_a_inf <= 0; s1_b_inf <= 0; s1_c_inf <= 0;
            s1_a_zero <= 0; s1_b_zero <= 0; s1_c_zero <= 0;
            s1_mul_man <= 0; s1_mul_exp <= 0;
            s1_mul_sign <= 0; s1_mul_overflow <= 0;
        end else begin
            s1_a <= a; s1_b <= b; s1_c <= c;
            s1_valid <= valid_in;
            s1_a_nan   <= (a[62:52] == 11'd2047) && (a[51:0] != 52'd0);
            s1_b_nan   <= (b[62:52] == 11'd2047) && (b[51:0] != 52'd0);
            s1_c_nan   <= (c[62:52] == 11'd2047) && (c[51:0] != 52'd0);
            s1_a_inf   <= (a[62:52] == 11'd2047) && (a[51:0] == 52'd0);
            s1_b_inf   <= (b[62:52] == 11'd2047) && (b[51:0] == 52'd0);
            s1_c_inf   <= (c[62:52] == 11'd2047) && (c[51:0] == 52'd0);
            s1_a_zero  <= (a == 64'h0000000000000000);
            s1_b_zero  <= (b == 64'h0000000000000000);
            s1_c_zero  <= (c == 64'h0000000000000000);
            s1_mul_man      <= mul_man_w;
            s1_mul_exp      <= mul_exp_w;
            s1_mul_sign     <= mul_sign_w;
            s1_mul_overflow <= mul_ovf_w;
        end
    end

    // =========================================================================
    // Pipeline stage 2
    // =========================================================================

    // Unpack s1_c
    wire         c_sign = s1_c[63];
    wire [10:0]  c_exp  = s1_c[62:52];
    wire [51:0]  c_man  = s1_c[51:0];
    wire         c_den  = (c_exp == 0) && (c_man != 0);

    wire [52:0] c_mantissa;
    assign c_mantissa[52]   = (s1_c_zero || c_den) ? 1'b0 : 1'b1;
    assign c_mantissa[51:0] = s1_c_zero ? 52'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [11:0] c_exponent = s1_c_zero ? 12'd0 : (c_den ? 12'd1 : {1'b0, c_exp});

    wire [11:0] mul_exp_eff = s1_mul_overflow ? (s1_mul_exp + 12'd1) : s1_mul_exp;
    wire [11:0] add_exp = (mul_exp_eff > c_exponent) ? mul_exp_eff : c_exponent;

    // Align mantissas: implicit 1 at bit 105
    wire [105:0] mul_man_aligned = (mul_exp_eff >= c_exponent) ?
        (s1_mul_man << 1) :
        (s1_mul_man << 1) >> (c_exponent - mul_exp_eff);
    wire [105:0] c_man_aligned = (c_exponent > mul_exp_eff) ?
        ({c_mantissa, 53'd0}) :
        ({c_mantissa, 53'd0} >> (mul_exp_eff - c_exponent));

    // Add
    wire         mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [106:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    wire         add_sign = (s1_mul_sign == c_sign) ? s1_mul_sign :
                            mul_ge_c ? s1_mul_sign : c_sign;
    wire [106:0] add_result = (s1_mul_sign == c_sign) ?
        ({1'b0, mul_man_aligned} + {1'b0, c_man_aligned}) :
        abs_diff;

    // Normalize
    reg [105:0] norm_man;
    reg signed [12:0] norm_exp;
    reg         norm_sign;
    reg [6:0]   lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[106]) begin
            norm_man = add_result[106:1];
            norm_exp = {1'b0, add_exp} + 13'd1;
        end else begin
            norm_man = add_result[105:0];
            norm_exp = {1'b0, add_exp};
            if (!norm_man[105]) begin
                lead_pos = 0;
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
                norm_exp = norm_exp - shift;
            end
        end
    end

    // Round-to-nearest-even
    // Mantissa field: norm_man[104:53] (52 bits)
    // Guard: [52], Round: [51], Sticky: |[50:0]
    wire guard  = norm_man[52];
    wire round  = norm_man[51];
    wire sticky = |norm_man[50:0];
    wire round_up = guard & (round | sticky | norm_man[53]);

    wire [105:0] rounded_man = norm_man + (round_up ? 106'h0000000000000000001000000 : 106'd0);  // add 1 at bit 52
    wire rounded_carry = ~rounded_man[105] & norm_man[105];

    wire [105:0] final_man = rounded_carry ? 106'h0200000000000000000000000 : rounded_man;  // 1<<105
    wire [12:0]  final_exp = rounded_carry ? (norm_exp + 13'd1) : norm_exp;

    // Pack result
    wire result_underflow = (norm_exp < 0) || (norm_exp == 0 && !rounded_carry);
    wire result_overflow  = (final_exp >= 2047);
    wire [63:0] packed_result;
    assign packed_result = result_underflow ? FP64_ZERO :
                           result_overflow  ? FP64_INF  :
                           {norm_sign, final_exp[10:0], final_man[104:53]};

    // Special cases
    wire any_nan = s1_a_nan | s1_b_nan | s1_c_nan;
    wire mul_inf_zero = (s1_a_inf & s1_b_zero) | (s1_b_inf & s1_a_zero);
    wire mul_inf = s1_a_inf | s1_b_inf;
    wire add_inf = s1_c_inf;
    wire inf_add_nan = mul_inf & add_inf & (s1_mul_sign != c_sign);

    wire is_special = any_nan | mul_inf_zero | mul_inf | add_inf;

    wire [63:0] special_result =
        any_nan      ? FP64_NAN :
        mul_inf_zero ? FP64_NAN :
        inf_add_nan  ? FP64_NAN :
        mul_inf      ? {s1_mul_sign, 11'd2047, 52'd0} :
        add_inf      ? s1_c :
                       packed_result;

    reg [63:0] s2_result;
    reg        s2_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_result <= 0;
            s2_valid  <= 0;
        end else begin
            s2_result <= is_special ? special_result : packed_result;
            s2_valid  <= s1_valid;
        end
    end

    // Stage 3
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
