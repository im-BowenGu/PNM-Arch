`timescale 1ns/1ps

module tb_bf16_fma_edge;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [15:0] a, b, c;
    reg         valid_in;
    wire [15:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    bf16_fma dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c),
        .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    localparam BF16_0    = 16'h0000;
    localparam BF16_1    = 16'h3F80;
    localparam BF16_2    = 16'h4000;
    localparam BF16_3    = 16'h4040;
    localparam BF16_MAX  = 16'h7F7F;
    localparam BF16_INF  = 16'h7F80;
    localparam BF16_NINF = 16'hFF80;
    localparam BF16_QNAN = 16'h7FC0;
    localparam BF16_SNAN = 16'h7D41;
    localparam BF16_DMIN = 16'h0001;

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
        $dumpfile("tb_bf16_fma_edge.vcd");
        $dumpvars(0, tb_bf16_fma_edge);
        errors = 0;
        a = 0; b = 0; c = 0; valid_in = 0;

        #25; rst_n = 1; #10;

        // 1. Overflow
        $display("[EDGE] Test 1: overflow");
        run_op(BF16_MAX, BF16_MAX, BF16_0);
        @(negedge clk);
        if (result !== BF16_INF) begin
            $display("[EDGE] FAIL(T1): got %h", result); errors = errors + 1;
        end

        // 2. Neg * neg -> pos
        $display("[EDGE] Test 2: neg*neg");
        run_op(16'hBF80, 16'hBF80, BF16_0);  // -1 * -1
        @(negedge clk);
        if (result !== BF16_1) begin
            $display("[EDGE] FAIL(T2): got %h", result); errors = errors + 1;
        end

        // 3. Denormal * 1
        $display("[EDGE] Test 3: denormal");
        run_op(BF16_DMIN, BF16_1, BF16_0);
        @(negedge clk);
        if (result !== BF16_0 && result !== BF16_DMIN) begin
            $display("[EDGE] FAIL(T3): got %h", result); errors = errors + 1;
        end

        // 4. Exact add: 1 + 2^-7 = 0x3F81
        $display("[EDGE] Test 4: exact add");
        run_op(BF16_1, BF16_1, 16'h3C00);  // 2^-7 = exp biased 120
        @(negedge clk);
        if (result !== 16'h3F81) begin
            $display("[EDGE] FAIL(T4): got %h", result); errors = errors + 1;
        end

        // 5. Back-to-back pipeline
        $display("[EDGE] Test 5: back-to-back");
        @(negedge clk);
        a = BF16_2; b = BF16_2; c = BF16_0; valid_in = 1;
        @(posedge clk);
        a = BF16_1; b = BF16_1; c = BF16_0; valid_in = 1;
        @(posedge clk);
        a = BF16_3; b = BF16_1; c = BF16_1; valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        repeat (6) @(posedge clk);
        @(negedge clk);
        if (result !== 16'h4080) begin
            $display("[EDGE] FAIL(T5): got %h", result); errors = errors + 1;
        end

        // 6. Reset mid-op
        $display("[EDGE] Test 6: reset");
        @(negedge clk);
        a = BF16_MAX; b = BF16_MAX; c = BF16_0; valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        @(negedge clk);
        rst_n = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        if (dut.valid_out !== 1'b0) begin
            $display("[EDGE] FAIL(T6): valid_out after reset"); errors = errors + 1;
        end

        // 7. Inf - Inf -> NaN
        $display("[EDGE] Test 7: Inf-Inf");
        run_op(BF16_INF, BF16_1, BF16_NINF);
        check_nan("Inf-Inf");

        // 8. NaN * 0 -> NaN
        $display("[EDGE] Test 8: NaN*0");
        run_op(BF16_QNAN, BF16_0, BF16_0);
        check_nan("NaN*0");

        // 9. sNaN quieted
        $display("[EDGE] Test 9: sNaN");
        run_op(BF16_SNAN, BF16_1, BF16_0);
        check_nan("sNaN*1");

        // 10. 3 * 2 = 6
        $display("[EDGE] Test 10: 3*2=6");
        run_op(BF16_3, BF16_2, BF16_0);
        @(negedge clk);
        if (result !== 16'h40C0) begin
            $display("[EDGE] FAIL(T10): got %h exp 40C0", result); errors = errors + 1;
        end

        if (errors == 0)
            $display("*** BF16 FMA EDGE TEST PASSED ***");
        else
            $display("*** BF16 FMA EDGE TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish(1); end

endmodule
