`timescale 1ns/1ps

// =============================================================================
// fp64_alu — IEEE 754 double-precision multi-function ALU
//
// Operations (selected by op[2:0]):
//   0: ADD   (a + b)     — dedicated 3-cycle adder pipeline
//   1: SUB   (a - b)     — dedicated 3-cycle adder (negate b)
//   2: MUL   (a * b)     — via fp64_fma with c=0, 3 cycles
//   3: DIV   (a / b)     — restoring binary long division, 56 cycles (fix #8)
//   4: MIN   (a < b ? a : b) — 3-cycle pipelined comparator
//   5: MAX   (a > b ? a : b) — 3-cycle pipelined comparator
//   7: CMP   (a == b ? 1.0 : 0.0) — 3-cycle pipelined comparator
//
// IEEE 754 compliance:
//   - DIV by zero returns ±Inf (per IEEE 754)
//   - CMP with NaN returns 0.0 (per IEEE 754, avoids HIGH #10)
//   - NaN propagation on ADD/SUB/MUL/DIV
//   - Denormal inputs handled (flushed to zero for ADD/SUB/MUL)
//
// Bug avoidance:
//   - ADD/SUB uses dedicated path, not FMA, to avoid alignment issues
//   - CMP with NaN returns 0.0 (HIGH #10)
//   - Registers inputs alongside valid to prevent 1-cycle skew (Bug #12)
// =============================================================================

module fp64_alu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire        valid_in,
    input  wire [2:0]  op,
    output reg  [63:0] result,
    output reg         valid_out,
    output wire        busy
);

    localparam [2:0] OP_ADD = 0, OP_SUB = 1, OP_MUL = 2, OP_DIV = 3,
                     OP_MIN = 4, OP_MAX = 5, OP_CMP = 7;

    localparam FP64_ZERO = 64'h0000000000000000;
    localparam FP64_ONE  = 64'h3FF0000000000000;
    localparam FP64_INF  = 64'h7FF0000000000000;
    localparam FP64_NAN  = 64'h7FF8000000000000;
    localparam FP64_NEG_INF = 64'hFFF0000000000000;

    wire is_addsub = (op == OP_ADD || op == OP_SUB);
    wire is_mul    = (op == OP_MUL);
    wire is_div    = (op == OP_DIV);
    wire is_cmpop  = (op == OP_MIN || op == OP_MAX || op == OP_CMP);

    // =========================================================================
    // ADD/SUB: dedicated 3-cycle pipeline
    //   Stage 1: unpack inputs, capture sign/exp/man
    //   Stage 2: align, add/sub, normalize, register result
    //   Stage 3: output
    // =========================================================================
    reg [63:0] as1_a, as1_b;
    reg        as1_sign_a, as1_sign_b;
    reg [10:0] as1_exp_a, as1_exp_b;
    reg [52:0] as1_man_a, as1_man_b;
    reg        as1_valid;
    reg        as1_a_nan, as1_b_nan, as1_a_inf, as1_b_inf;

    wire [10:0] a_exp_w = a[62:52];
    wire [10:0] b_exp_w = b[62:52];
    wire        a_zero_w = (a[62:0] == 63'd0);
    wire        b_zero_w = (b[62:0] == 63'd0);
    wire        a_den_w  = (a_exp_w == 0) && (a[51:0] != 0);
    wire        b_den_w  = (b_exp_w == 0) && (b[51:0] != 0);
    wire [52:0] a_man_w = a_zero_w ? 53'd0 : (a_den_w ? {1'b0, a[51:0]} : {1'b1, a[51:0]});
    wire [52:0] b_man_w = b_zero_w ? 53'd0 : (b_den_w ? {1'b0, b[51:0]} : {1'b1, b[51:0]});
    wire [10:0] a_exp_adj = a_zero_w ? 11'd0 : (a_den_w ? 11'd1 : a_exp_w);
    wire [10:0] b_exp_adj = b_zero_w ? 11'd0 : (b_den_w ? 11'd1 : b_exp_w);

    // Stage 1: capture inputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            as1_a <= 0; as1_b <= 0; as1_valid <= 0;
            as1_sign_a <= 0; as1_sign_b <= 0;
            as1_exp_a <= 0; as1_exp_b <= 0;
            as1_man_a <= 0; as1_man_b <= 0;
            as1_a_nan <= 0; as1_b_nan <= 0;
            as1_a_inf <= 0; as1_b_inf <= 0;
        end else if (valid_in && is_addsub) begin
            as1_a <= a; as1_b <= b; as1_valid <= 1;
            as1_sign_a <= a[63];
            as1_sign_b <= b[63] ^ op[0]; // SUB: flip b's sign
            as1_exp_a <= a_exp_adj;
            as1_exp_b <= b_exp_adj;
            as1_man_a <= a_man_w;
            as1_man_b <= b_man_w;
            as1_a_nan <= (a[62:52] == 11'd2047) && (a[51:0] != 0);
            as1_b_nan <= (b[62:52] == 11'd2047) && (b[51:0] != 0);
            as1_a_inf <= (a[62:52] == 11'd2047) && (a[51:0] == 0);
            as1_b_inf <= (b[62:52] == 11'd2047) && (b[51:0] == 0);
        end else begin
            as1_valid <= 0;
        end
    end

    // Stage 2: align, add, normalize (combinatorial → registered)
    wire signed [11:0] as_exp_diff = {1'b0, as1_exp_a} - {1'b0, as1_exp_b};
    wire [10:0] as_larger_exp = (as_exp_diff >= 0) ? as1_exp_a : as1_exp_b;

    // Wide alignment retaining guard/round bits + sticky for RNE rounding.
    // Each operand is placed in a 55-bit field: 53-bit significand (implicit
    // 1 at bit 54) plus two low guard/round bits.  Bits shifted out of this
    // 55-bit window during alignment are OR-ed into a sticky flag.
    wire [11:0] as_sh_a = (as_exp_diff >= 0) ? 12'd0 : (-as_exp_diff);
    wire [11:0] as_sh_b = (as_exp_diff >= 0) ? as_exp_diff : 12'd0;

    wire [54:0] as_raw_a = {as1_man_a, 2'b00};          // implicit 1 at bit 54
    wire [54:0] as_raw_b = {as1_man_b, 2'b00};

    wire [54:0] as_wide_a = (as_sh_a == 0) ? as_raw_a : (as_raw_a >> as_sh_a);
    wire [54:0] as_wide_b = (as_sh_b == 0) ? as_raw_b : (as_raw_b >> as_sh_b);

    wire as_sticky_a = (as_sh_a == 0) ? 1'b0 :
                       (as_sh_a >= 55) ? |as_raw_a :
                       |(as_raw_a & ((55'h1 << as_sh_a) - 55'h1));
    wire as_sticky_b = (as_sh_b == 0) ? 1'b0 :
                       (as_sh_b >= 55) ? |as_raw_b :
                       |(as_raw_b & ((55'h1 << as_sh_b) - 55'h1));

    wire as_a_ge_b   = (as_wide_a >= as_wide_b);
    wire as_same_sign = (as1_sign_a == as1_sign_b);
    wire [55:0] as_sum  = {1'b0, as_wide_a} + {1'b0, as_wide_b};
    wire [55:0] as_diff = as_a_ge_b ?
        ({1'b0, as_wide_a} - {1'b0, as_wide_b}) :
        ({1'b0, as_wide_b} - {1'b0, as_wide_a});

    wire as_result_sign = as_same_sign ? as1_sign_a :
                          as_a_ge_b ? as1_sign_a : as1_sign_b;
    wire [55:0] as_wide_result = as_same_sign ? as_sum : as_diff;
    wire as_sticky_ops = as_sticky_a | as_sticky_b;

    // Round-to-nearest-even on the wide (55-bit significand + G/R) result.
    // Normalize the wide result so the leading 1 sits at bit 55; the 52-bit
    // fraction is bits [54:3], guard [2], round [1], sticky [0] | operand sticky.
    reg [63:0] as_norm_result;
    reg [5:0]  as_lead;
    reg [55:0] as_nm;
    reg [51:0] as_frac;
    reg        as_guard, as_round, as_sticky, as_round_up, as_frac_carry;
    reg signed [11:0] as_norm_exp;
    reg [52:0] as_frac_rounded;
    reg [11:0] as_final_exp;

    always @(*) begin
        as_norm_result = {as_result_sign, 11'd0, 52'd0}; // default: zero
        // Special cases: NaN, Inf
        if (as1_a_nan || as1_b_nan)
            as_norm_result = FP64_NAN;
        else if (as1_a_inf || as1_b_inf)
            as_norm_result = (as1_a_inf && as1_b_inf && !as_same_sign) ?
                             FP64_NAN : (as1_a_inf ? {as1_sign_a, FP64_INF[62:0]} :
                                                     {as1_sign_b, FP64_INF[62:0]});
        else if (as_wide_result != 0) begin
            as_norm_exp = {1'b0, as_larger_exp};
            // Leading-one position of the 56-bit sum.
            if      (as_wide_result[55]) as_lead = 0;
            else if (as_wide_result[54]) as_lead = 1;
            else if (as_wide_result[53]) as_lead = 2;
            else if (as_wide_result[52]) as_lead = 3;
            else if (as_wide_result[51]) as_lead = 4;
            else if (as_wide_result[50]) as_lead = 5;
            else if (as_wide_result[49]) as_lead = 6;
            else if (as_wide_result[48]) as_lead = 7;
            else if (as_wide_result[47]) as_lead = 8;
            else if (as_wide_result[46]) as_lead = 9;
            else if (as_wide_result[45]) as_lead = 10;
            else if (as_wide_result[44]) as_lead = 11;
            else if (as_wide_result[43]) as_lead = 12;
            else if (as_wide_result[42]) as_lead = 13;
            else if (as_wide_result[41]) as_lead = 14;
            else if (as_wide_result[40]) as_lead = 15;
            else if (as_wide_result[39]) as_lead = 16;
            else if (as_wide_result[38]) as_lead = 17;
            else if (as_wide_result[37]) as_lead = 18;
            else if (as_wide_result[36]) as_lead = 19;
            else if (as_wide_result[35]) as_lead = 20;
            else if (as_wide_result[34]) as_lead = 21;
            else if (as_wide_result[33]) as_lead = 22;
            else if (as_wide_result[32]) as_lead = 23;
            else if (as_wide_result[31]) as_lead = 24;
            else if (as_wide_result[30]) as_lead = 25;
            else if (as_wide_result[29]) as_lead = 26;
            else if (as_wide_result[28]) as_lead = 27;
            else if (as_wide_result[27]) as_lead = 28;
            else if (as_wide_result[26]) as_lead = 29;
            else if (as_wide_result[25]) as_lead = 30;
            else if (as_wide_result[24]) as_lead = 31;
            else if (as_wide_result[23]) as_lead = 32;
            else if (as_wide_result[22]) as_lead = 33;
            else if (as_wide_result[21]) as_lead = 34;
            else if (as_wide_result[20]) as_lead = 35;
            else if (as_wide_result[19]) as_lead = 36;
            else if (as_wide_result[18]) as_lead = 37;
            else if (as_wide_result[17]) as_lead = 38;
            else if (as_wide_result[16]) as_lead = 39;
            else if (as_wide_result[15]) as_lead = 40;
            else if (as_wide_result[14]) as_lead = 41;
            else if (as_wide_result[13]) as_lead = 42;
            else if (as_wide_result[12]) as_lead = 43;
            else if (as_wide_result[11]) as_lead = 44;
            else if (as_wide_result[10]) as_lead = 45;
            else if (as_wide_result[9])  as_lead = 46;
            else if (as_wide_result[8])  as_lead = 47;
            else if (as_wide_result[7])  as_lead = 48;
            else if (as_wide_result[6])  as_lead = 49;
            else if (as_wide_result[5])  as_lead = 50;
            else if (as_wide_result[4])  as_lead = 51;
            else if (as_wide_result[3])  as_lead = 52;
            else if (as_wide_result[2])  as_lead = 53;
            else if (as_wide_result[1])  as_lead = 54;
            else                         as_lead = 55;

            as_nm = as_wide_result << as_lead;   // leading 1 now at bit 55
            as_norm_exp = {1'b0, as_larger_exp} - {6'd0, as_lead} + 12'd1;

            as_frac   = as_nm[54:3];
            as_guard  = as_nm[2];
            as_round  = as_nm[1];
            as_sticky = as_nm[0] | as_sticky_ops;
            // Round-to-nearest-even.  For subtraction (different signs) the only
            // operand that is shifted (and thus has a discarded tail) is the
            // smaller one being subtracted, so its sticky is subtractive: it must
            // not push a g=1,r=0 residual over the half-ULP tie point.  gating
            // both the sticky AND the LSB tie-break by as_same_sign keeps
            // additions rounding up on any tail while subtractions only round up
            // when the round bit is set (mirrors fp64_fma's ~sub_far guard).
            as_round_up = as_guard & (as_round | (as_frac[0] & as_same_sign) | (as_sticky & as_same_sign));

            as_frac_rounded = {1'b0, as_frac} + {52'd0, as_round_up};
            as_frac_carry   = as_frac_rounded[52]; // overflowed past 2^53
            as_final_exp = as_norm_exp + (as_frac_carry ? 12'd1 : 12'd0);
            as_frac = as_frac_carry ? 52'd0 : as_frac_rounded[51:0];

            if (as_norm_exp < 0)
                as_norm_result = {as_result_sign, 11'd0, 52'd0};
            else if (as_final_exp >= 2047)
                as_norm_result = {as_result_sign, 11'd2047, 52'd0};
            else
                as_norm_result = {as_result_sign, as_final_exp[10:0], as_frac};
        end
    end


    // Stage 2 register: capture normalized result
    reg [63:0] as2_result;
    reg        as2_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            as2_result <= 0;
            as2_valid <= 0;
        end else begin
            as2_valid <= as1_valid;
            if (as1_valid)
                as2_result <= as_norm_result;
        end
    end

    // =========================================================================
    // MUL via fp64_fma (3-cycle pipeline)
    // =========================================================================
    reg        fma_valid_in;
    reg [63:0] fma_a_reg, fma_b_reg, fma_c_reg;

    wire [63:0] fma_result;
    wire        fma_valid_out;

    fp64_fma u_fma (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fma_a_reg),
        .b         (fma_b_reg),
        .c         (fma_c_reg),
        .valid_in  (fma_valid_in),
        .result    (fma_result),
        .valid_out (fma_valid_out)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fma_a_reg <= 0; fma_b_reg <= 0; fma_c_reg <= 0;
        end else if (valid_in && is_mul) begin
            fma_a_reg <= a; fma_b_reg <= b; fma_c_reg <= 64'd0;
        end
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) fma_valid_in <= 0;
        else         fma_valid_in <= valid_in && is_mul;

    // =========================================================================
    // DIV: restoring binary long division, 56 cycles
    //   Two phases:
    //     Phase A (1 cycle): rem = SA; q_int = (SA >= SB); subtract if so.
    //       SA/SB in (0.5, 2), so the integer bit settles here.
    //     Phase B (53 cycles): rem = {rem, 0} each cycle; if rem >= SB:
    //       subtract and set fraction bit q[j].  rem in [0, SB) so
    //       rem<<1 fits 54 bits; one fraction bit per cycle.
    //   The old code extracted only dividend bits (integer division
    //   floor(SA/SB)), which collapsed every non-trivial quotient to 1.0,
    //   and its 11-bit (ea - eb + 1023) wrapped for |ea-eb| >= 1024.
    // =========================================================================
    localparam DIV_IDLE    = 2'd0;
    localparam DIV_COMPUTE = 2'd1;
    localparam DIV_NORM    = 2'd2;

    reg [1:0]   div_state;
    reg [53:0]  div_rem;      // running remainder (54 bits)
    reg [53:0]  div_SA;       // dividend significand (54 bits: {0, 1.mantissa})
    reg [52:0]  div_SB;       // divisor significand (53 bits: 1.mantissa)
    reg [52:0]  div_q;        // 53 fraction quotient bits
    reg         div_q_int;    // integer quotient bit (value >= 1)
    reg [5:0]   div_bit;
    reg signed [12:0] div_exp;
    reg         div_sign;
    reg         div_a_nan, div_b_nan, div_a_inf, div_b_inf;
    reg         div_a_zero, div_b_zero, div_a_den, div_b_den;

    wire [5:0] bit_idx = div_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_state <= DIV_IDLE;
        end else if (valid_in && is_div) begin
            div_a_nan   <= (a[62:52] == 11'd2047) && (a[51:0] != 0);
            div_a_inf   <= (a[62:52] == 11'd2047) && (a[51:0] == 0);
            div_a_zero  <= (a[62:0] == 0);
            div_a_den   <= (a[62:52] == 0) && (a[51:0] != 0);
            div_b_nan   <= (b[62:52] == 11'd2047) && (b[51:0] != 0);
            div_b_inf   <= (b[62:52] == 11'd2047) && (b[51:0] == 0);
            div_b_zero  <= (b[62:0] == 0);
            div_b_den   <= (b[62:52] == 0) && (b[51:0] != 0);
            div_sign    <= a[63] ^ b[63];
            // 13-bit signed exponent math: (ea - eb + 1023) must not wrap
            // (11-bit arithmetic wraps for |ea - eb| >= 1024).
            div_exp     <= $signed({2'b00, (a[62:52] != 0 ? a[62:52] : 11'd1)}) -
                           $signed({2'b00, (b[62:52] != 0 ? b[62:52] : 11'd1)}) +
                           $signed(13'd1023);
            div_rem     <= {1'b0, 1'b1, a[51:0]}; // SA
            div_SA      <= {1'b0, 1'b1, a[51:0]};
            div_SB      <= {1'b1, b[51:0]};
            div_q       <= 53'd0;
            div_q_int   <= 1'b0;
            div_bit     <= 6'd53;
            div_state   <= DIV_COMPUTE;
        end else if (div_state == DIV_COMPUTE) begin
            if (div_bit == 53) begin
                // Phase A: integer quotient bit
                if (div_rem >= {1'b0, div_SB}) begin
                    div_rem <= div_rem - {1'b0, div_SB};
                    div_q_int <= 1'b1;
                end
                div_bit <= 6'd52;
            end else begin
                // Phase B: fraction bits, rem = {rem, 0} per cycle
                if (div_bit == 0)
                    div_state <= DIV_NORM;
                div_rem = {div_rem[52:0], 1'b0};
                if (div_rem >= {1'b0, div_SB}) begin
                    div_rem = div_rem - {1'b0, div_SB};
                    div_q[bit_idx] <= 1'b1;
                end else begin
                    div_q[bit_idx] <= 1'b0;
                end
                if (div_bit != 0)
                    div_bit <= div_bit - 1;
            end
        end else if (div_state == DIV_NORM) begin
            div_state <= DIV_IDLE;
        end
    end

    // Combinational: normalize quotient, build result
    reg [63:0] div_result;
    reg [5:0]  div_norm_shift;
    reg [51:0] div_norm_man;
    reg signed [12:0] div_norm_exp;
    always @(*) begin
        div_result = FP64_ZERO;
        if (div_a_nan || div_b_nan || (div_a_inf && div_b_inf) ||
            (div_a_zero && div_b_zero)) begin
            // NaN only for NaN, Inf/Inf, 0/0 (IEEE 754);
            // Inf/0 falls through to the +-Inf branch below.
            div_result = FP64_NAN;
        end else if (div_a_den || div_b_den) begin
            // Denormal input flushed to zero: a_den -> a=0 -> +-0;
            // b_den -> b=0 -> +-Inf
            if (div_a_den)
                div_result = div_sign ? 64'h8000000000000000 : FP64_ZERO;
            else
                div_result = div_sign ? FP64_NEG_INF : FP64_INF;
        end else if (div_a_inf || div_b_zero) begin
            div_result = div_sign ? FP64_NEG_INF : FP64_INF;
        end else if (div_b_inf || div_a_zero) begin
            div_result = div_sign ? 64'h8000000000000000 : FP64_ZERO;
        end else begin
            div_norm_exp = div_exp;
            if (div_q_int) begin
                // value in [1, 2): mantissa 1.q[52:1], drop q[0] (round to zero)
                div_norm_man = div_q[52:1];
            end else begin
                // value in (0.5, 1): mantissa 1.q[51:0], exponent -1
                div_norm_man = div_q[51:0];
                div_norm_exp = div_norm_exp - 13'sd1;
            end
            // Signed literal comparisons (13'sd): bare 13'd1/13'd2046 are
            // unsigned, which would compare the 13-bit signed exponent as
            // unsigned and misfire (underflow -> +Inf).
            if (div_norm_exp < 13'sd1)
                div_result = div_sign ? 64'h8000000000000000 : FP64_ZERO;
            else if (div_norm_exp > 13'sd2046)
                div_result = {div_sign, 11'd2047, 52'd0};
            else
                div_result = {div_sign, div_norm_exp[10:0], div_norm_man};
        end
    end



    // =========================================================================
    // MIN/MAX/CMP: 3-stage pipelined comparator (matching FMA latency)
    // =========================================================================
    reg [63:0] s1_a, s1_b;
    reg [2:0]  s1_op;
    reg        s1_valid;
    reg        s1_a_nan, s1_b_nan;

    reg [63:0] s2_result;
    reg        s2_valid;

    reg [63:0] s3_result;
    reg        s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_a <= 0; s1_b <= 0; s1_op <= 0; s1_valid <= 0;
            s1_a_nan <= 0; s1_b_nan <= 0;
        end else if (valid_in && is_cmpop) begin
            s1_a <= a; s1_b <= b; s1_op <= op; s1_valid <= 1;
            s1_a_nan <= (a[62:52] == 11'd2047) && (a[51:0] != 0);
            s1_b_nan <= (b[62:52] == 11'd2047) && (b[51:0] != 0);
        end else begin
            s1_valid <= 0;
        end
    end

    // True signed comparison (port from fp32_alu — magnitude-only compare was wrong)
    wire s1_a_sign = s1_a[63];
    wire s1_b_sign = s1_b[63];
    wire s1_both_zero = (s1_a[62:0] == 0) && (s1_b[62:0] == 0);
    wire s1_a_gt_b = s1_both_zero ? 1'b0 :
                     s1_a_nan ? 1'b0 :
                     s1_b_nan ? 1'b0 :
                     (s1_a_sign != s1_b_sign) ? ~s1_a_sign :
                     s1_a_sign ? (s1_b[62:0] > s1_a[62:0]) : (s1_a[62:0] > s1_b[62:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_result <= 0; s2_valid <= 0;
        end else begin
            s2_valid <= s1_valid;
            if (s1_a_nan || s1_b_nan) begin
                if (s1_op == OP_CMP)
                    s2_result <= FP64_ZERO;
                else
                    s2_result <= s1_a_nan ? s1_b : s1_a;
            end else if (s1_op == OP_CMP) begin
                // OP_CMP contract (HDL/README.md:290): (a == b) ? 1.0 : 0.0.
                // The (s1_a_gt_b || ...) term turned it into ">=" — equality
                // is the only true condition; larger or smaller must be 0.0.
                s2_result <= s1_both_zero ? {1'b0, 11'd1023, 52'd0} :
                             (s1_a[62:0] == s1_b[62:0] && s1_a[63] == s1_b[63]) ?
                             {1'b0, 11'd1023, 52'd0} : FP64_ZERO;
            end else if (s1_op == OP_MIN) begin
                s2_result <= s1_both_zero ? {s1_a_sign | s1_b_sign, 63'd0} :
                             s1_a_nan ? s1_b : s1_b_nan ? s1_a :
                             (s1_a_gt_b ? s1_b : s1_a);
            end else begin
                s2_result <= s1_both_zero ? {s1_a_sign & s1_b_sign, 63'd0} :
                             s1_a_nan ? s1_b : s1_b_nan ? s1_a :
                             (s1_a_gt_b ? s1_a : s1_b);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s3_result <= 0; s3_valid <= 0; end
        else begin s3_result <= s2_result; s3_valid <= s2_valid; end
    end

    // =========================================================================
    // Output mux
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= 0;
            if (as2_valid) begin
                result <= as2_result;
                valid_out <= 1;
            end else if (fma_valid_out) begin
                result <= fma_result;
                valid_out <= 1;
            end else if (div_state == DIV_NORM) begin
                result <= div_result;
                valid_out <= 1;
            end else if (s3_valid) begin
                result <= s3_result;
                valid_out <= 1;
            end
        end
    end

    assign busy = (div_state != DIV_IDLE);

endmodule
