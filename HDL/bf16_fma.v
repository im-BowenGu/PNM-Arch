`timescale 1ns/1ps

// =============================================================================
// bf16_fma — Brain Floating Point 16 Fused Multiply-Add unit
//
// Computes: result = (a * b) + c  in BF16 format.
// Pipeline latency: 3 cycles.
//
// BF16 format:
//   [15]    sign
//   [14:7]  exponent (8 bits, bias = 127)
//   [6:0]   mantissa (7 bits, implicit leading 1)
//
// Fixes applied (same as fp16_fma):
//   1. Pipeline: multiply results registered into stage 1
//   2. Underflow: signed norm_exp prevents unsigned wrap
//   3. Rounding: round-to-nearest-even
//   4. Special cases: NaN, Inf, zero*Inf
// =============================================================================

module bf16_fma (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire [15:0] c,
    input  wire        valid_in,
    output reg  [15:0] result,
    output reg         valid_out
);

    localparam BF16_BIAS = 127;
    localparam BF16_ZERO = 16'h0000;
    localparam BF16_INF  = 16'h7F80;
    localparam BF16_NAN  = 16'h7FC0;

    // =========================================================================
    // Pipeline stage 1: register inputs + detect special cases + multiply
    // =========================================================================
    reg [15:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    reg s1_a_nan, s1_b_nan, s1_c_nan;
    reg s1_a_inf, s1_b_inf, s1_c_inf;
    reg s1_a_zero, s1_b_zero, s1_c_zero;

    // Registered multiply results
    reg [15:0] s1_mul_man;
    reg [8:0]  s1_mul_exp;
    reg        s1_mul_sign;
    reg        s1_mul_overflow;

    // Unpack a
    wire        a_sign_w = a[15];
    wire [7:0]  a_exp_w  = a[14:7];
    wire [6:0]  a_man_w  = a[6:0];
    wire        a_zero_w = (a == 16'h0000);
    wire        a_den_w  = (a_exp_w == 0) && (a_man_w != 0);

    wire [7:0]  a_mantissa_w;
    assign a_mantissa_w[7]   = (a_zero_w || a_den_w) ? 1'b0 : 1'b1;
    assign a_mantissa_w[6:0] = a_zero_w ? 7'd0 : (a_den_w ? {1'b0, a_man_w} : a_man_w);
    wire [8:0]  a_exponent_w = a_zero_w ? 9'd0 : (a_den_w ? 9'd1 : {1'b0, a_exp_w});

    // Unpack b
    wire        b_sign_w = b[15];
    wire [7:0]  b_exp_w  = b[14:7];
    wire [6:0]  b_man_w  = b[6:0];
    wire        b_zero_w = (b == 16'h0000);
    wire        b_den_w  = (b_exp_w == 0) && (b_man_w != 0);

    wire [7:0]  b_mantissa_w;
    assign b_mantissa_w[7]   = (b_zero_w || b_den_w) ? 1'b0 : 1'b1;
    assign b_mantissa_w[6:0] = b_zero_w ? 7'd0 : (b_den_w ? {1'b0, b_man_w} : b_man_w);
    wire [8:0]  b_exponent_w = b_zero_w ? 9'd0 : (b_den_w ? 9'd1 : {1'b0, b_exp_w});

    // Multiply
    wire        mul_sign_w = a_sign_w ^ b_sign_w;
    wire [8:0]  mul_exp_w  = a_exponent_w + b_exponent_w - BF16_BIAS;
    wire [15:0] mul_man_w  = a_mantissa_w * b_mantissa_w;
    wire        mul_ovf_w  = mul_man_w[15];

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
            s1_a_nan   <= (a[14:7] == 8'd255) && (a[6:0] != 7'd0);
            s1_b_nan   <= (b[14:7] == 8'd255) && (b[6:0] != 7'd0);
            s1_c_nan   <= (c[14:7] == 8'd255) && (c[6:0] != 7'd0);
            s1_a_inf   <= (a[14:7] == 8'd255) && (a[6:0] == 7'd0);
            s1_b_inf   <= (b[14:7] == 8'd255) && (b[6:0] == 7'd0);
            s1_c_inf   <= (c[14:7] == 8'd255) && (c[6:0] == 7'd0);
            s1_a_zero  <= (a == 16'h0000);
            s1_b_zero  <= (b == 16'h0000);
            s1_c_zero  <= (c == 16'h0000);
            s1_mul_man      <= mul_man_w;
            s1_mul_exp      <= mul_exp_w;
            s1_mul_sign     <= mul_sign_w;
            s1_mul_overflow <= mul_ovf_w;
        end
    end

    // =========================================================================
    // Pipeline stage 2: align, add, normalize, round, pack
    // =========================================================================

    // Unpack s1_c
    wire        c_sign = s1_c[15];
    wire [7:0]  c_exp  = s1_c[14:7];
    wire [6:0]  c_man  = s1_c[6:0];
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [7:0]  c_mantissa;
    assign c_mantissa[7]   = (s1_c_zero || c_den) ? 1'b0 : 1'b1;
    assign c_mantissa[6:0] = s1_c_zero ? 7'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [8:0]  c_exponent = s1_c_zero ? 9'd0 : (c_den ? 9'd1 : {1'b0, c_exp});

    wire [8:0]  mul_exp_eff = s1_mul_overflow ? (s1_mul_exp + 9'd1) : s1_mul_exp;
    wire [8:0]  add_exp = (mul_exp_eff > c_exponent) ? mul_exp_eff : c_exponent;

    // Align mantissas: implicit 1 at bit 15
    wire [15:0] mul_man_aligned = (mul_exp_eff >= c_exponent) ?
        (s1_mul_man << 1) :
        (s1_mul_man << 1) >> (c_exponent - mul_exp_eff);
    wire [15:0] c_man_aligned = (c_exponent > mul_exp_eff) ?
        ({c_mantissa, 8'd0}) :
        ({c_mantissa, 8'd0} >> (mul_exp_eff - c_exponent));

    // Add
    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [16:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    wire        add_sign = (s1_mul_sign == c_sign) ? s1_mul_sign :
                           mul_ge_c ? s1_mul_sign : c_sign;
    wire [16:0] add_result = (s1_mul_sign == c_sign) ?
        ({1'b0, mul_man_aligned} + {1'b0, c_man_aligned}) :
        abs_diff;

    // Normalize (signed exponent)
    reg [15:0] norm_man;
    reg signed [9:0] norm_exp;
    reg        norm_sign;
    reg [3:0]  lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[16]) begin
            norm_man = add_result[16:1];
            norm_exp = {1'b0, add_exp} + 10'd1;
        end else begin
            norm_man = add_result[15:0];
            norm_exp = {1'b0, add_exp};
            if (!norm_man[15]) begin
                lead_pos = 0;
                if      (norm_man[14]) lead_pos = 1;
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
                norm_exp = norm_exp - shift;
            end
        end
    end

    // Round-to-nearest-even
    // Mantissa field: norm_man[14:8] (7 bits)
    // Guard: [7], Round: [6], Sticky: |[5:0]
    wire guard  = norm_man[7];
    wire round  = norm_man[6];
    wire sticky = |norm_man[5:0];
    wire round_up = guard & (round | sticky | norm_man[8]);

    wire [15:0] rounded_man = norm_man + (round_up ? 16'd128 : 16'd0);  // add 1 at bit 7
    wire rounded_carry = ~rounded_man[15] & norm_man[15];

    wire [15:0] final_man = rounded_carry ? 16'h8000 : rounded_man;  // 1<<15
    wire [9:0]  final_exp = rounded_carry ? (norm_exp + 10'd1) : norm_exp;

    // Pack result
    wire result_underflow = (norm_exp < 0) || (norm_exp == 0 && !rounded_carry);
    wire result_overflow  = (final_exp >= 255);
    wire [15:0] packed_result;
    assign packed_result = result_underflow ? BF16_ZERO :
                           result_overflow  ? BF16_INF  :
                           {norm_sign, final_exp[7:0], final_man[14:8]};

    // Special cases
    wire any_nan = s1_a_nan | s1_b_nan | s1_c_nan;
    wire mul_inf_zero = (s1_a_inf & s1_b_zero) | (s1_b_inf & s1_a_zero);
    wire mul_inf = s1_a_inf | s1_b_inf;
    wire add_inf = s1_c_inf;
    wire inf_add_nan = mul_inf & add_inf & (s1_mul_sign != c_sign);

    wire is_special = any_nan | mul_inf_zero | mul_inf | add_inf;

    wire [15:0] special_result =
        any_nan      ? BF16_NAN :
        mul_inf_zero ? BF16_NAN :
        inf_add_nan  ? BF16_NAN :
        mul_inf      ? {s1_mul_sign, 8'd255, 7'd0} :
        add_inf      ? s1_c :
                       packed_result;

    reg [15:0] s2_result;
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
