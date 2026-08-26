`timescale 1ns/1ps

// =============================================================================
// tb_int4_mac — Testbench for INT4 Multiply-Accumulate Unit
// =============================================================================

module tb_int4_mac;

    reg         clk;
    reg         rst_n;
    reg  [7:0]  a;
    reg         pack_select;
    reg  [7:0]  b;
    reg         b_pack_select;
    reg  [31:0] c;
    reg         valid_in;
    wire [31:0] result;
    wire        valid_out;

    int4_mac uut (
        .clk(clk),
        .rst_n(rst_n),
        .a(a),
        .pack_select(pack_select),
        .b(b),
        .b_pack_select(b_pack_select),
        .c(c),
        .valid_in(valid_in),
        .result(result),
        .valid_out(valid_out)
    );

    // Clock generation: 100 MHz
    always #5 clk = ~clk;

    integer errors;
    integer test_num;
    reg signed [31:0] expected;

    initial begin
        $dumpfile("tb_int4_mac.vcd");
        $dumpvars(0, tb_int4_mac);

        errors = 0;
        test_num = 0;

        // Reset
        clk = 0;
        rst_n = 0;
        a = 0;
        pack_select = 0;
        b = 0;
        b_pack_select = 0;
        c = 0;
        valid_in = 0;

        #20;
        rst_n = 1;
        #10;

        // =====================================================================
        // Test 1: 3 * 5 + 0 = 15 (low nibbles: 0x03 * 0x05)
        // =====================================================================
        test_num = test_num + 1;
        a = 8'h03;        // low nibble = 3
        pack_select = 0;  // use low nibble
        b = 8'h05;        // low nibble = 5
        b_pack_select = 0;
        c = 32'sd0;
        valid_in = 1;
        #10;
        valid_in = 0;
        #10; // wait for pipeline

        expected = 32'sd15;
        if (result !== expected) begin
            $display("FAIL [Test %0d]: 3*5+0 = %0d, expected %0d", test_num, result, expected);
            errors = errors + 1;
        end else begin
            $display("OK [Test %0d]: 3*5+0 = %0d", test_num, result);
        end

        // =====================================================================
        // Test 2: -2 * 4 + 10 = 2 (low nibbles: 0xFE lo=-2, 0x04 lo=4)
        // =====================================================================
        test_num = test_num + 1;
        a = 8'hFE;        // low nibble = 0xE = -2 (signed)
        pack_select = 0;
        b = 8'h04;        // low nibble = 4
        b_pack_select = 0;
        c = 32'sd10;
        valid_in = 1;
        #10;
        valid_in = 0;
        #10;

        expected = 32'sd2;
        if (result !== expected) begin
            $display("FAIL [Test %0d]: -2*4+10 = %0d, expected %0d", test_num, result, expected);
            errors = errors + 1;
        end else begin
            $display("OK [Test %0d]: -2*4+10 = %0d", test_num, result);
        end

        // =====================================================================
        // Test 3: 7 * 7 + 0 = 49 (high nibbles: 0x70 hi=7, 0x70 hi=7)
        // =====================================================================
        test_num = test_num + 1;
        a = 8'h70;        // high nibble = 7
        pack_select = 1;  // use high nibble
        b = 8'h70;        // high nibble = 7
        b_pack_select = 1;
        c = 32'sd0;
        valid_in = 1;
        #10;
        valid_in = 0;
        #10;

        expected = 32'sd49;
        if (result !== expected) begin
            $display("FAIL [Test %0d]: 7*7+0 = %0d, expected %0d", test_num, result, expected);
            errors = errors + 1;
        end else begin
            $display("OK [Test %0d]: 7*7+0 = %0d", test_num, result);
        end

        // =====================================================================
        // Test 4: -8 * -8 + 0 = 64 (low nibbles: 0x88 lo=0x8=-8)
        // =====================================================================
        test_num = test_num + 1;
        a = 8'h08;        // low nibble = 0x8 = -8 (signed 4-bit)
        pack_select = 0;
        b = 8'h08;        // low nibble = -8
        b_pack_select = 0;
        c = 32'sd0;
        valid_in = 1;
        #10;
        valid_in = 0;
        #10;

        expected = 32'sd64;
        if (result !== expected) begin
            $display("FAIL [Test %0d]: -8*-8+0 = %0d, expected %0d", test_num, result, expected);
            errors = errors + 1;
        end else begin
            $display("OK [Test %0d]: -8*-8+0 = %0d", test_num, result);
        end

        // =====================================================================
        // Test 5: Accumulation chain: 2*3+5=11, then 11+0=11
        // =====================================================================
        test_num = test_num + 1;
        a = 8'h02;
        pack_select = 0;
        b = 8'h03;
        b_pack_select = 0;
        c = 32'sd5;
        valid_in = 1;
        #10;
        valid_in = 0;
        #10;

        expected = 32'sd11;
        if (result !== expected) begin
            $display("FAIL [Test %0d]: 2*3+5 = %0d, expected %0d", test_num, result, expected);
            errors = errors + 1;
        end else begin
            $display("OK [Test %0d]: 2*3+5 = %0d", test_num, result);
        end

        // =====================================================================
        // Summary
        // =====================================================================
        #20;
        if (errors == 0)
            $display("*** INT4 MAC TEST PASSED ***");
        else
            $display("*** INT4 MAC TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
