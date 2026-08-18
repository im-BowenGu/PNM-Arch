`timescale 1ns/1ps

// =============================================================================
// tb_fp16_fma — self-checking testbench for FP16 FMA unit
// Tests: basic ops, NaN propagation, Inf arithmetic, underflow, rounding
// =============================================================================
module tb_fp16_fma;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [15:0] a, b, c;
    reg         valid_in;
    wire [15:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    fp16_fma dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    task check;
        input [15:0] exp;
        input [8*32-1:0] name;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH (%0s): a=%h b=%h c=%h -> got %h, expected %h", name, a, b, c, result, exp);
                errors = errors + 1;
            end
        end
    endtask

    task run_op;
        begin
            valid_in = 1; #10; valid_in = 0;
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_fp16_fma.vcd");
        $dumpvars(0, tb_fp16_fma);
        errors = 0;

        // Reset
        #25; rst_n = 1; #10;

        // --- Basic operations ---

        // Test 1: 1.0 * 1.0 + 0.0 = 1.0
        a = 16'h3C00; b = 16'h3C00; c = 16'h0000;
        run_op; check(16'h3C00, "1*1+0");

        // Test 2: 2.0 * 3.0 + 1.0 = 7.0
        a = 16'h4000; b = 16'h4200; c = 16'h3C00;
        run_op; check(16'h4700, "2*3+1");

        // Test 3: 0.5 * 0.5 + 0.0 = 0.25
        a = 16'h3800; b = 16'h3800; c = 16'h0000;
        run_op; check(16'h3400, "0.5*0.5+0");

        // Test 4: 1.0 * 0.0 + 0.0 = 0.0
        a = 16'h3C00; b = 16'h0000; c = 16'h0000;
        run_op; check(16'h0000, "1*0+0");

        // Test 5: -1.0 * 2.0 + 3.0 = 1.0
        a = 16'hBC00; b = 16'h4000; c = 16'h4200;
        run_op; check(16'h3C00, "-1*2+3");

        // --- NaN tests ---

        // Test 6: NaN * anything = NaN
        a = 16'h7E00; b = 16'h3C00; c = 16'h0000;
        run_op; check(16'h7E00, "NaN*1+0");

        // Test 7: anything * NaN = NaN
        a = 16'h3C00; b = 16'h7E00; c = 16'h0000;
        run_op; check(16'h7E00, "1*NaN+0");

        // Test 8: NaN + NaN = NaN
        a = 16'h7E00; b = 16'h3C00; c = 16'h7E00;
        run_op; check(16'h7E00, "NaN*1+NaN");

        // --- Infinity tests ---

        // Test 9: Inf * 1 + 0 = Inf
        a = 16'h7C00; b = 16'h3C00; c = 16'h0000;
        run_op; check(16'h7C00, "Inf*1+0");

        // Test 10: -Inf * 1 + 0 = -Inf
        a = 16'hFC00; b = 16'h3C00; c = 16'h0000;
        run_op; check(16'hFC00, "-Inf*1+0");

        // Test 11: Inf * 0 = NaN
        a = 16'h7C00; b = 16'h0000; c = 16'h0000;
        run_op; check(16'h7E00, "Inf*0+0");

        // Test 12: Inf + Inf = Inf
        a = 16'h7C00; b = 16'h3C00; c = 16'h7C00;
        run_op; check(16'h7C00, "Inf*1+Inf");

        // Test 13: Inf + (-Inf) = NaN
        a = 16'h7C00; b = 16'h3C00; c = 16'hFC00;
        run_op; check(16'h7E00, "Inf*1+(-Inf)");

        // --- Underflow test ---

        // Test 14: smallest denormal * 1 + 0 = denormal (may underflow to zero)
        a = 16'h0001; b = 16'h3C00; c = 16'h0000;
        run_op;
        // Result should be 0x0001 (denormal) or 0x0000 (flush to zero)
        if (result !== 16'h0000 && result !== 16'h0001) begin
            $display("[TB] MISMATCH (underflow): a=%h b=%h c=%h -> got %h, expected 0x0000 or 0x0001", a, b, c, result);
            errors = errors + 1;
        end

        // --- Rounding edge case ---

        // Test 15: 1.0 + 2^(-11) should round to nearest
        // 1.0 = 0x3C00, 2^(-11) = 0x0400
        // 1.0 + 2^(-11) = 1.000488... rounds to 1.0 in FP16 (guard=0)
        a = 16'h3C00; b = 16'h3C00; c = 16'h0400;
        run_op; check(16'h3C00, "1+eps");

        if (errors == 0)
            $display("*** FP16 FMA TEST PASSED ***");
        else
            $display("*** FP16 FMA TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
