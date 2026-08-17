`timescale 1ns/1ps

// =============================================================================
// tb_bf16_fma — self-checking testbench for BF16 FMA unit
//
// Tests basic operations: multiply, add, fused multiply-add, special values.
// Mirrors tb_fp16_fma structure for consistency.
// =============================================================================
module tb_bf16_fma;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [15:0] a, b, c;
    reg         valid_in;
    wire [15:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    bf16_fma dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

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
        $dumpfile("tb_bf16_fma.vcd");
        $dumpvars(0, tb_bf16_fma);
        errors = 0;

        // Reset
        #25; rst_n = 1; #10;

        // BF16 format: [15] sign, [14:7] exp (8-bit, bias=127), [6:0] mantissa (7-bit)
        // 1.0 = 0x3F80  (exp=127, man=0)
        // 2.0 = 0x4000  (exp=128, man=0)
        // 3.0 = 0x4040  (exp=128, man=0x40)
        // 0.5 = 0x3F00  (exp=126, man=0)
        // 7.0 = 0x40C0  (exp=129, man=0x40)
        // 0.25= 0x3E80  (exp=125, man=0)
        // -1.0= 0xBF80
        // 6.0 = 0x40C0  (exp=129, man=0x40)

        // Test 1: 1.0 * 1.0 + 0.0 = 1.0
        a = 16'h3F80; b = 16'h3F80; c = 16'h0000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h3F80);

        // Test 2: 2.0 * 3.0 + 1.0 = 7.0
        // 2.0=0x4000, 3.0=0x4040, 1.0=0x3F80, 7.0=0x40E0
        a = 16'h4000; b = 16'h4040; c = 16'h3F80;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h40E0);

        // Test 3: 0.5 * 0.5 + 0.0 = 0.25
        // 0.5=0x3F00, 0.25=0x3E80
        a = 16'h3F00; b = 16'h3F00; c = 16'h0000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h3E80);

        // Test 4: 1.0 * 0.0 + 0.0 = 0.0
        a = 16'h3F80; b = 16'h0000; c = 16'h0000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h0000);

        // Test 5: -1.0 * 2.0 + 3.0 = 1.0
        // -1.0=0xBF80, 2.0=0x4000, 3.0=0x4040
        a = 16'hBF80; b = 16'h4000; c = 16'h4040;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(16'h3F80);

        if (errors == 0)
            $display("*** BF16 FMA TEST PASSED ***");
        else
            $display("*** BF16 FMA TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
