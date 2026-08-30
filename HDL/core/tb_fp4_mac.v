`timescale 1ns/1ps

module tb_fp4_mac;

    reg clk, rst_n;
    reg [7:0] a, b;
    reg pack_select, b_pack_select;
    reg [31:0] c;
    reg [3:0] wshift;
    reg valid_in;
    wire [31:0] result;
    wire valid_out;

    integer errors;

    fp4_mac uut (
        .clk(clk), .rst_n(rst_n),
        .a(a), .pack_select(pack_select),
        .b(b), .b_pack_select(b_pack_select),
        .c(c), .wshift(wshift),
        .valid_in(valid_in),
        .result(result), .valid_out(valid_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task pump;
        input [31:0] exp;
        input [8*24-1:0] msg;
        integer i;
        begin
            @(posedge clk);
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            for (i = 0; i < 4; i = i + 1) begin
                @(posedge clk);
                if (valid_out) begin
                    if (result !== exp) begin
                        $display("FAIL [%0s]: got %0d, expected %0d", msg, result, exp);
                        errors = errors + 1;
                    end else begin
                        $display("PASS [%0s]: %0d", msg, result);
                    end
                end
            end
        end
    endtask

    // E2M1 magnitude codes (OCP MX): 0=0,1=0.5,2=1.0,3=1.5,4=2.0,5=3.0,6=4.0,7=6.0
    initial begin
        $dumpfile("tb_fp4_mac.vcd");
        $dumpvars(0, tb_fp4_mac);

        errors = 0;
        rst_n = 0;
        a = 0; b = 0; pack_select = 0; b_pack_select = 0;
        c = 0; wshift = 0; valid_in = 0;

        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Low-nibble plane: a=1.0 (code 2, d8=8), b=1.0 (d8=8) -> 64
        a = 8'h02; b = 8'h02;
        pack_select = 0; b_pack_select = 0; c = 0; wshift = 0;
        pump(32'd64, "1.0 x 1.0 = 64");

        // Accumulate: c = 64, add again -> 128
        c = 32'd64;
        pump(32'd128, "accumulate 64+64 = 128");
        c = 0;

        // High-nibble plane: a high=1.0 (code 2, d8=8), b high=0.5 (code 1, d8=4)
        a = 8'h20; b = 8'h10;
        pack_select = 1; b_pack_select = 1; c = 0; wshift = 0;
        pump(32'd32, "1.0 x 0.5 = 32");

        // Negative: a=-2.0 (low=0x4, sign set -> 0xC, d8=-16), b=1.0 -> -128
        a = 8'h0C; b = 8'h02;
        pack_select = 0; b_pack_select = 0; c = 0; wshift = 0;
        pump(-32'sd128, "-2.0 x 1.0 = -128");

        // MXFP4 block scale: a=1.0 (d8=8), b=1.5 (code 3, d8=12), wshift=2
        // b_scaled = 12<<2 = 48 -> 8*48 = 384
        a = 8'h02; b = 8'h03;
        pack_select = 0; b_pack_select = 0; c = 0; wshift = 4'd2;
        pump(32'd384, "MXFP4 1.0 x (1.5<<2) = 384");

        $display("");
        if (errors == 0)
            $display("*** FP4 MAC TEST PASSED ***");
        else
            $display("*** FP4 MAC TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
