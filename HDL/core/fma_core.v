`timescale 1ns/1ps

// =============================================================================
// fma_core — parameterized Fused Multiply-Add unit
//
// Computes: result = (a * b) + c, pipeline latency 3 cycles.
//
// The four shipped formats (fp16/bf16/fp32/fp64_fma.v) are thin wrappers over
// this core; keeping the arithmetic in one module means the class of bugs the
// audit rounds kept fixing four times (zero-guard, overflow alignment,
// far-sticky, carry-drop, RNE tie) now needs one fix at one site.
//
// Parameters:
//   W    total width (16/16/32/64)
//   E    exponent field width (5/8/8/11)
//   M    mantissa field width (10/7/23/52)
//   B    exponent bias (15/127/127/1023)
//   AW   alignment/rounding window width (22/24/48/106) — the aligned sum
//        carries at bit AW, the fraction occupies the window's top M bits
//        [AW-2 : AW-1-M], guard [AW-2-M], round [AW-3-M], sticky |[AW-4-M:0]
//   FTZ  1 = flush subnormal results to ±0 (fp16/bf16/fp64);
//        0 = full denormal output with RNE (fp32)
//
// IEEE special cases: NaN propagates (qNaN pattern), Inf propagates,
// 0*Inf → NaN, Inf + -Inf → NaN, result overflow → ±Inf, underflow → ±0
// (or denormal).
// =============================================================================

module fma_core #(
    parameter W    = 32,
    parameter E    = 8,
    parameter M    = 23,
    parameter B    = 127,
    parameter AW   = 48,
    parameter FTZ  = 0
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire [W-1:0] c,
    input  wire         valid_in,
    output reg  [W-1:0] result,
    output reg          valid_out
);

    localparam EW     = E + 3;              // working exponent width
    localparam INFEXP = {E{1'b1}};          // all-ones exponent field
    localparam MW     = M + 1;              // mantissa + implicit leading 1
    localparam PW     = 2 * M + 2;          // product width (two MW significands)
    localparam NANP   = {{E{1'b1}}, 1'b1, {(M-1){1'b0}}}; // quiet NaN pattern (sign 0)
    // AW/MW-wide unit literals for parametric shift masks (Verilog-2005 has
    // no x'(y) casts).
    localparam ONE_AW = {{(AW-1){1'b0}}, 1'b1};
    localparam ONE_MW = {{(MW-1){1'b0}}, 1'b1};

    // =========================================================================
    // Pipeline stage 1 — unpack + multiply
    // =========================================================================
    reg [W-1:0] s1_a, s1_b, s1_c;
    reg         s1_valid;

    reg  s1_a_nan, s1_b_nan, s1_c_nan;
    reg  s1_a_inf, s1_b_inf, s1_c_inf;
    reg  s1_a_zero, s1_b_zero, s1_c_zero;

    reg [PW-1:0] s1_mul_man;
    reg signed [EW-1:0] s1_mul_exp;
    reg         s1_mul_sign;
    reg         s1_mul_overflow;

    wire        a_sign_w = a[W-1];
    wire [E-1:0] a_exp_w = a[W-2 : M];
    wire [M-1:0] a_man_w = a[M-1:0];
    wire        a_zero_w = (a[W-2:0] == {W-1{1'b0}});
    wire        a_den_w  = (a_exp_w == 0) && (a_man_w != 0);

    wire [MW-1:0] a_mantissa_w;
    assign a_mantissa_w[MW-1] = (a_zero_w || a_den_w) ? 1'b0 : 1'b1;
    assign a_mantissa_w[M-1:0] = a_zero_w ? {M{1'b0}} :
                                 (a_den_w ? {1'b0, a_man_w} : a_man_w);
    wire [EW-1:0] a_exponent_w = a_zero_w ? {EW{1'b0}} :
                                 (a_den_w ? {{(EW-E){1'b0}}, 1'd1} : {{(EW-E){1'b0}}, a_exp_w});

    wire        b_sign_w = b[W-1];
    wire [E-1:0] b_exp_w = b[W-2 : M];
    wire [M-1:0] b_man_w = b[M-1:0];
    wire        b_zero_w = (b[W-2:0] == {W-1{1'b0}});
    wire        b_den_w  = (b_exp_w == 0) && (b_man_w != 0);

    wire [MW-1:0] b_mantissa_w;
    assign b_mantissa_w[MW-1] = (b_zero_w || b_den_w) ? 1'b0 : 1'b1;
    assign b_mantissa_w[M-1:0] = b_zero_w ? {M{1'b0}} :
                                 (b_den_w ? {1'b0, b_man_w} : b_man_w);
    wire [EW-1:0] b_exponent_w = b_zero_w ? {EW{1'b0}} :
                                 (b_den_w ? {{(EW-E){1'b0}}, 1'd1} : {{(EW-E){1'b0}}, b_exp_w});

    wire [E-1:0] c_exp_w = c[W-2 : M];
    wire [M-1:0] c_man_w = c[M-1:0];
    wire        c_zero_w = (c[W-2:0] == {W-1{1'b0}});

    // Multiply — zero-guard: 0*x must not leave a bogus exponent that would
    // misalign c into oblivion.
    wire        mul_sign_w = a_sign_w ^ b_sign_w;
    wire signed [EW-1:0] mul_exp_w = (a_zero_w || b_zero_w) ? {EW{1'b0}} :
        $signed({2'b00, a_exponent_w}) + $signed({2'b00, b_exponent_w}) - B;
    wire [PW-1:0] mul_man_w = a_mantissa_w * b_mantissa_w;
    wire        mul_ovf_w  = mul_man_w[PW-1];

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
            s1_a_nan   <= (a_exp_w == INFEXP) && (a_man_w != 0);
            s1_b_nan   <= (b_exp_w == INFEXP) && (b_man_w != 0);
            s1_c_nan   <= (c_exp_w == INFEXP) && (c_man_w != 0);
            s1_a_inf   <= (a_exp_w == INFEXP) && (a_man_w == 0);
            s1_b_inf   <= (b_exp_w == INFEXP) && (b_man_w == 0);
            s1_c_inf   <= (c_exp_w == INFEXP) && (c_man_w == 0);
            s1_a_zero  <= a_zero_w;
            s1_b_zero  <= b_zero_w;
            s1_c_zero  <= c_zero_w;
            s1_mul_man      <= mul_man_w;
            s1_mul_exp      <= mul_exp_w;
            s1_mul_sign     <= mul_sign_w;
            s1_mul_overflow <= mul_ovf_w;
        end
    end

    // =========================================================================
    // Pipeline stage 2 — align, add, normalize, round, pack
    // =========================================================================

    wire        c_sign = s1_c[W-1];
    wire [E-1:0] c_exp = s1_c[W-2 : M];
    wire [M-1:0] c_man = s1_c[M-1:0];
    wire        c_den  = (c_exp == 0) && (c_man != 0);

    wire [MW-1:0] c_mantissa;
    assign c_mantissa[MW-1]   = (s1_c_zero || c_den) ? 1'b0 : 1'b1;
    assign c_mantissa[M-1:0]  = s1_c_zero ? {M{1'b0}} :
                                (c_den ? {1'b0, c_man} : c_man);
    wire [EW-1:0] c_exponent  = s1_c_zero ? {EW{1'b0}} :
                                (c_den ? {{(EW-E){1'b0}}, 1'd1} : {{(EW-E){1'b0}}, c_exp});

    wire signed [EW-1:0] mul_exp_eff = s1_mul_overflow ? (s1_mul_exp + 1) : s1_mul_exp;
    wire signed [EW-1:0] add_exp = (mul_exp_eff > $signed({2'b00, c_exponent})) ? mul_exp_eff : $signed({2'b00, c_exponent});
    wire signed [EW-1:0] exp_diff = mul_exp_eff - $signed({2'b00, c_exponent});

    // Align in an AW-bit window with the implicit leading 1 at bit AW-1.
    // The product and c are zero-padded below, so a right-shifted operand
    // keeps its discarded low bits inside the window as guard/round/sticky
    // precision.
    wire [AW-1:0] mul_man_norm = s1_mul_overflow ? {s1_mul_man, {(AW-PW){1'b0}}}
                                                 : ({s1_mul_man, {(AW-PW){1'b0}}} << 1);
    wire [AW-1:0] mul_man_aligned = (exp_diff >= 0) ? mul_man_norm
                                                    : (mul_man_norm >> (-exp_diff));
    wire [AW-1:0] c_man_norm = {c_mantissa, {(AW-MW){1'b0}}};
    wire [AW-1:0] c_man_aligned = (exp_diff < 0) ? c_man_norm
                                                 : (c_man_norm >> exp_diff);

    // Far sticky: bits of the right-shifted operand that fall entirely below
    // the window's LSB are gone from norm_man; OR them back so a tiny addend
    // still rounds the mantissa up.
    wire [EW-1:0] mul_shift_u = (exp_diff < 0) ? (-exp_diff) : {EW{1'b0}};
    wire [EW-1:0] c_shift_u   = (exp_diff > 0) ?  exp_diff  : {EW{1'b0}};
    wire [EW-1:0] mul_shift   = (mul_shift_u > AW) ? AW : mul_shift_u;
    wire [EW-1:0] c_shift     = (c_shift_u   > AW) ? AW : c_shift_u;
    wire mul_far_sticky = |(mul_man_norm & ((ONE_AW << mul_shift) - ONE_AW));
    wire c_far_sticky  = |(c_man_norm & ((ONE_AW << c_shift) - ONE_AW));
    // The far sticky only applies to addition (same signs): subtraction
    // residuals pull the true magnitude down, so they must suppress the RNE
    // tie-break instead of adding sticky.
    wire add_op = (s1_mul_sign == c_sign);
    wire mul_far_eff = add_op & mul_far_sticky;
    wire c_far_eff  = add_op & c_far_sticky;
    wire sub_far = (!add_op) & (mul_far_sticky | c_far_sticky);

    // Add
    wire        mul_ge_c = (mul_man_aligned >= c_man_aligned);
    wire [AW:0] abs_diff = mul_ge_c ?
        ({1'b0, mul_man_aligned} - {1'b0, c_man_aligned}) :
        ({1'b0, c_man_aligned} - {1'b0, mul_man_aligned});

    wire        add_sign = (s1_mul_sign == c_sign) ? s1_mul_sign :
                           mul_ge_c ? s1_mul_sign : c_sign;
    wire [AW:0] add_result = (s1_mul_sign == c_sign) ?
        ({1'b0, mul_man_aligned} + {1'b0, c_man_aligned}) :
        abs_diff;

    // Carry-drop sticky: normalize (add_result[AW:1]) shifts bit 0 out of
    // the window when the add carries; fold it back in.
    wire carry_drop = add_op & add_result[AW] & add_result[0];

    // Normalize
    reg [AW-1:0] norm_man;
    reg signed [EW-1:0] norm_exp;
    reg         norm_sign;
    integer lead;
    integer i;
    reg lead_found;

    always @(*) begin
        norm_sign = add_sign;
        if (add_result == 0) begin
            norm_man = 0;
            norm_exp = 0;
        end else if (add_result[AW]) begin
            norm_man = add_result[AW:1];
            norm_exp = add_exp + 1;
        end else begin
            norm_man = add_result[AW-1:0];
            norm_exp = add_exp;
            // normalize: shift so the leading 1 sits at AW-1.  The scan must
            // keep the FIRST (highest) set bit: a plain overwriting loop would
            // end on the lowest set bit and over-shift.
            lead = 0;
            lead_found = 0;
            for (i = 0; i < AW; i = i + 1) begin
                if (!lead_found && norm_man[AW-1-i])
                    lead = i;
                if (norm_man[AW-1-i])
                    lead_found = 1;
            end
            if (!norm_man[AW-1]) begin
                norm_man = norm_man << lead;
                norm_exp = norm_exp - lead;
            end
        end
    end

    // Round-to-nearest-even
    wire guard  = norm_man[AW-2-M];
    wire round  = norm_man[AW-3-M];
    wire sticky = |norm_man[AW-4-M:0] | mul_far_eff | c_far_eff | carry_drop;
    wire round_up = guard & (round | sticky | (norm_man[AW-1-M] & ~sub_far));

    wire [AW-1:0] rounded_man = norm_man + (round_up ? (ONE_AW << (AW-2-M)) : 0);
    wire rounded_carry = ~rounded_man[AW-1] & norm_man[AW-1];

    wire [AW-1:0] final_man = rounded_carry ? (ONE_AW << (AW-1)) : rounded_man;
    wire signed [EW-1:0] final_exp = rounded_carry ? (norm_exp + 1) : norm_exp;

    // Pack
    wire result_underflow = (final_exp < 1);
    // final_exp is non-negative here (underflow handled first), so the
    // unsigned-context compare against the all-ones exponent field is safe.
    wire result_overflow  = (final_exp >= 1) && (final_exp >= {2'b00, INFEXP});

    // Subnormal output (FTZ=0, fp32/bf16): right-shift the normalized window
    // into the exponent-0 range with a fresh RNE at the subnormal boundary.
    // The leading 1 sits at norm_man[AW-1]; the subnormal's top mantissa bit
    // is M-1, so the shift is (AW-M) - norm_exp (negative norm_exp = deeper
    // subnormal).  A carry out of the M-bit field yields the smallest normal.
    wire signed [EW-1:0] sub_shift_s = (AW-M) - norm_exp;
    wire        sub_clamped = (sub_shift_s > AW);
    wire [EW-1:0] sub_shift = sub_clamped ? AW[EW-1:0] : sub_shift_s[EW-1:0];
    wire [M-1:0]  sub_man   = sub_clamped ? {M{1'b0}} : (norm_man >> sub_shift);
    wire        sub_guard   = sub_clamped ? 1'b0 : norm_man[sub_shift - 1];
    wire        sub_round   = sub_clamped ? 1'b0 : norm_man[sub_shift - 2];
    // sticky = |norm_man[shift-3:0] (guard and round sit at [shift-1],[shift-2]
    // and are excluded from the mask: (1<<shift)-1 marks [shift-1:0], >>2 drops
    // the guard+round bits).
    wire [AW-1:0] sub_low_mask = ((ONE_AW << sub_shift) - ONE_AW) >> 2;
    wire        sub_sticky  = sub_clamped ? 1'b0 : |(norm_man & sub_low_mask);
    wire        sub_round_up = sub_guard & (sub_round | sub_sticky | sub_man[0]);
    wire [M:0] sub_field   = {1'b0, sub_man} + (sub_round_up ? 1 : 0);
    wire        sub_carry    = sub_field[M];
    wire [W-1:0] den_result  = sub_carry ? {norm_sign, {{(E-1){1'b0}}, 1'd1}, {(M){1'b0}}}
                                         : {norm_sign, {(E){1'b0}}, sub_field[M-1:0]};
    wire [W-1:0] ftz_result  = {norm_sign, {(W-1){1'b0}}};

    wire [W-1:0] packed_result =
        result_underflow ? ((FTZ || norm_man == 0 || sub_clamped) ? ftz_result : den_result) :
        result_overflow  ? {norm_sign, INFEXP, {(M){1'b0}}} :
        {norm_sign, final_exp[E-1:0], final_man[AW-2 : AW-1-M]};

    // Special cases
    wire any_nan = s1_a_nan | s1_b_nan | s1_c_nan;
    wire mul_inf_zero = (s1_a_inf & s1_b_zero) | (s1_b_inf & s1_a_zero);
    wire mul_inf = s1_a_inf | s1_b_inf;
    wire add_inf = s1_c_inf;
    wire inf_add_nan = mul_inf & add_inf & (s1_mul_sign != c_sign);

    wire is_special = any_nan | mul_inf_zero | mul_inf | add_inf;

    wire [W-1:0] special_result =
        any_nan      ? {1'b0, NANP} :
        mul_inf_zero ? {1'b0, NANP} :
        inf_add_nan  ? {1'b0, NANP} :
        mul_inf      ? {s1_mul_sign, INFEXP, {(M){1'b0}}} :
        add_inf      ? s1_c :
                       packed_result;

    reg [W-1:0] s2_result;
    reg         s2_valid;

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