`timescale 1ns/1ps

module tb_weight_dequant;

    reg clk, rst_n;
    reg [1:0] mode;
    reg [7:0] weight_in;
    reg nibble_sel;
    reg [7:0] scale_in;
    reg valid_in;

    wire [15:0] bf16_out;
    wire valid_out;

    weight_dequant uut (
        .clk(clk), .rst_n(rst_n),
        .mode(mode),
        .weight_in(weight_in), .nibble_sel(nibble_sel),
        .scale_in(scale_in),
        .valid_in(valid_in),
        .bf16_out(bf16_out), .valid_out(valid_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors;
    reg [15:0] last_bf16;

    task send_and_check;
        input [7:0] w;
        input [15:0] exp;
        input [8*24-1:0] msg;
        begin
            @(posedge clk);
            weight_in = w;
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            // wait for valid_out
            repeat(3) begin
                @(posedge clk);
                if (valid_out) begin
                    last_bf16 = bf16_out;
                    if (bf16_out !== exp) begin
                        $display("FAIL [%0s]: got 0x%04x, expected 0x%04x", msg, bf16_out, exp);
                        errors = errors + 1;
                    end else begin
                        $display("PASS [%0s]: 0x%04x", msg, bf16_out);
                    end
                end
            end
        end
    endtask

    initial begin
        $dumpfile("tb_weight_dequant.vcd");
        $dumpvars(0, tb_weight_dequant);

        errors = 0;
        rst_n = 0;
        mode = 0;
        weight_in = 0;
        nibble_sel = 0;
        scale_in = 0;
        valid_in = 0;
        last_bf16 = 0;

        @(posedge clk);
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // INT4 tests (mode=0)
        mode = 0;
        nibble_sel = 0;  // low nibble
        send_and_check(8'h01, 16'h3F80, "INT4 low +1");   // 1.0
        send_and_check(8'h02, 16'h4000, "INT4 low +2");   // 2.0
        send_and_check(8'h0F, 16'hBF80, "INT4 low -1");   // -1.0
        send_and_check(8'h08, 16'hC100, "INT4 low -8");   // -8.0
        send_and_check(8'h00, 16'h0000, "INT4 low 0");    // 0.0

        nibble_sel = 1;  // high nibble
        send_and_check(8'h30, 16'h4040, "INT4 high +3");   // 3.0
        send_and_check(8'h70, 16'h40E0, "INT4 high +7");   // 7.0
        send_and_check(8'h80, 16'hC180, "INT4 high -8");   // -8.0

        // INT8 tests (mode=1)
        mode = 2'b01;
        send_and_check(8'h01, 16'h3F80, "INT8 +1");       // 1.0
        send_and_check(8'h7F, 16'h42FE, "INT8 +127");     // 127.0
        send_and_check(8'h80, 16'hC300, "INT8 -128");     // -128.0
        send_and_check(8'h00, 16'h0000, "INT8 0");        // 0.0

        // FP4 tests (mode=2, E2M1 nibble -> BF16, OCP MX table)
        mode = 2'b10;
        nibble_sel = 0;
        send_and_check(8'h02, 16'h3F80, "FP4 low 1.0");   // 1.0
        send_and_check(8'h01, 16'h3F00, "FP4 low 0.5");   // 0.5
        send_and_check(8'h03, 16'h3FC0, "FP4 low 1.5");   // 1.5
        send_and_check(8'h07, 16'h40C0, "FP4 low 6.0");   // 6.0
        send_and_check(8'h06, 16'h4080, "FP4 low 4.0");   // 4.0
        send_and_check(8'h0C, 16'hC000, "FP4 low -2.0");  // -2.0
        send_and_check(8'h00, 16'h0000, "FP4 low 0");     // 0
        nibble_sel = 1;
        send_and_check(8'h50, 16'h4040, "FP4 high 3.0");  // 3.0

        // MXFP4 tests (mode=3): FP4 nibble with 2^scale block exponent
        mode = 2'b11;
        nibble_sel = 0;
        scale_in = 8'd1;  // x2
        send_and_check(8'h02, 16'h4000, "MXFP4 1.0<<1");      // 2.0
        send_and_check(8'h03, 16'h4040, "MXFP4 1.5<<1");      // 3.0
        scale_in = 8'd3;  // x8
        send_and_check(8'h01, 16'h4080, "MXFP4 0.5<<3");      // 4.0
        scale_in = 8'd0;
        send_and_check(8'h02, 16'h3F80, "MXFP4 1.0<<0");      // 1.0

        $display("");
        if (errors == 0)
            $display("*** WEIGHT DEQUANT TEST PASSED ***");
        else
            $display("*** WEIGHT DEQUANT TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
