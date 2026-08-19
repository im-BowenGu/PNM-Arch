`timescale 1ns/1ps

module tb_fp32_alu_edge;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [31:0] a, b;
    reg  [2:0]  op;
    reg         valid_in;
    wire [31:0] result;
    wire        valid_out;
    wire        busy;

    localparam FP32_0    = 32'h00000000;
    localparam FP32_NEG0 = 32'h80000000;
    localparam FP32_1    = 32'h3F800000;
    localparam FP32_2    = 32'h40000000;
    localparam FP32_MAX  = 32'h7F7FFFFF;
    localparam FP32_INF  = 32'h7F800000;
    localparam FP32_NINF = 32'hFF800000;
    localparam FP32_QNAN = 32'h7FC00000;
    localparam FP32_SNAN = 32'h7FA00001;
    localparam FP32_DMIN = 32'h00000001;

    localparam OP_ADD = 3'd0;
    localparam OP_SUB = 3'd1;
    localparam OP_MUL = 3'd2;
    localparam OP_DIV = 3'd3;
    localparam OP_MIN = 3'd4;
    localparam OP_MAX = 3'd5;
    localparam OP_CMP = 3'd6;

    always #5 clk = ~clk;

    fp32_alu dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .op(op),
        .valid_in(valid_in),
        .result(result), .valid_out(valid_out),
        .busy(busy)
    );

    integer errors;
    integer timeout_val;

    task wait_result;
        begin
            timeout_val = 0;
            while (!valid_out && timeout_val < 200) begin
                @(posedge clk);
                timeout_val = timeout_val + 1;
            end
            if (timeout_val >= 200) begin
                $display("[EDGE] TIMEOUT waiting for valid_out (op=%0d)", op);
                errors = errors + 1;
            end
        end
    endtask

    task run_op;
        input [2:0]  iop;
        input [31:0] ia, ib;
        input [31:0] exp;
        input [8*32-1:0] nm;
        begin
            a = ia; b = ib; op = iop;
            @(posedge clk);
            while (busy) @(posedge clk);
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            wait_result;
            if (result !== exp) begin
                $display("[EDGE] FAIL(%0s): got %h exp %h", nm, result, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fp32_alu_edge.vcd");
        $dumpvars(0, tb_fp32_alu_edge);
        errors = 0;
        a = 0; b = 0; op = 0; valid_in = 0;

        #25; rst_n = 1; #10;

        // 1. NaN + 1 -> NaN (any quiet NaN)
        $display("[EDGE] Test 1: NaN+1");
        run_op(OP_ADD, FP32_QNAN, FP32_1, FP32_QNAN, "NaN+1");

        // 2. NaN * 0 -> NaN
        $display("[EDGE] Test 2: NaN*0");
        run_op(OP_MUL, FP32_QNAN, FP32_0, FP32_QNAN, "NaN*0");

        // 3. Inf + Inf -> Inf
        $display("[EDGE] Test 3: Inf+Inf");
        run_op(OP_ADD, FP32_INF, FP32_INF, FP32_INF, "Inf+Inf");

        // 4. Inf - Inf -> NaN
        $display("[EDGE] Test 4: Inf-Inf");
        run_op(OP_SUB, FP32_INF, FP32_INF, FP32_QNAN, "Inf-Inf");

        // 5. Inf * 0 -> NaN
        $display("[EDGE] Test 5: Inf*0");
        run_op(OP_MUL, FP32_INF, FP32_0, FP32_QNAN, "Inf*0");

        // 6. Overflow: MAX * 2 -> Inf
        $display("[EDGE] Test 6: overflow");
        run_op(OP_MUL, FP32_MAX, FP32_2, FP32_INF, "MAX*2");

        // 7. 0/0 -> NaN
        $display("[EDGE] Test 7: 0/0");
        run_op(OP_DIV, FP32_0, FP32_0, FP32_QNAN, "0/0");

        // 8. (-1)/0 -> -Inf
        $display("[EDGE] Test 8: (-1)/0");
        run_op(OP_DIV, 32'hBF800000, FP32_0, FP32_NINF, "(-1)/0");

        // 9. MIN(NaN, 1) = 1 (IEEE 754)
        $display("[EDGE] Test 9: MIN(NaN,1)");
        run_op(OP_MIN, FP32_QNAN, FP32_1, FP32_1, "min(NaN,1)");

        // 10. MAX(1, NaN) = 1 (IEEE 754)
        $display("[EDGE] Test 10: MAX(1,NaN)");
        run_op(OP_MAX, FP32_1, FP32_QNAN, FP32_1, "max(1,NaN)");

        // 11. 0 - 0 = +0
        $display("[EDGE] Test 11: 0-0");
        run_op(OP_SUB, FP32_0, FP32_0, FP32_0, "0-0");

        // 12. (-0) + 0 = -0
        $display("[EDGE] Test 12: (-0)+0");
        run_op(OP_ADD, FP32_NEG0, FP32_0, FP32_NEG0, "(-0)+0");

        // 13. Denormal: dmin * 1
        $display("[EDGE] Test 13: denormal");
        run_op(OP_MUL, FP32_DMIN, FP32_1, FP32_DMIN, "dmin*1");

        // 14. Back-to-back ops
        $display("[EDGE] Test 14: back-to-back");
        run_op(OP_ADD, FP32_1, FP32_1, FP32_2, "1+1");
        run_op(OP_MUL, FP32_2, FP32_2, 32'h40800000, "2*2");
        run_op(OP_ADD, FP32_1, FP32_1, FP32_2, "1+1again");

        // 15. Reset mid-division
        $display("[EDGE] Test 15: reset mid-div");
        @(negedge clk);
        op = OP_DIV; a = FP32_1; b = FP32_2; valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        @(negedge clk);
        rst_n = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        if (busy !== 1'b0) begin
            $display("[EDGE] FAIL(T15): busy after reset"); errors = errors + 1;
        end

        // 16. MIN(-Inf, 1) = -Inf
        $display("[EDGE] Test 16: MIN(-Inf,1)");
        run_op(OP_MIN, FP32_NINF, FP32_1, FP32_NINF, "min(-Inf,1)");

        // 17. MAX(Inf, -1) = Inf
        $display("[EDGE] Test 17: MAX(Inf,-1)");
        run_op(OP_MAX, FP32_INF, 32'hBF800000, FP32_INF, "max(Inf,-1)");

        // 18. sNaN quieted (just check NaN bit set)
        $display("[EDGE] Test 18: sNaN");
        run_op(OP_MUL, FP32_SNAN, FP32_1, FP32_QNAN, "sNaN*1");

        if (errors == 0)
            $display("*** FP32 ALU EDGE TEST PASSED ***");
        else
            $display("*** FP32 ALU EDGE TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish(1); end

endmodule
