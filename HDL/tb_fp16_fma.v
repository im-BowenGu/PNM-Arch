`timescale 1ns/1ps

// =============================================================================
// tb_fp16_fma — self-checking testbench for FP16 FMA unit
//
// Tests basic operations: multiply, add, fused multiply-add, special values.
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
    reg [15:0] expected;

    task check;
        input [15:0] exp;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH: a=%h b=%h c=%h -> got %h, expected %h", a, b, c, result, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fp16_fma.vcd");
        $dumpvars(0, tb_fp16_fma);
        errors = 0;

        // Reset
        #25; rst_n = 1; #10;

        // Test 1: 1.0 * 1.0 + 0.0 = 1.0
        a = 16'h3C00; b = 16'h3C00; c = 16'h0000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h3C00);

        // Test 2: 2.0 * 3.0 + 1.0 = 7.0
        // 2.0 = 0x4000, 3.0 = 0x4200, 7.0 = 0x4700
        a = 16'h4000; b = 16'h4200; c = 16'h3C00;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h4700);

        // Test 3: 0.5 * 0.5 + 0.0 = 0.25
        // 0.5 = 0x3800, 0.25 = 0x3400
        a = 16'h3800; b = 16'h3800; c = 16'h0000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h3400);

        // Test 4: 1.0 * 0.0 + 0.0 = 0.0
        a = 16'h3C00; b = 16'h0000; c = 16'h0000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h0000);

        // Test 5: -1.0 * 2.0 + 3.0 = 1.0
        // -1.0 = 0xBC00, 2.0 = 0x4000, 3.0 = 0x4200
        a = 16'hBC00; b = 16'h4000; c = 16'h4200;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h3C00);

        if (errors == 0)
            $display("*** FP16 FMA TEST PASSED ***");
        else
            $display("*** FP16 FMA TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
