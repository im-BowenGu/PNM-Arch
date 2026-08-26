`timescale 1ns/1ps

// tb_int8_alu — self-checking testbench for int8_alu
//
// Tests: ADD, SUB, MUL, SHIFT, MIN, MAX, AND, CMP
// Exit 0 on success, non-zero on failure.

module tb_int8_alu;

    reg clk, rst_n;
    reg signed [7:0] a, b;
    reg valid_in;
    reg [2:0] op;
    wire [15:0] result;
    wire valid_out;

    int8_alu uut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .valid_in(valid_in), .op(op),
        .result(result), .valid_out(valid_out)
    );

    localparam [2:0] OP_ADD=0, OP_SUB=1, OP_MUL=2, OP_SHIFT=3,
                     OP_MIN=4, OP_MAX=5, OP_AND=6, OP_CMP=7;

    integer errors, pass_count;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task automatic feed(input signed [7:0] ta, input signed [7:0] tb, input [2:0] top);
        begin
            @(posedge clk);
            a <= ta; b <= tb; op <= top; valid_in <= 1;
            @(posedge clk);
            valid_in <= 0;
        end
    endtask

    task automatic wait_result(output [15:0] res);
        integer timeout;
        begin
            timeout = 0;
            while (!valid_out && timeout < 20) begin
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

    task automatic check(input [15:0] got, input [15:0] expected, input [8*32-1:0] msg);
        begin
            if (got !== expected) begin
                $display("FAIL %0s: got %0d, expected %0d", msg, got, expected);
                errors = errors + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    reg [15:0] res;

    initial begin
        $dumpfile("tb_int8_alu.vcd");
        $dumpvars(0, tb_int8_alu);
        errors = 0;
        pass_count = 0;
        rst_n = 0; a = 0; b = 0; valid_in = 0; op = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ADD: 3 + 5 = 8
        feed(8'sd3, 8'sd5, OP_ADD);
        wait_result(res);
        check(res, 16'd8, "ADD 3+5=8");

        // SUB: 10 - 3 = 7
        feed(8'sd10, 8'sd3, OP_SUB);
        wait_result(res);
        check(res, 16'd7, "SUB 10-3=7");

        // MUL: 3 * 5 = 15
        feed(8'sd3, 8'sd5, OP_MUL);
        wait_result(res);
        check(res, 16'd15, "MUL 3*5=15");

        // MUL: -3 * 5 = -15 (signed)
        feed(-8'sd3, 8'sd5, OP_MUL);
        wait_result(res);
        check(res, 16'hFFF1, "MUL -3*5=-15");

        // SHIFT: 4 << 2 = 16
        feed(8'sd4, 8'sd2, OP_SHIFT);
        wait_result(res);
        check(res, 16'd16, "SHIFT 4<<2=16");

        // MIN: MIN(10, 5) = 5
        feed(8'sd10, 8'sd5, OP_MIN);
        wait_result(res);
        check(res, 16'd5, "MIN(10,5)=5");

        // MAX: MAX(10, 5) = 10
        feed(8'sd10, 8'sd5, OP_MAX);
        wait_result(res);
        check(res, 16'd10, "MAX(10,5)=10");

        // AND: 0xFF & 0x0F = 0x0F
        feed(8'hFF, 8'h0F, OP_AND);
        wait_result(res);
        check(res, 16'h0F, "AND FF&0F=0F");

        // CMP: CMP(7, 7) = 1
        feed(8'sd7, 8'sd7, OP_CMP);
        wait_result(res);
        check(res, 16'd1, "CMP(7,7)=1");

        // CMP: CMP(7, 3) = 0
        feed(8'sd7, 8'sd3, OP_CMP);
        wait_result(res);
        check(res, 16'd0, "CMP(7,3)=0");

        $display("*** INT8 ALU TEST: %0d passed, %0d errors ***", pass_count, errors);
        if (errors != 0) $finish(1);
        else $finish(0);
    end

endmodule
