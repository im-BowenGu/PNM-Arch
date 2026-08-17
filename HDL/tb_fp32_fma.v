`timescale 1ns/1ps

// =============================================================================
// tb_fp32_fma — self-checking testbench for FP32 FMA unit
// =============================================================================
module tb_fp32_fma;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [31:0] a, b, c;
    reg         valid_in;
    wire [31:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    fp32_fma dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    task check;
        input [31:0] exp;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH: a=%h b=%h c=%h -> got %h, expected %h", a, b, c, result, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fp32_fma.vcd");
        $dumpvars(0, tb_fp32_fma);
        errors = 0;

        // Reset
        #25; rst_n = 1; #10;

        // Test 1: 1.0 * 1.0 + 0.0 = 1.0
        // 1.0 = 0x3F800000
        a = 32'h3F800000; b = 32'h3F800000; c = 32'h00000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(32'h3F800000);

        // Test 2: 2.0 * 3.0 + 1.0 = 7.0
        // 2.0 = 0x40000000, 3.0 = 0x40400000, 7.0 = 0x40E00000
        a = 32'h40000000; b = 32'h40400000; c = 32'h3F800000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(32'h40E00000);

        // Test 3: 0.5 * 0.5 + 0.0 = 0.25
        // 0.5 = 0x3F000000, 0.25 = 0x3E800000
        a = 32'h3F000000; b = 32'h3F000000; c = 32'h00000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(32'h3E800000);

        // Test 4: 1.0 * 0.0 + 0.0 = 0.0
        a = 32'h3F800000; b = 32'h00000000; c = 32'h00000000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(32'h00000000);

        // Test 5: -1.0 * 2.0 + 3.0 = 1.0
        // -1.0 = 0xBF800000, 2.0 = 0x40000000, 3.0 = 0x40400000
        a = 32'hBF800000; b = 32'h40000000; c = 32'h40400000;
        valid_in = 1; #10; valid_in = 0;
        repeat (4) @(posedge clk);
        check(32'h3F800000);

        if (errors == 0)
            $display("*** FP32 FMA TEST PASSED ***");
        else
            $display("*** FP32 FMA TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
