`timescale 1ns/1ps

// =============================================================================
// int8_alu — INT8 multi-function ALU
//
// Operations (selected by op[2:0]):
//   0: ADD   (a + b)     — signed 8-bit addition, 1 cycle
//   1: SUB   (a - b)     — signed 8-bit subtraction, 1 cycle
//   2: MUL   (a * b)     — signed 8-bit multiply, 2 cycles (same as int8_mac)
//   3: SHIFT (a << b)    — arithmetic left shift, 1 cycle
//   4: MIN   (a < b ? a : b) — signed comparison, 1 cycle
//   5: MAX   (a > b ? a : b) — signed comparison, 1 cycle
//   6: AND   (a & b)     — bitwise AND, 1 cycle
//   7: CMP   (a == b ? 1 : 0) — equality test, 1 cycle
//
// Interface:
//   clk, rst_n, a[7:0], b[7:0], valid_in, op[2:0]
//   → result[15:0] (extended to 16-bit for MUL/SHIFT), valid_out
//
// Signed arithmetic throughout. MUL produces 16-bit signed result.
// ADD/SUB produce 8-bit result zero-extended to 16-bit.
// =============================================================================

module int8_alu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    input  wire        valid_in,
    input  wire [2:0]  op,
    output reg  [15:0] result,
    output reg         valid_out
);

    localparam [2:0] OP_ADD = 0, OP_SUB = 1, OP_MUL = 2, OP_SHIFT = 3,
                     OP_MIN = 4, OP_MAX = 5, OP_AND = 6, OP_CMP = 7;

    // Stage 1: compute
    reg signed [8:0]  add_result;
    reg signed [8:0]  sub_result;
    reg signed [15:0] mul_result;
    reg signed [7:0]  shift_result;
    reg signed [7:0]  min_result;
    reg signed [7:0]  max_result;
    reg [7:0]         and_result;
    reg [7:0]         cmp_result;
    reg               s1_valid;
    reg [2:0]         s1_op;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_result <= 0; sub_result <= 0; mul_result <= 0;
            shift_result <= 0; min_result <= 0; max_result <= 0;
            and_result <= 0; cmp_result <= 0;
            s1_valid <= 0; s1_op <= 0;
        end else begin
            s1_valid <= valid_in;
            s1_op <= op;
            add_result <= $signed({a[7], a}) + $signed({b[7], b});
            sub_result <= $signed({a[7], a}) - $signed({b[7], b});
            mul_result <= $signed(a) * $signed(b);
            shift_result <= a <<< b[2:0];  // arithmetic left shift, 3-bit count
            min_result <= ($signed(a) < $signed(b)) ? a : b;
            max_result <= ($signed(a) > $signed(b)) ? a : b;
            and_result <= a & b;
            cmp_result <= (a == b) ? 8'd1 : 8'd0;
        end
    end

    // Stage 2: output mux
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= s1_valid;
            case (s1_op)
                OP_ADD:   result <= {8'h00, add_result[7:0]};
                OP_SUB:   result <= {8'h00, sub_result[7:0]};
                OP_MUL:   result <= mul_result;
                OP_SHIFT: result <= {8'h00, shift_result};
                OP_MIN:   result <= {8'h00, min_result};
                OP_MAX:   result <= {8'h00, max_result};
                OP_AND:   result <= {8'h00, and_result};
                OP_CMP:   result <= {8'h00, cmp_result};
                default:  result <= 0;
            endcase
        end
    end

endmodule
