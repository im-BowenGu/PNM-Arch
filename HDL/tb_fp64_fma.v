`timescale 1ns/1ps

// =============================================================================
// tb_fp64_fma — self-checking testbench for FP64 FMA unit
// =============================================================================
module tb_fp64_fma;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [63:0] a, b, c;
    reg         valid_in;
    wire [63:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    fp64_fma dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    task check;
        input [63:0] exp;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH: a=%h b=%h c=%h -> got %h, expected %h", a, b, c, result, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fp64_fma.vcd");
        $dumpvars(0, tb_fp64_fma);
        errors = 0;

        // Reset
        #25; rst_n = 1; #10;

        // Test 1: 1.0 * 1.0 + 0.0 = 1.0
        // 1.0 = 0x3FF0000000000000
        a = 64'h3FF0000000000000; b = 64'h3FF0000000000000; c = 64'h0000000000000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(64'h3FF0000000000000);

        // Test 2: 2.0 * 3.0 + 1.0 = 7.0
        // 2.0 = 0x4000000000000000, 3.0 = 0x4008000000000000, 7.0 = 0x401C000000000000
        a = 64'h4000000000000000; b = 64'h4008000000000000; c = 64'h3FF0000000000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(64'h401C000000000000);

        // Test 3: 0.5 * 0.5 + 0.0 = 0.25
        // 0.5 = 0x3FE0000000000000, 0.25 = 0x3FD0000000000000
        a = 64'h3FE0000000000000; b = 64'h3FE0000000000000; c = 64'h0000000000000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(64'h3FD0000000000000);

        // Test 4: 1.0 * 0.0 + 0.0 = 0.0
        a = 64'h3FF0000000000000; b = 64'h0000000000000000; c = 64'h0000000000000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(64'h0000000000000000);

        // Test 5: -1.0 * 2.0 + 3.0 = 1.0
        // -1.0 = 0xBFF0000000000000, 2.0 = 0x4000000000000000, 3.0 = 0x4008000000000000
        a = 64'hBFF0000000000000; b = 64'h4000000000000000; c = 64'h4008000000000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(64'h3FF0000000000000);

        if (errors == 0)
            $display("*** FP64 FMA TEST PASSED ***");
        else
            $display("*** FP64 FMA TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
