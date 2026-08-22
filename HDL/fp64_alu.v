`timescale 1ns/1ps

// =============================================================================
// fp64_alu — IEEE 754 double-precision multi-function ALU
//
// Operations (selected by op[2:0]):
//   0: ADD   (a + b)     — dedicated 3-cycle adder pipeline
//   1: SUB   (a - b)     — dedicated 3-cycle adder (negate b)
//   2: MUL   (a * b)     — via fp64_fma with c=0, 3 cycles
//   3: DIV   (a / b)     — restoring binary long division, 58 cycles
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

    wire [52:0] as_man_a_aligned = (as_exp_diff >= 0) ? as1_man_a : (as1_man_a >> (-as_exp_diff));
    wire [52:0] as_man_b_aligned = (as_exp_diff < 0)  ? as1_man_b : (as1_man_b >> as_exp_diff);

    wire as_a_ge_b = (as_man_a_aligned >= as_man_b_aligned);
    wire as_same_sign = (as1_sign_a == as1_sign_b);
    wire [53:0] as_sum  = {1'b0, as_man_a_aligned} + {1'b0, as_man_b_aligned};
    wire [53:0] as_diff = as_a_ge_b ?
        ({1'b0, as_man_a_aligned} - {1'b0, as_man_b_aligned}) :
        ({1'b0, as_man_b_aligned} - {1'b0, as_man_a_aligned});

    wire as_result_sign = as_same_sign ? as1_sign_a :
                          as_a_ge_b ? as1_sign_a : as1_sign_b;
    wire [53:0] as_add_result = as_same_sign ? as_sum : as_diff;

    // Normalize
    reg [63:0] as_norm_result;
    reg [5:0]  as_lead;
    reg [53:0] as_norm_man;
    reg signed [11:0] as_norm_exp;

    always @(*) begin
        as_norm_result = {as_result_sign, 11'd0, 52'd0}; // default: zero
        // Special cases: NaN, Inf
        if (as1_a_nan || as1_b_nan)
            as_norm_result = FP64_NAN;
        else if (as1_a_inf || as1_b_inf)
            as_norm_result = (as1_a_inf && as1_b_inf && !as_same_sign) ?
                             FP64_NAN : (as1_a_inf ? {as1_sign_a, FP64_INF[62:0]} :
                                                     {as1_sign_b, FP64_INF[62:0]});
        else if (as_add_result != 0) begin
            as_norm_man = as_add_result;
            as_norm_exp = {1'b0, as_larger_exp};
            if (as_add_result[53]) begin
                as_norm_exp = as_norm_exp + 12'd1;
                as_norm_result = {as_result_sign, as_norm_exp[10:0], as_norm_man[52:1]};
            end else begin
                as_lead = 0;
                if      (as_norm_man[52]) as_lead = 0;
                else if (as_norm_man[51]) as_lead = 1;
                else if (as_norm_man[50]) as_lead = 2;
                else if (as_norm_man[49]) as_lead = 3;
                else if (as_norm_man[48]) as_lead = 4;
                else if (as_norm_man[47]) as_lead = 5;
                else if (as_norm_man[46]) as_lead = 6;
                else if (as_norm_man[45]) as_lead = 7;
                else if (as_norm_man[44]) as_lead = 8;
                else if (as_norm_man[43]) as_lead = 9;
                else if (as_norm_man[42]) as_lead = 10;
                else if (as_norm_man[41]) as_lead = 11;
                else if (as_norm_man[40]) as_lead = 12;
                else if (as_norm_man[39]) as_lead = 13;
                else if (as_norm_man[38]) as_lead = 14;
                else if (as_norm_man[37]) as_lead = 15;
                else if (as_norm_man[36]) as_lead = 16;
                else if (as_norm_man[35]) as_lead = 17;
                else if (as_norm_man[34]) as_lead = 18;
                else if (as_norm_man[33]) as_lead = 19;
                else if (as_norm_man[32]) as_lead = 20;
                else if (as_norm_man[31]) as_lead = 21;
                else if (as_norm_man[30]) as_lead = 22;
                else if (as_norm_man[29]) as_lead = 23;
                else if (as_norm_man[28]) as_lead = 24;
                else if (as_norm_man[27]) as_lead = 25;
                else if (as_norm_man[26]) as_lead = 26;
                else if (as_norm_man[25]) as_lead = 27;
                else if (as_norm_man[24]) as_lead = 28;
                else if (as_norm_man[23]) as_lead = 29;
                else if (as_norm_man[22]) as_lead = 30;
                else if (as_norm_man[21]) as_lead = 31;
                else if (as_norm_man[20]) as_lead = 32;
                else if (as_norm_man[19]) as_lead = 33;
                else if (as_norm_man[18]) as_lead = 34;
                else if (as_norm_man[17]) as_lead = 35;
                else if (as_norm_man[16]) as_lead = 36;
                else if (as_norm_man[15]) as_lead = 37;
                else if (as_norm_man[14]) as_lead = 38;
                else if (as_norm_man[13]) as_lead = 39;
                else if (as_norm_man[12]) as_lead = 40;
                else if (as_norm_man[11]) as_lead = 41;
                else if (as_norm_man[10]) as_lead = 42;
                else if (as_norm_man[9])  as_lead = 43;
                else if (as_norm_man[8])  as_lead = 44;
                else if (as_norm_man[7])  as_lead = 45;
                else if (as_norm_man[6])  as_lead = 46;
                else if (as_norm_man[5])  as_lead = 47;
                else if (as_norm_man[4])  as_lead = 48;
                else if (as_norm_man[3])  as_lead = 49;
                else if (as_norm_man[2])  as_lead = 50;
                else if (as_norm_man[1])  as_lead = 51;
                else                      as_lead = 52;

                as_norm_man = as_norm_man << as_lead;
                as_norm_exp = {1'b0, as_larger_exp} - {6'd0, as_lead};

                if (as_norm_exp < 0)
                    as_norm_result = {as_result_sign, 11'd0, 52'd0};
                else if (as_norm_exp >= 2047)
                    as_norm_result = {as_result_sign, 11'd2047, 52'd0};
                else
                    as_norm_result = {as_result_sign, as_norm_exp[10:0], as_norm_man[51:0]};
            end
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
    // DIV: restoring binary long division, 54 cycles
    //   Standard algorithm: remainder starts at 0, bring down dividend bits
    //   from MSB to LSB. Each iteration: shift remainder left, bring in next
    //   dividend bit, compare with divisor, subtract if >=.
    // =========================================================================
    localparam DIV_IDLE    = 2'd0;
    localparam DIV_COMPUTE = 2'd1;
    localparam DIV_NORM    = 2'd2;

    reg [1:0]   div_state;
    reg [53:0]  div_rem;      // running remainder (54 bits)
    reg [53:0]  div_quotient; // accumulating quotient (bit 51 = hidden leading 1)
    reg [53:0]  div_divisor;  // divisor mantissa (54 bits: {1'b0, 1.mantissa})
    reg [53:0]  div_dividend; // dividend mantissa for bit extraction
    reg [5:0]   div_bit;
    reg [10:0]  div_exp;
    reg         div_sign;
    reg         div_a_nan, div_b_nan, div_a_inf, div_b_inf;
    reg         div_a_zero, div_b_zero;

    // Combinational: extract dividend bit by iteration number
    wire [5:0] bit_idx = div_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_state <= DIV_IDLE;
        end else if (valid_in && is_div) begin
            div_a_nan   <= (a[62:52] == 11'd2047) && (a[51:0] != 0);
            div_a_inf   <= (a[62:52] == 11'd2047) && (a[51:0] == 0);
            div_a_zero  <= (a[62:0] == 0);
            div_b_nan   <= (b[62:52] == 11'd2047) && (b[51:0] != 0);
            div_b_inf   <= (b[62:52] == 11'd2047) && (b[51:0] == 0);
            div_b_zero  <= (b[62:0] == 0);
            div_sign    <= a[63] ^ b[63];
            div_exp     <= (a[62:52] != 0 ? a[62:52] : 11'd1)
                         - (b[62:52] != 0 ? b[62:52] : 11'd1)
                         + 11'd1023;
            div_rem     <= 54'd0;
            div_quotient <= 54'd0;
            div_dividend <= {1'b0, (a[62:52] != 0) ? {1'b1, a[51:0]} : {1'b0, a[51:0]}};
            div_divisor  <= {1'b0, (b[62:52] != 0) ? {1'b1, b[51:0]} : {1'b0, b[51:0]}};
            div_bit     <= 6'd52;
            div_state   <= DIV_COMPUTE;
        end else if (div_state == DIV_COMPUTE) begin
            if (div_bit == 0) begin
                div_state <= DIV_NORM;
            end else begin
                div_bit <= div_bit - 1;
                // Standard restoring division: shift remainder, bring in dividend bit,
                // compare with divisor, subtract if >=
                div_rem = {div_rem[52:0], div_dividend[bit_idx]};
                if (div_rem >= div_divisor) begin
                    div_rem = div_rem - div_divisor;
                    div_quotient <= {div_quotient[52:0], 1'b1};
                end else begin
                    div_quotient <= {div_quotient[52:0], 1'b0};
                end
            end
        end else if (div_state == DIV_NORM) begin
            div_state <= DIV_IDLE;
        end
    end

    // Combinational: extract dividend bit by iteration number
    reg [63:0] div_result;
    reg [5:0]  div_norm_shift;
    reg [53:0] div_norm_man;
    reg signed [11:0] div_norm_exp;
    always @(*) begin
        div_result = FP64_ZERO;
        if (div_a_nan || div_b_nan || (div_a_inf && div_b_inf) ||
            (div_a_zero && div_b_zero)) begin
            div_result = FP64_NAN;
        end else if (div_a_inf || div_b_zero) begin
            div_result = div_sign ? FP64_NEG_INF : FP64_INF;
        end else if (div_b_inf || div_a_zero) begin
            div_result = div_sign ? 64'h8000000000000000 : FP64_ZERO;
        end else begin
            div_norm_man = div_quotient;
            div_norm_exp = {1'b0, div_exp};
            // Quotient leading 1 is at bit 50 (may overflow to 51)
            if (div_norm_man[51]) begin
                div_norm_man = {1'b0, div_norm_man[51:1]};
                div_norm_exp = div_norm_exp + 12'd1;
            end
            if (div_norm_exp < 0)
                div_result = div_sign ? 64'h8000000000000000 : FP64_ZERO;
            else if (div_norm_exp >= 2047)
                div_result = {div_sign, 11'd2047, 52'd0};
            else
                div_result = {div_sign, div_norm_exp[10:0], div_norm_man[51:0]};
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

    wire [63:0] a_abs = {1'b0, s1_a[62:0]};
    wire [63:0] b_abs = {1'b0, s1_b[62:0]};
    wire a_lt_b = (a_abs < b_abs);
    wire a_gt_b = (a_abs > b_abs);
    wire a_eq_b = (a_abs == b_abs);

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
                s2_result <= a_eq_b ? {1'b0, 11'd1023, 52'd0} : FP64_ZERO;
            end else if (s1_op == OP_MIN) begin
                s2_result <= a_lt_b ? s1_a : s1_b;
            end else begin
                s2_result <= a_gt_b ? s1_a : s1_b;
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
