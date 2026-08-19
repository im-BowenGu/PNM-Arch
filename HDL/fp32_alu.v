`timescale 1ns/1ps

// =============================================================================
// fp32_alu — FP32 ALU chip (Paper §2.7 compute unit)
//
// Multi-function FP32 ALU: ADD, SUB, MUL, DIV, MIN, MAX, CMP.
// Pipeline latency: 4 cycles (FMA path: 3 + 1 output mux).
// DIV uses 25-cycle restoring division.
// MIN/MAX/CMP are 3-cycle pipelined (matching FMA latency).
// busy: asserted when DIV is in progress; new valid_in must be held.
// =============================================================================

module fp32_alu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        valid_in,
    input  wire [2:0]  op,
    output reg  [31:0] result,
    output reg         valid_out,
    output wire        busy          // high while DIV in progress
);

    localparam OP_ADD  = 3'd0;
    localparam OP_SUB  = 3'd1;
    localparam OP_MUL  = 3'd2;
    localparam OP_DIV  = 3'd3;
    localparam OP_MIN  = 3'd4;
    localparam OP_MAX  = 3'd5;
    localparam OP_CMP  = 3'd7;

    localparam FP32_ZERO = 32'h00000000;
    localparam FP32_ONE  = 32'h3F800000;
    localparam FP32_NAN  = 32'h7FC00000;
    localparam FP32_INF  = 32'h7F800000;

    // =========================================================================
    // FMA: used for ADD, SUB, MUL
    // Bug fix: register fma_a/b/c alongside fma_valid to prevent stale inputs
    // =========================================================================
    reg  [31:0] fma_a, fma_b, fma_c;
    reg         fma_valid;
    wire [31:0] fma_result;
    wire        fma_valid_out;

    fp32_fma u_fma (
        .clk(clk), .rst_n(rst_n),
        .a(fma_a), .b(fma_b), .c(fma_c),
        .valid_in(fma_valid),
        .result(fma_result), .valid_out(fma_valid_out)
    );

    // Bug fix: register fma_a/b/c in the clocked block so inputs are stable
    // when fma_valid is asserted (previously combinational + registered valid
    // caused a 1-cycle skew where the FMA sampled stale operands).
    wire fma_go = valid_in && (op == OP_ADD || op == OP_SUB || op == OP_MUL) && !busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fma_valid <= 0;
            fma_a <= 0; fma_b <= 0; fma_c <= 0;
        end else begin
            fma_valid <= fma_go;
            if (fma_go) begin
                case (op)
                    OP_ADD: begin fma_a <= a; fma_b <= 32'h3F800000; fma_c <= b; end
                    OP_SUB: begin fma_a <= a; fma_b <= 32'h3F800000; fma_c <= b ^ 32'h80000000; end
                    OP_MUL: begin fma_a <= a; fma_b <= b;           fma_c <= 32'h00000000; end
                    default: begin fma_a <= a; fma_b <= 32'h3F800000; fma_c <= b; end
                endcase
            end
        end
    end

    // =========================================================================
    // Division: left-shifting restoring division (26 compute + 1 norm)
    // Divisor stays fixed; remainder shifts left each iteration.
    // =========================================================================
    localparam DIV_IDLE    = 2'd0;
    localparam DIV_COMPUTE = 2'd1;
    localparam DIV_NORM    = 2'd2;

    reg [1:0]  d_state;
    reg [24:0] d_rem_high;  // Upper half of remainder
    reg [23:0] d_rem_low;   // Lower half of remainder
    reg [23:0] d_divisor;   // Fixed 24-bit divisor (never shifted)
    reg [25:0] d_quot;      // 26-bit quotient for accuracy and rounding
    reg [4:0]  d_cnt;
    reg        d_sign;
    reg [8:0]  d_exp;
    reg        d_valid_r;
    reg [31:0] d_result_r;

    wire [24:0] rem_sub = d_rem_high - {1'b0, d_divisor};
    wire        can_sub = ~rem_sub[24]; // Positive or zero => subtraction successful

    wire a_is_zero = (a[30:0] == 31'd0);
    wire b_is_zero = (b[30:0] == 31'd0);

    assign busy = (d_state != DIV_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_state <= DIV_IDLE; d_valid_r <= 0; d_result_r <= 0;
            d_rem_high <= 0; d_rem_low <= 0; d_divisor <= 0;
            d_quot <= 0; d_cnt <= 0; d_sign <= 0; d_exp <= 0;
        end else begin
            d_valid_r <= 0;
            case (d_state)
                DIV_IDLE: begin
                    if (valid_in && op == OP_DIV && !busy) begin
                        d_sign <= a[31] ^ b[31];
                        if ((a[30:23] == 8'd255 && a[22:0] != 0) ||
                            (b[30:23] == 8'd255 && b[22:0] != 0) ||
                            (a[30:23] == 8'd255 && b[30:23] == 8'd255) ||
                            (a_is_zero && b_is_zero)) begin
                            d_result_r <= FP32_NAN; d_valid_r <= 1;
                        end else if (b_is_zero) begin
                            d_result_r <= {a[31] ^ b[31], 8'd255, 23'd0}; d_valid_r <= 1;
                        end else if (a_is_zero) begin
                            d_result_r <= {a[31] ^ b[31], 8'd0, 23'd0}; d_valid_r <= 1;
                        end else if (a[30:23] == 8'd255) begin
                            d_result_r <= {a[31] ^ b[31], 8'd255, 23'd0}; d_valid_r <= 1;
                        end else if (b[30:23] == 8'd255) begin
                            d_result_r <= {a[31] ^ b[31], 8'd0, 23'd0}; d_valid_r <= 1;
                        end else begin
                            d_rem_high <= {1'b0, 1'b1, a[22:0]};
                            d_rem_low  <= 24'd0;
                            d_divisor  <= {1'b1, b[22:0]};
                            d_quot     <= 0;
                            d_exp      <= {1'b0, a[30:23]} - {1'b0, b[30:23]} + 9'd127;
                            d_cnt      <= 0;
                            d_state    <= DIV_COMPUTE;
                        end
                    end
                end

                DIV_COMPUTE: begin
                    // Shift remainder left; if subtract succeeds, append 1 to quotient.
                    // Divisor stays fixed — precision is preserved.
                    if (can_sub) begin
                        d_rem_high <= {rem_sub[23:0], d_rem_low[23]};
                        d_rem_low  <= {d_rem_low[22:0], 1'b0};
                        d_quot     <= {d_quot[24:0], 1'b1};
                    end else begin
                        d_rem_high <= {d_rem_high[23:0], d_rem_low[23]};
                        d_rem_low  <= {d_rem_low[22:0], 1'b0};
                        d_quot     <= {d_quot[24:0], 1'b0};
                    end
                    d_cnt <= d_cnt + 1;
                    if (d_cnt == 5'd25) begin
                        d_state <= DIV_NORM;
                    end
                end

                DIV_NORM: begin
                    // d_quot[25] = 1 => range [1.0, 2.0); = 0 => [0.5, 1.0)
                    if (d_quot[25]) begin
                        d_result_r <= {d_sign, d_exp[7:0], d_quot[24:2]};
                    end else begin
                        d_result_r <= {d_sign, d_exp[7:0] - 8'd1, d_quot[23:1]};
                    end
                    d_valid_r <= 1;
                    d_state   <= DIV_IDLE;
                end

                default: d_state <= DIV_IDLE;
            endcase
        end
    end

    // =========================================================================
    // MIN / MAX / CMP: Fully pipelined (3 stages matching FMA latency)
    // =========================================================================
    reg [2:0]  s1_op, s2_op, s3_op;
    reg        s1_valid, s2_valid, s3_valid;
    reg [31:0] s1_a, s1_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_op <= 0; s2_op <= 0; s3_op <= 0;
            s1_a <= 0; s1_b <= 0;
            s1_valid <= 0; s2_valid <= 0; s3_valid <= 0;
        end else begin
            s1_op <= op; s2_op <= s1_op; s3_op <= s2_op;
            s1_a <= a; s1_b <= b;
            s1_valid <= valid_in; s2_valid <= s1_valid; s3_valid <= s2_valid;
        end
    end

    // True signed comparison (handles sign bits, not just magnitude)
    wire s1_a_sign = s1_a[31];
    wire s1_b_sign = s1_b[31];
    wire s1_both_zero = (s1_a[30:0] == 0) && (s1_b[30:0] == 0);
    wire s1_a_nan = (s1_a[30:23] == 8'd255) && (s1_a[22:0] != 0);
    wire s1_b_nan = (s1_b[30:23] == 8'd255) && (s1_b[22:0] != 0);
    wire s1_a_gt_b = s1_both_zero ? 1'b0 :
                     s1_a_nan ? 1'b0 :
                     s1_b_nan ? 1'b1 :
                     (s1_a_sign != s1_b_sign) ? ~s1_a_sign :
                     s1_a_sign ? (s1_b[30:0] > s1_a[30:0]) : (s1_a[30:0] > s1_b[30:0]);

    reg [31:0] s1_minmax_res;
    always @(*) begin
        case (s1_op)
            OP_MIN: s1_minmax_res = s1_both_zero ? {s1_a_sign | s1_b_sign, 31'd0} :
                                    s1_a_nan ? s1_b : s1_b_nan ? s1_a :
                                    (s1_a_gt_b ? s1_b : s1_a);
            OP_MAX: s1_minmax_res = s1_both_zero ? {s1_a_sign & s1_b_sign, 31'd0} :
                                    s1_a_nan ? s1_b : s1_b_nan ? s1_a :
                                    (s1_a_gt_b ? s1_a : s1_b);
            OP_CMP: s1_minmax_res = s1_a_gt_b ? FP32_ONE : FP32_ZERO;
            default:s1_minmax_res = FP32_ZERO;
        endcase
    end

    // Pipeline the result alongside valid/opcode so it arrives at the mux in sync
    reg [31:0] s2_minmax_res, s3_minmax_res;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_minmax_res <= 0; s3_minmax_res <= 0;
        end else begin
            s2_minmax_res <= s1_minmax_res;
            s3_minmax_res <= s2_minmax_res;
        end
    end

    // =========================================================================
    // Output mux: DIV has highest priority (24-cycle latency > FMA's 3)
    // Bug fix: no two sources should be active simultaneously; if they are,
    // DIV wins (it has the longest latency and is rarest).
    // =========================================================================
    reg [31:0] result_mux;
    reg        valid_mux;

    always @(*) begin
        if (d_valid_r) begin
            result_mux = d_result_r;
            valid_mux  = 1'b1;
        end else if (fma_valid_out) begin
            result_mux = fma_result;
            valid_mux  = 1'b1;
        end else if (s3_valid && (s3_op == OP_MIN || s3_op == OP_MAX || s3_op == OP_CMP)) begin
            result_mux = s3_minmax_res;
            valid_mux  = 1'b1;
        end else begin
            result_mux = FP32_ZERO;
            valid_mux  = 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin result <= 0; valid_out <= 0; end
        else begin result <= result_mux; valid_out <= valid_mux; end
    end

endmodule
