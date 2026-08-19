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
// Fixes applied:
//   1. Pipeline: multiply results registered into stage 1 (s1_mul_*)
//   2. Underflow: signed norm_exp prevents unsigned wrap to infinity
//   3. Rounding: round-to-nearest-even with guard/round/sticky bits
//   4. Special cases: NaN, Inf, zero*Inf properly handled
// =============================================================================

module fp16_fma (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire [15:0] c,
    input  wire        valid_in,
    output reg  [15:0] result,
    output reg         valid_out
);

    localparam FP16_BIAS = 15;
    localparam FP16_ZERO = 16'h0000;
    localparam FP16_INF  = 16'h7C00;
    localparam FP16_NAN  = 16'h7E00;

    // =========================================================================
    // Pipeline stage 1: register inputs + detect special cases + multiply
    // =========================================================================
    reg [15:0] s1_a, s1_b, s1_c;
    reg        s1_valid;

    // Special case flags (registered with inputs)
    reg s1_a_nan, s1_b_nan, s1_c_nan;
    reg s1_a_inf, s1_b_inf, s1_c_inf;
    reg s1_a_zero, s1_b_zero, s1_c_zero;

    // Registered multiply results (fix #1: must travel with s1_c)
    reg [21:0] s1_mul_man;
    reg [6:0]  s1_mul_exp;
    reg        s1_mul_sign;
    reg        s1_mul_overflow;

    // Unpack a (combinational from current inputs)
    wire        a_sign_w = a[15];
    wire [4:0]  a_exp_w  = a[14:10];
    wire [9:0]  a_man_w  = a[9:0];
    wire        a_zero_w = (a[14:0] == 15'h0000);
    wire        a_den_w  = (a_exp_w == 0) && (a_man_w != 0);

    wire [10:0] a_mantissa_w;
    assign a_mantissa_w[10]   = (a_zero_w || a_den_w) ? 1'b0 : 1'b1;
    assign a_mantissa_w[9:0]  = a_zero_w ? 10'd0 : (a_den_w ? {1'b0, a_man_w} : a_man_w);
    wire [5:0]  a_exponent_w = a_zero_w ? 6'd0 : (a_den_w ? 6'd1 : {1'b0, a_exp_w});

    // Unpack b (combinational from current inputs)
    wire        b_sign_w = b[15];
    wire [4:0]  b_exp_w  = b[14:10];
    wire [9:0]  b_man_w  = b[9:0];
    wire        b_zero_w = (b[14:0] == 15'h0000);
    wire        b_den_w  = (b_exp_w == 0) && (b_man_w != 0);

    wire [10:0] b_mantissa_w;
    assign b_mantissa_w[10]   = (b_zero_w || b_den_w) ? 1'b0 : 1'b1;
    assign b_mantissa_w[9:0]  = b_zero_w ? 10'd0 : (b_den_w ? {1'b0, b_man_w} : b_man_w);
    wire [5:0]  b_exponent_w = b_zero_w ? 6'd0 : (b_den_w ? 6'd1 : {1'b0, b_exp_w});

    // Multiply (combinational, registered next cycle)
    // Bug fix #1: force exponent and mantissa to zero when either operand
    // is zero, preventing unsigned underflow of (0 + exp - 15) which wraps
    // to 113+ in 7-bit arithmetic.
    wire        mul_sign_w = a_sign_w ^ b_sign_w;
    wire [6:0]  mul_exp_w  = (a_zero_w || b_zero_w) ? 7'd0 :
                             (a_exponent_w + b_exponent_w - FP16_BIAS);
    wire [21:0] mul_man_w  = (a_zero_w || b_zero_w) ? 22'd0 :
                             (a_mantissa_w * b_mantissa_w);
    wire        mul_ovf_w  = mul_man_w[21];

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
            s1_a_nan   <= (a[14:10] == 5'd31) && (a[9:0] != 10'd0);
            s1_b_nan   <= (b[14:10] == 5'd31) && (b[9:0] != 10'd0);
            s1_c_nan   <= (c[14:10] == 5'd31) && (c[9:0] != 10'd0);
            s1_a_inf   <= (a[14:10] == 5'd31) && (a[9:0] == 10'd0);
            s1_b_inf   <= (b[14:10] == 5'd31) && (b[9:0] == 10'd0);
            s1_c_inf   <= (c[14:10] == 5'd31) && (c[9:0] == 10'd0);
            s1_a_zero  <= (a[14:0] == 15'h0000);
            s1_b_zero  <= (b[14:0] == 15'h0000);
            s1_c_zero  <= (c[14:0] == 15'h0000);
            s1_mul_man      <= mul_man_w;
            s1_mul_exp      <= mul_exp_w;
            s1_mul_sign     <= mul_sign_w;
            s1_mul_overflow <= mul_ovf_w;
        end
    end

    // =========================================================================
    // Pipeline stage 2: align, add, normalize, round, pack
    // =========================================================================

    // Unpack s1_c (the addend, from registered s1_c)
    wire        c_sign = s1_c[15];
    wire [4:0]  c_exp  = s1_c[14:10];
    wire [9:0]  c_man  = s1_c[9:0];
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [10:0] c_mantissa;
    assign c_mantissa[10]   = (s1_c_zero || c_den) ? 1'b0 : 1'b1;
    assign c_mantissa[9:0]  = s1_c_zero ? 10'd0 : (c_den ? {1'b0, c_man} : c_man);
    wire [5:0]  c_exponent = s1_c_zero ? 6'd0 : (c_den ? 6'd1 : {1'b0, c_exp});

    // Effective multiply exponent (from registered multiply results)
    wire [6:0]  mul_exp_eff = s1_mul_overflow ? (s1_mul_exp + 7'd1) : s1_mul_exp;

    // Result exponent: max(mul_exp_eff, c_exponent)
    wire [6:0]  add_exp = (mul_exp_eff > {1'b0, c_exponent}) ? mul_exp_eff : {1'b0, c_exponent};

    // Align mantissas: both have implicit 1 at bit 21
    // Bug fix #2: only shift left by 1 when product did not overflow bit 20;
    // when s1_mul_overflow=1, bit 21 is already set and <<1 would truncate it.
    wire [21:0] mul_man_norm = s1_mul_overflow ? s1_mul_man : (s1_mul_man << 1);
    wire [21:0] mul_man_aligned = (mul_exp_eff >= {1'b0, c_exponent}) ?
        mul_man_norm :
        (mul_man_norm >> ({1'b0, c_exponent} - mul_exp_eff));
    wire [21:0] c_man_aligned = ({1'b0, c_exponent} > mul_exp_eff) ?
        ({c_mantissa, 11'd0}) :
        ({c_mantissa, 11'd0} >> (mul_exp_eff - {1'b0, c_exponent}));

    // Add with sign/magnitude
    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [22:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    wire        add_sign = (s1_mul_sign == c_sign) ? s1_mul_sign :
                           mul_ge_c ? s1_mul_sign : c_sign;
    wire [22:0] add_result = (s1_mul_sign == c_sign) ?
        ({1'b0, mul_man_aligned} + {1'b0, c_man_aligned}) :
        abs_diff;

    // Normalize (fix #2: signed exponent prevents underflow wrap)
    reg [21:0] norm_man;
    reg signed [7:0] norm_exp;
    reg        norm_sign;
    reg [4:0]  lead_pos;
    integer shift;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[22]) begin
            norm_man = add_result[22:1];
            norm_exp = add_exp + 1;
        end else begin
            norm_man = add_result[21:0];
            norm_exp = {1'b0, add_exp};
            if (!norm_man[21]) begin
                lead_pos = 0;
                if      (norm_man[20]) lead_pos = 1;
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
                norm_exp = norm_exp - shift;
            end
        end
    end

    // Round-to-nearest-even (fix #3)
    // After normalization, implicit 1 at bit 21.
    // Mantissa field: norm_man[20:11] (10 bits)
    // Guard bit: norm_man[10], Round: norm_man[9], Sticky: |norm_man[8:0]
    wire guard  = norm_man[10];
    wire round  = norm_man[9];
    wire sticky = |norm_man[8:0];

    // Round up if: guard=1 AND (round=1 OR sticky=1 OR LSB of mantissa=1)
    wire round_up = guard & (round | sticky | norm_man[11]);

    // Apply rounding: add 1 at bit position 10 (LSB of mantissa field in norm_man)
    wire [21:0] rounded_man = norm_man + (round_up ? 22'd1024 : 22'd0);

    // Detect carry from rounding (bit 21 went from 1 to 0 = overflow)
    wire rounded_carry = ~rounded_man[21] & norm_man[21];

    // Bug fix #3: 22'h002000 was 1<<13, should be 22'h200000 (1<<21)
    wire [21:0] final_man = rounded_carry ? 22'h200000 : rounded_man;
    wire [7:0]  final_exp = rounded_carry ? (norm_exp + 8'd1) : norm_exp;

    // Pack result
    // Underflow: norm_exp < 0 (signed), or norm_exp == 0 with no rounding carry
    wire result_underflow = (norm_exp < 0) || (norm_exp == 0 && !rounded_carry);
    wire result_overflow  = (final_exp >= 31);
    wire [15:0] packed_result;
    assign packed_result = result_underflow ? (norm_sign ? 16'h8000 : FP16_ZERO) :
                           result_overflow  ? {norm_sign, 5'd31, 10'd0} :
                           {norm_sign, final_exp[4:0], final_man[20:11]};

    // =========================================================================
    // Special case handling (fix #4)
    // =========================================================================
    // NaN * anything = NaN
    // Inf * 0 = NaN
    // Inf * finite = Inf (with sign)
    // finite * Inf = Inf (with sign)
    // NaN + anything = NaN
    // Inf + anything = Inf (unless Inf + (-Inf) = NaN)
    wire any_nan = s1_a_nan | s1_b_nan | s1_c_nan;
    wire mul_inf_zero = (s1_a_inf & s1_b_zero) | (s1_b_inf & s1_a_zero);
    wire mul_inf = s1_a_inf | s1_b_inf;
    wire add_inf = s1_c_inf;

    // Check if we are doing Inf + (-Inf) for the addend (which = NaN)
    // This happens when: (a*b) produced Inf with some sign, and c is Inf with opposite sign
    wire inf_add_nan = mul_inf & add_inf & (s1_mul_sign != c_sign);

    wire is_special = any_nan | mul_inf_zero | mul_inf | add_inf;

    wire [15:0] special_result =
        any_nan      ? FP16_NAN :
        mul_inf_zero ? FP16_NAN :
        inf_add_nan  ? FP16_NAN :
        mul_inf      ? {s1_mul_sign, 5'd31, 10'd0} :
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
