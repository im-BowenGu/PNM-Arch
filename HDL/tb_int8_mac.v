`timescale 1ns/1ps

// =============================================================================
// tb_int8_mac — self-checking testbench for INT8 MAC unit
// =============================================================================
module tb_int8_mac;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [7:0]  a, b;
    reg  [31:0] c;
    reg         valid_in;
    wire [31:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    int8_mac dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    task check;
        input [31:0] exp;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH: a=%d b=%d c=%d -> got %d, expected %d", $signed(a), $signed(b), $signed(c), $signed(result), $signed(exp));
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_int8_mac.vcd");
        $dumpvars(0, tb_int8_mac);
        errors = 0;

        // Reset
        #25; rst_n = 1; #10;

        // Test 1: 2 * 3 + 0 = 6
        a = 8'd2; b = 8'd3; c = 32'd0;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(32'd6);

        // Test 2: -5 * 4 + 10 = -10
        a = -8'd5; b = 8'd4; c = 32'd10;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(-32'd10);

        // Test 3: 127 * 1 + 0 = 127 (max positive)
        a = 8'd127; b = 8'd1; c = 32'd0;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(32'd127);

        // Test 4: -128 * -1 + 0 = 128 (min negative * -1)
        a = -8'd128; b = -8'd1; c = 32'd0;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(32'd128);

        // Test 5: 10 * 10 + 100 = 200
        a = 8'd10; b = 8'd10; c = 32'd100;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(32'd200);

        // Test 6: Accumulation chain: 1*1 + 0 = 1, then 2*2 + 1 = 5
        a = 8'd1; b = 8'd1; c = 32'd0;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(32'd1);
        a = 8'd2; b = 8'd2; c = result;
        valid_in = 1; #10; valid_in = 0;
        repeat (3) @(posedge clk);
        check(32'd5);

        if (errors == 0)
            $display("*** INT8 MAC TEST PASSED ***");
        else
            $display("*** INT8 MAC TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
