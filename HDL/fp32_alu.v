`timescale 1ns/1ps

// =============================================================================
// fp32_alu — FP32 ALU chip (Paper §2.7 compute unit)
//
// Multi-function FP32 ALU: ADD, SUB, MUL, DIV, MIN, MAX, CMP.
// Pipeline latency: 4 cycles (FMA path: 3 + 1 output mux).
// DIV uses 25-cycle restoring division.
// MIN/MAX/CMP are 1-cycle (registered inputs + combinational output).
// =============================================================================

module fp32_alu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        valid_in,
    input  wire [2:0]  op,
    output reg  [31:0] result,
    output reg         valid_out
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

    always @(*) begin
        case (op)
            OP_ADD: begin fma_a = a; fma_b = 32'h3F800000; fma_c = b; end
            OP_SUB: begin fma_a = a; fma_b = 32'h3F800000; fma_c = b ^ 32'h80000000; end
            OP_MUL: begin fma_a = a; fma_b = b;            fma_c = 32'h00000000; end
            default: begin fma_a = a; fma_b = 32'h3F800000; fma_c = b; end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fma_valid <= 0; end
        else begin fma_valid <= valid_in && (op == OP_ADD || op == OP_SUB || op == OP_MUL); end
    end

    // =========================================================================
    // Division: restoring binary long division, 25 cycles (24 compute + 1 norm)
    // =========================================================================
    localparam DIV_IDLE    = 2'd0;
    localparam DIV_COMPUTE = 2'd2;
    localparam DIV_NORM    = 2'd3;

    reg [1:0]  d_state;
    reg [24:0] d_rem;       // 25-bit remainder
    reg [24:0] d_divisor;   // 25-bit aligned divisor
    reg [23:0] d_quot;      // 24-bit quotient
    reg [4:0]  d_cnt;       // bit counter
    reg        d_sign;
    reg [8:0]  d_exp;
    reg        d_valid_r;
    reg [31:0] d_result_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_state <= DIV_IDLE; d_valid_r <= 0; d_result_r <= 0;
            d_rem <= 0; d_divisor <= 0; d_quot <= 0; d_cnt <= 0;
            d_sign <= 0; d_exp <= 0;
        end else begin
            d_valid_r <= 0;
            case (d_state)
                DIV_IDLE: begin
                    if (valid_in && op == OP_DIV) begin
                        d_sign <= a[31] ^ b[31];
                        // Use a/b bit-fields directly to avoid wire race conditions
                        if ((a[30:23] == 8'd255 && a[22:0] != 0) ||
                            (b[30:23] == 8'd255 && b[22:0] != 0) ||
                            (a[30:23] == 8'd255 && b[30:23] == 8'd255) ||
                            (a == 0 && b == 0)) begin
                            d_result_r <= FP32_NAN; d_valid_r <= 1;
                        end else if (b == 0) begin
                            d_result_r <= {a[31] ^ b[31], 8'd255, 23'd0}; d_valid_r <= 1;
                        end else if (a == 0 || b[30:23] == 8'd255) begin
                            d_result_r <= {a[31] ^ b[31], 8'd0, 23'd0}; d_valid_r <= 1;
                        end else if (a[30:23] == 8'd255) begin
                            d_result_r <= {a[31] ^ b[31], 8'd255, 23'd0}; d_valid_r <= 1;
                        end else begin
                            d_rem     <= {1'b0, 1'b1, a[22:0]};
                            d_divisor <= {1'b0, 1'b1, b[22:0]};
                            d_quot    <= 0;
                            d_exp     <= {1'b0, a[30:23]} - {1'b0, b[30:23]} + 9'd127;
                            d_cnt     <= 0;
                            d_state   <= DIV_COMPUTE;
                        end
                    end
                end

                DIV_COMPUTE: begin
                    if (d_rem >= d_divisor) begin
                        d_rem   <= d_rem - d_divisor;
                        d_quot  <= {d_quot[22:0], 1'b1};
                    end else begin
                        d_quot  <= {d_quot[22:0], 1'b0};
                    end
                    d_divisor <= {1'b0, d_divisor[24:1]};
                    d_cnt <= d_cnt + 1;
                    if (d_cnt == 5'd23) begin
                        d_state <= DIV_NORM;
                    end
                end

                DIV_NORM: begin
                    // d_quot now has all 24 bits (result of 24 iterations)
                    // Quotient represents (1.man_a)/(1.man_b) * 2^23
                    //   d_quot[23]=1 -> value in [1.0, 2.0), use d_quot[22:0]
                    //   d_quot[23]=0 -> value in [0.5, 1.0), shift left, exp-1
                    if (d_quot[23]) begin
                        d_result_r <= {d_sign, d_exp[7:0], d_quot[22:0]};
                    end else begin
                        d_result_r <= {d_sign, d_exp[7:0] - 8'd1, d_quot[22:0], 1'b0};
                    end
                    d_valid_r  <= 1;
                    d_state    <= DIV_IDLE;
                end

                default: d_state <= DIV_IDLE;
            endcase
        end
    end

    // =========================================================================
    // MIN / MAX / CMP: registered inputs, combinational output
    // =========================================================================
    reg [2:0]  s1_op, s2_op, s3_op;
    reg [31:0] s1_a, s1_b;
    reg        s1_valid, s2_valid, s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_op <= 0; s2_op <= 0; s3_op <= 0; s1_a <= 0; s1_b <= 0; s1_valid <= 0; s2_valid <= 0; s3_valid <= 0; end
        else begin
            s1_op <= op; s2_op <= s1_op; s3_op <= s2_op;
            s1_a <= a; s1_b <= b;
            s1_valid <= valid_in; s2_valid <= s1_valid; s3_valid <= s2_valid;
        end
    end

    wire a_gt_b_mag = (s1_a[30:0] > s1_b[30:0]);

    reg [31:0] minmax_result;
    always @(*) begin
        case (s1_op)
            OP_MIN: begin
                if (s1_a[31] && !s1_b[31]) minmax_result = s1_a;
                else if (!s1_a[31] && s1_b[31]) minmax_result = s1_b;
                else if (!s1_a[31]) minmax_result = a_gt_b_mag ? s1_b : s1_a;
                else minmax_result = a_gt_b_mag ? s1_a : s1_b;
            end
            OP_MAX: begin
                if (s1_a[31] && !s1_b[31]) minmax_result = s1_b;
                else if (!s1_a[31] && s1_b[31]) minmax_result = s1_a;
                else if (!s1_a[31]) minmax_result = a_gt_b_mag ? s1_a : s1_b;
                else minmax_result = a_gt_b_mag ? s1_b : s1_a;
            end
            OP_CMP: minmax_result = a_gt_b_mag ? FP32_ONE : FP32_ZERO;
            default: minmax_result = FP32_ZERO;
        endcase
    end

    // =========================================================================
    // Output mux: DIV has highest priority (24-cycle latency > FMA's 3)
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
            result_mux = minmax_result;
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
