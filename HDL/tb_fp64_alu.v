`timescale 1ns/1ps

// tb_fp64_alu — self-checking testbench for fp64_alu
//
// Tests: ADD, SUB, MUL, DIV, MIN, MAX, CMP, NaN handling, DIV by zero
// Exit 0 on success, non-zero on failure.

module tb_fp64_alu;

    reg clk, rst_n;
    reg [63:0] a, b;
    reg valid_in;
    reg [2:0] op;
    wire [63:0] result;
    wire valid_out;
    wire busy;

    fp64_alu uut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .valid_in(valid_in), .op(op),
        .result(result), .valid_out(valid_out), .busy(busy)
    );

    localparam [2:0] OP_ADD=0, OP_SUB=1, OP_MUL=2, OP_DIV=3,
                     OP_MIN=4, OP_MAX=5, OP_CMP=7;

    // FP64 constants
    localparam [63:0] FP64_1_0  = 64'h3FF0000000000000; // 1.0
    localparam [63:0] FP64_2_0  = 64'h4000000000000000; // 2.0
    localparam [63:0] FP64_3_0  = 64'h4008000000000000; // 3.0
    localparam [63:0] FP64_5_0  = 64'h4014000000000000; // 5.0
    localparam [63:0] FP64_6_0  = 64'h4018000000000000; // 6.0
    localparam [63:0] FP64_NEG1 = 64'hBFF0000000000000; // -1.0
    localparam [63:0] FP64_ZERO = 64'h0000000000000000; // 0.0
    localparam [63:0] FP64_INF  = 64'h7FF0000000000000; // +Inf
    localparam [63:0] FP64_NEG_INF = 64'hFFF0000000000000; // -Inf
    localparam [63:0] FP64_NAN  = 64'h7FF8000000000000; // NaN

    integer errors;
    integer pass_count;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task automatic feed(input [63:0] ta, input [63:0] tb, input [2:0] top);
        begin
            @(posedge clk);
            a <= ta; b <= tb; op <= top; valid_in <= 1;
            @(posedge clk);
            valid_in <= 0;
        end
    endtask

    task automatic wait_result(output [63:0] res);
        integer timeout;
        begin
            timeout = 0;
            while (!valid_out && timeout < 200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!valid_out) begin
                $display("TIMEOUT waiting for result");
                errors = errors + 1;
            end
            res = result;
        end
    endtask

    task automatic check(input [63:0] got, input [63:0] expected, input [8*32-1:0] msg);
        begin
            if (got !== expected) begin
                $display("FAIL %0s: got %h, expected %h", msg, got, expected);
                errors = errors + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    reg [63:0] res;

    initial begin
        $dumpfile("tb_fp64_alu.vcd");
        $dumpvars(0, tb_fp64_alu);
        errors = 0;
        pass_count = 0;
        rst_n = 0; a = 0; b = 0; valid_in = 0; op = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ADD: 2.0 + 3.0 = 5.0
        feed(FP64_2_0, FP64_3_0, OP_ADD);
        wait_result(res);
        check(res, FP64_5_0, "ADD 2+3=5");

        // SUB: 5.0 - 3.0 = 2.0
        feed(FP64_5_0, FP64_3_0, OP_SUB);
        wait_result(res);
        check(res, FP64_2_0, "SUB 5-3=2");

        // MUL: 2.0 * 3.0 = 6.0
        feed(FP64_2_0, FP64_3_0, OP_MUL);
        wait_result(res);
        check(res, FP64_6_0, "MUL 2*3=6");

        // ADD: 1.0 + (-1.0) = 0.0
        feed(FP64_1_0, FP64_NEG1, OP_ADD);
        wait_result(res);
        check(res, FP64_ZERO, "ADD 1+(-1)=0");

        // DIV: 6.0 / 3.0 = 2.0
        feed(FP64_6_0, FP64_3_0, OP_DIV);
        wait_result(res);
        check(res, FP64_2_0, "DIV 6/3=2");

        // DIV by zero: 1.0 / 0.0 = +Inf
        feed(FP64_1_0, FP64_ZERO, OP_DIV);
        wait_result(res);
        check(res, FP64_INF, "DIV 1/0=+Inf");

        // MIN: MIN(3.0, 2.0) = 2.0
        feed(FP64_3_0, FP64_2_0, OP_MIN);
        wait_result(res);
        check(res, FP64_2_0, "MIN(3,2)=2");

        // MAX: MAX(3.0, 2.0) = 3.0
        feed(FP64_3_0, FP64_2_0, OP_MAX);
        wait_result(res);
        check(res, FP64_3_0, "MAX(3,2)=3");

        // CMP: CMP(2.0, 2.0) = 1.0
        feed(FP64_2_0, FP64_2_0, OP_CMP);
        wait_result(res);
        check(res, FP64_1_0, "CMP(2,2)=1.0");

        // CMP: CMP(2.0, 3.0) = 0.0
        feed(FP64_2_0, FP64_3_0, OP_CMP);
        wait_result(res);
        check(res, FP64_ZERO, "CMP(2,3)=0.0");

        // CMP with NaN: CMP(NaN, 1.0) = 0.0 (IEEE 754)
        feed(FP64_NAN, FP64_1_0, OP_CMP);
        wait_result(res);
        check(res, FP64_ZERO, "CMP(NaN,1)=0.0");

        // ADD with NaN: NaN + 1.0 = NaN
        feed(FP64_NAN, FP64_1_0, OP_ADD);
        wait_result(res);
        check(res, FP64_NAN, "NaN+1=NaN");

        $display("*** FP64 ALU TEST: %0d passed, %0d errors ***", pass_count, errors);
        if (errors != 0) $finish(1);
        else $finish(0);
    end

endmodule
