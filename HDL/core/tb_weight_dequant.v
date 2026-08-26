`timescale 1ns/1ps

module tb_weight_dequant;

    reg clk, rst_n;
    reg mode;
    reg [7:0] weight_in;
    reg nibble_sel;
    reg valid_in;

    wire [15:0] bf16_out;
    wire valid_out;

    weight_dequant uut (
        .clk(clk), .rst_n(rst_n),
        .mode(mode),
        .weight_in(weight_in), .nibble_sel(nibble_sel),
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
        mode = 1;
        send_and_check(8'h01, 16'h3F80, "INT8 +1");       // 1.0
        send_and_check(8'h7F, 16'h42FE, "INT8 +127");     // 127.0
        send_and_check(8'h80, 16'hC300, "INT8 -128");     // -128.0
        send_and_check(8'h00, 16'h0000, "INT8 0");        // 0.0

        $display("");
        if (errors == 0)
            $display("*** WEIGHT DEQUANT TEST PASSED ***");
        else
            $display("*** WEIGHT DEQUANT TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
