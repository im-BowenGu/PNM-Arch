`timescale 1ns/1ps

// =============================================================================
// tb_ternary_acc — self-checking testbench for the BitNet b1.58 ternary
// select-add accumulator (ternary_acc.v): result = c + code(b)*a,
// code(b) in {+1, -1, 0} from b[1:0].
// =============================================================================
module tb_ternary_acc;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [7:0]  a, b;
    reg  [31:0] c;
    reg         valid_in;
    wire [31:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    ternary_acc dut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .b(b), .c(c), .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    integer errors;

    task check;
        input [31:0] exp;
        begin
            if (result !== exp) begin
                $display("[TB] MISMATCH: a=%0d b[1:0]=%b c=%0d -> got %0d, expected %0d",
                         $signed(a), b[1:0], $signed(c), $signed(result), $signed(exp));
                errors = errors + 1;
            end
        end
    endtask

    task apply;
        input [7:0] aa;
        input [7:0] bb;
        input [31:0] cc;
        begin
            a = aa; b = bb; c = cc;
            valid_in = 1; #10; valid_in = 0;
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_ternary_acc.vcd");
        $dumpvars(0, tb_ternary_acc);
        errors = 0;

        #25; rst_n = 1; #10;

        // code +1: add activation
        apply(8'd5,   8'b0000_0001, 32'd0);   check(32'd5);
        // code -1: subtract activation
        apply(8'd5,   8'b0000_0010, 32'd0);   check(-32'd5);
        // code 0: pass accumulator through
        apply(8'd5,   8'b0000_0000, 32'd7);   check(32'd7);

        // signed activation, +1 / -1
        apply(-8'd3,  8'b0000_0001, 32'd10);  check(32'd7);
        apply(-8'd3,  8'b0000_0010, 32'd10);  check(32'd13);

        // extremes
        apply(8'd127, 8'b0000_0001, 32'd0);   check(32'd127);
        apply(-8'd128,8'b0000_0010, 32'd0);   check(32'd128);

        // only b[1:0] selects: 8'h21 -> +1, 8'hFE -> -1
        apply(8'd9,   8'h21,        32'd1);   check(32'd10);
        apply(8'd9,   8'hFE,        32'd1);   check(-32'd8);

        // accumulation chain: +4 then -4 over the accumulator
        apply(8'd4,   8'b0000_0001, 32'd0);   check(32'd4);
        apply(8'd4,   8'b0000_0010, 32'd4);   check(32'd0);

        if (errors == 0)
            $display("*** TERNARY ACC TEST PASSED ***");
        else
            $display("*** TERNARY ACC TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
