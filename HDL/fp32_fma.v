`timescale 1ns/1ps

// =============================================================================
// fp32_fma — IEEE 754 single-precision Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in FP32 (binary32) format.
// Pipeline latency: 3 cycles.
//
// IEEE 754 single-precision format:
//   [31]    sign
//   [30:23] exponent (8 bits, bias = 127)
//   [22:0]  mantissa (23 bits, implicit leading 1)
//
// Fixes applied:
//   1. Pipeline: multiply results registered into stage 1
//   2. Underflow: signed norm_exp prevents unsigned wrap
//   3. Rounding: round-to-nearest-even
//   4. Special cases: NaN, Inf, zero*Inf
// =============================================================================

module fp32_fma (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    input  wire        valid_in,
    output reg  [31:0] result,
    output reg         valid_out
);

    localparam FP32_BIAS = 127;
    localparam FP32_ZERO = 32'h00000000;
    localparam FP32_INF  = 32'h7F800000;
    localparam FP32_NAN  = 32'h7FC00000;

    // =========================================================================
    // Pipeline stage 1
    // =========================================================================
    reg [31:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    reg s1_a_nan, s1_b_nan, s1_c_nan;
    reg s1_a_inf, s1_b_inf, s1_c_inf;
    reg s1_a_zero, s1_b_zero, s1_c_zero;

    reg [47:0] s1_mul_man;
    reg signed [9:0] s1_mul_exp;
    reg        s1_mul_sign;
    reg        s1_mul_overflow;

    // Unpack a
    wire        a_sign_w = a[31];
    wire [7:0]  a_exp_w  = a[30:23];
    wire [22:0] a_man_w  = a[22:0];
    wire        a_zero_w = (a[30:0] == 31'h00000000);
    wire        a_den_w  = (a_exp_w == 0) && (a_man_w != 0);

    wire [23:0] a_mantissa_w;
    assign a_mantissa_w[23]   = (a_zero_w || a_den_w) ? 1'b0 : 1'b1;
    assign a_mantissa_w[22:0] = a_zero_w ? 23'd0 : (a_den_w ? {1'b0, a_man_w} : a_man_w);
    wire [8:0]  a_exponent_w = a_zero_w ? 9'd0 : (a_den_w ? 9'd1 : {1'b0, a_exp_w});

    // Unpack b
    wire        b_sign_w = b[31];
    wire [7:0]  b_exp_w  = b[30:23];
    wire [22:0] b_man_w  = b[22:0];
    wire        b_zero_w = (b[30:0] == 31'h00000000);
    wire        b_den_w  = (b_exp_w == 0) && (b_man_w != 0);

    wire [23:0] b_mantissa_w;
    assign b_mantissa_w[23]   = (b_zero_w || b_den_w) ? 1'b0 : 1'b1;
    assign b_mantissa_w[22:0] = b_zero_w ? 23'd0 : (b_den_w ? {1'b0, b_man_w} : b_man_w);
    wire [8:0]  b_exponent_w = b_zero_w ? 9'd0 : (b_den_w ? 9'd1 : {1'b0, b_exp_w});

    // Multiply
    wire        mul_sign_w = a_sign_w ^ b_sign_w;
    wire signed [9:0] mul_exp_w = $signed({1'b0, a_exponent_w}) + $signed({1'b0, b_exponent_w}) - 10'sd127;
    wire [47:0] mul_man_w  = a_mantissa_w * b_mantissa_w;
    wire        mul_ovf_w  = mul_man_w[47];

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
            s1_a_nan   <= (a[30:23] == 8'd255) && (a[22:0] != 23'd0);
            s1_b_nan   <= (b[30:23] == 8'd255) && (b[22:0] != 23'd0);
            s1_c_nan   <= (c[30:23] == 8'd255) && (c[22:0] != 23'd0);
            s1_a_inf   <= (a[30:23] == 8'd255) && (a[22:0] == 23'd0);
            s1_b_inf   <= (b[30:23] == 8'd255) && (b[22:0] == 23'd0);
            s1_c_inf   <= (c[30:23] == 8'd255) && (c[22:0] == 23'd0);
            s1_a_zero  <= (a[30:0] == 31'h00000000);
            s1_b_zero  <= (b[30:0] == 31'h00000000);
            s1_c_zero  <= (c[30:0] == 31'h00000000);
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
    wire        c_sign = s1_c[31];
    wire [7:0]  c_exp  = s1_c[30:23];
    wire [22:0] c_man  = s1_c[22:0];
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [23:0] c_mantissa;
    assign c_mantissa[23]   = (s1_c_zero || c_den) ? 1'b0 : 1'b1;
    assign c_mantissa[22:0] = s1_c_zero ? 23'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [8:0]  c_exponent = s1_c_zero ? 9'd0 : (c_den ? 9'd1 : {1'b0, c_exp});

    wire signed [9:0] mul_exp_eff = s1_mul_overflow ? (s1_mul_exp + 10'sd1) : s1_mul_exp;
    wire signed [9:0] add_exp = (mul_exp_eff > $signed({1'b0, c_exponent})) ? mul_exp_eff : $signed({1'b0, c_exponent});
    wire signed [9:0] exp_diff = mul_exp_eff - $signed({1'b0, c_exponent});

    // Align mantissas: implicit 1 at bit 47
    wire [47:0] mul_man_aligned = (exp_diff >= 0) ?
        (s1_mul_man << 1) :
        (s1_mul_man << 1) >> (-exp_diff);
    wire [47:0] c_man_aligned = (exp_diff < 0) ?
        ({c_mantissa, 24'd0}) :
        ({c_mantissa, 24'd0} >> exp_diff);

    // Add
    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [48:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    wire        add_sign = (s1_mul_sign == c_sign) ? s1_mul_sign :
                           mul_ge_c ? s1_mul_sign : c_sign;
    wire [48:0] add_result = (s1_mul_sign == c_sign) ?
        ({1'b0, mul_man_aligned} + {1'b0, c_man_aligned}) :
        abs_diff;

    // Normalize
    reg [47:0] norm_man;
    reg signed [9:0] norm_exp;
    reg        norm_sign;
    reg [5:0]  lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[48]) begin
            norm_man = add_result[48:1];
            norm_exp = {1'b0, add_exp} + 10'd1;
        end else begin
            norm_man = add_result[47:0];
            norm_exp = {1'b0, add_exp};
            if (!norm_man[47]) begin
                lead_pos = 0;
                if      (norm_man[46]) lead_pos = 1;
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
                norm_exp = norm_exp - shift;
            end
        end
    end

    // Round-to-nearest-even
    // Mantissa field: norm_man[46:24] (23 bits)
    // Guard: [23], Round: [22], Sticky: |[21:0]
    wire guard  = norm_man[23];
    wire round  = norm_man[22];
    wire sticky = |norm_man[21:0];
    wire round_up = guard & (round | sticky | norm_man[24]);

    wire [47:0] rounded_man = norm_man + (round_up ? 48'h000000000800 : 48'd0);  // add 1 at bit 23
    wire rounded_carry = ~rounded_man[47] & norm_man[47];

    wire [47:0] final_man = rounded_carry ? 48'h008000000000 : rounded_man;  // 1<<47
    wire [9:0]  final_exp = rounded_carry ? (norm_exp + 10'd1) : norm_exp;

    // Pack result
    wire result_underflow = (norm_exp < 0) || (norm_exp == 0 && !rounded_carry);
    wire result_overflow  = (final_exp >= 255);
    wire [31:0] packed_result;
    assign packed_result = result_underflow ? (norm_sign ? 32'h80000000 : FP32_ZERO) :
                           result_overflow  ? {norm_sign, 8'd255, 23'd0} :
                           {norm_sign, final_exp[7:0], final_man[46:24]};

    // Special cases
    wire any_nan = s1_a_nan | s1_b_nan | s1_c_nan;
    wire mul_inf_zero = (s1_a_inf & s1_b_zero) | (s1_b_inf & s1_a_zero);
    wire mul_inf = s1_a_inf | s1_b_inf;
    wire add_inf = s1_c_inf;
    wire inf_add_nan = mul_inf & add_inf & (s1_mul_sign != c_sign);

    wire is_special = any_nan | mul_inf_zero | mul_inf | add_inf;

    wire [31:0] special_result =
        any_nan      ? FP32_NAN :
        mul_inf_zero ? FP32_NAN :
        inf_add_nan  ? FP32_NAN :
        mul_inf      ? {s1_mul_sign, 8'd255, 23'd0} :
        add_inf      ? s1_c :
                       packed_result;

    reg [31:0] s2_result;
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
