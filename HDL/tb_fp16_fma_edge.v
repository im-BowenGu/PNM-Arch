`timescale 1ns/1ps

module tb_fp16_fma_edge;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [15:0] a, b, c;
    reg         valid_in;
    wire [15:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    fp16_fma dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c),
        .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    localparam FP16_0    = 16'h0000;
    localparam FP16_NEG0 = 16'h8000;
    localparam FP16_1    = 16'h3C00;
    localparam FP16_2    = 16'h4000;
    localparam FP16_3    = 16'h4200;
    localparam FP16_MAX  = 16'h7BFF;
    localparam FP16_NMAX = 16'hFBFF;
    localparam FP16_INF  = 16'h7C00;
    localparam FP16_NINF = 16'hFC00;
    localparam FP16_QNAN = 16'h7E00;
    localparam FP16_SNAN = 16'h7D01;
    localparam FP16_DMIN = 16'h0001;
    localparam FP16_DMAX = 16'h03FF;

    task run_op;
        input [15:0] ia, ib, ic;
        begin
            @(negedge clk);
            a = ia; b = ib; c = ic;
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            repeat (4) @(posedge clk);
        end
    endtask

    task check_nan;
        input [8*80-1:0] nm;
        begin
            @(negedge clk);
            if (result[14] !== 1'b1) begin
                $display("[EDGE] FAIL(%0s): not NaN %h", nm, result);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fp16_fma_edge.vcd");
        $dumpvars(0, tb_fp16_fma_edge);
        errors = 0;
        a = 0; b = 0; c = 0; valid_in = 0;

        #25; rst_n = 1; #10;

        // 1. Overflow: max * max -> +Inf
        $display("[EDGE] Test 1: overflow");
        run_op(FP16_MAX, FP16_MAX, FP16_0);
        @(negedge clk);
        if (result !== FP16_INF) begin
            $display("[EDGE] FAIL(T1): got %h exp Inf", result); errors = errors + 1;
        end

        // 2. Denormal * 1 -> denormal or 0
        $display("[EDGE] Test 2: denormal");
        run_op(FP16_DMIN, FP16_1, FP16_0);
        @(negedge clk);
        if (result !== FP16_DMIN && result !== FP16_0) begin
            $display("[EDGE] FAIL(T2): got %h", result); errors = errors + 1;
        end

        // 3. Neg * neg -> positive
        $display("[EDGE] Test 3: neg*neg");
        run_op(16'hBC00, 16'hBC00, FP16_0);  // -1 * -1
        @(negedge clk);
        if (result !== FP16_1) begin
            $display("[EDGE] FAIL(T3): got %h", result); errors = errors + 1;
        end

        // 4. Zero * NaN -> NaN
        $display("[EDGE] Test 4: 0*NaN");
        run_op(FP16_0, FP16_QNAN, FP16_0);
        check_nan("0*NaN");

        // 5. NaN + NaN -> NaN
        $display("[EDGE] Test 5: NaN+NaN");
        run_op(FP16_QNAN, FP16_1, FP16_QNAN);
        check_nan("NaN+NaN");

        // 6. Inf - Inf -> NaN
        $display("[EDGE] Test 6: Inf-Inf");
        run_op(FP16_INF, FP16_1, FP16_NINF);
        check_nan("Inf-Inf");

        // 7. Back-to-back: 3 ops in pipeline
        $display("[EDGE] Test 7: back-to-back");
        @(negedge clk);
        a = FP16_2; b = FP16_2; c = FP16_0; valid_in = 1;
        @(posedge clk);
        a = FP16_1; b = FP16_1; c = FP16_0; valid_in = 1;
        @(posedge clk);
        a = FP16_3; b = FP16_1; c = FP16_0; valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        repeat (6) @(posedge clk);
        @(negedge clk);
        if (result !== 16'h4200) begin
            $display("[EDGE] FAIL(T7): got %h exp 4200", result); errors = errors + 1;
        end

        // 8. Reset mid-operation
        $display("[EDGE] Test 8: reset mid-op");
        @(negedge clk);
        a = FP16_MAX; b = FP16_MAX; c = FP16_0; valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        @(negedge clk);
        rst_n = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        if (dut.valid_out !== 1'b0) begin
            $display("[EDGE] FAIL(T8): valid_out after reset"); errors = errors + 1;
        end

        // 9. Max + denorm -> max (absorbed)
        $display("[EDGE] Test 9: absorption");
        run_op(FP16_MAX, FP16_1, FP16_DMIN);
        @(negedge clk);
        if (result !== FP16_MAX) begin
            $display("[EDGE] FAIL(T9): got %h", result); errors = errors + 1;
        end

        // 10. Inf * 0 -> NaN
        $display("[EDGE] Test 10: Inf*0");
        run_op(FP16_INF, FP16_0, FP16_0);
        check_nan("Inf*0");

        // 11. sNaN * 1 -> qNaN (quieted)
        $display("[EDGE] Test 11: sNaN quieted");
        run_op(FP16_SNAN, FP16_1, FP16_0);
        check_nan("sNaN*1");

        // 12. Large product: 3 * 2 = 6
        $display("[EDGE] Test 12: 3*2=6");
        run_op(FP16_3, FP16_2, FP16_0);
        @(negedge clk);
        if (result !== 16'h4600) begin
            $display("[EDGE] FAIL(T12): got %h exp 4600", result); errors = errors + 1;
        end

        if (errors == 0)
            $display("*** FP16 FMA EDGE TEST PASSED ***");
        else
            $display("*** FP16 FMA EDGE TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish(1); end

endmodule
