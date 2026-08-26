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
        $dumpfile("tb_fp32_fma.vcd");
        $dumpvars(0, tb_fp32_fma);
        errors = 0;

        #25; rst_n = 1; #10;

        // Test 1: 1.0 * 1.0 + 0.0 = 1.0
        a = 32'h3F800000; b = 32'h3F800000; c = 32'h00000000;
        run_op; check(32'h3F800000, "1*1+0");

        // Test 2: 2.0 * 3.0 + 1.0 = 7.0
        a = 32'h40000000; b = 32'h40400000; c = 32'h3F800000;
        run_op; check(32'h40E00000, "2*3+1");

        // Test 3: 0.5 * 0.5 + 0.0 = 0.25
        a = 32'h3F000000; b = 32'h3F000000; c = 32'h00000000;
        run_op; check(32'h3E800000, "0.5*0.5+0");

        // Test 4: 1.0 * 0.0 + 0.0 = 0.0
        a = 32'h3F800000; b = 32'h00000000; c = 32'h00000000;
        run_op; check(32'h00000000, "1*0+0");

        // Test 5: -1.0 * 2.0 + 3.0 = 1.0
        a = 32'hBF800000; b = 32'h40000000; c = 32'h40400000;
        run_op; check(32'h3F800000, "-1*2+3");

        // Test 6: NaN * 1 = NaN
        a = 32'h7FC00000; b = 32'h3F800000; c = 32'h00000000;
        run_op; check(32'h7FC00000, "NaN*1");

        // Test 7: Inf * 0 = NaN
        a = 32'h7F800000; b = 32'h00000000; c = 32'h00000000;
        run_op; check(32'h7FC00000, "Inf*0");

        // Test 8: Inf + (-Inf) = NaN
        a = 32'h7F800000; b = 32'h3F800000; c = 32'hFF800000;
        run_op; check(32'h7FC00000, "Inf+(-Inf)");

        if (errors == 0)
            $display("*** FP32 FMA TEST PASSED ***");
        else
            $display("*** FP32 FMA TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
