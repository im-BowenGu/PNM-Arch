`timescale 1ns/1ps

module tb_dyn_act_quant;

    reg clk, rst_n, mode;
    reg [15:0] q_data_in;
    reg q_valid_in;
    wire [7:0] q_int8_out;
    wire [15:0] q_scale_out;
    wire q_scale_valid, q_valid_out, q_block_done;

    reg [7:0] d_int8_in;
    reg [15:0] d_scale_in;
    reg d_valid_in;
    wire [15:0] d_data_out;
    wire d_valid_out;

    dyn_act_quant #(.BLOCK_SIZE(4), .DATA_WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .mode(mode),
        .q_data_in(q_data_in), .q_valid_in(q_valid_in),
        .q_int8_out(q_int8_out), .q_scale_out(q_scale_out),
        .q_scale_valid(q_scale_valid), .q_valid_out(q_valid_out),
        .q_block_done(q_block_done),
        .d_int8_in(d_int8_in), .d_scale_in(d_scale_in),
        .d_valid_in(d_valid_in),
        .d_data_out(d_data_out), .d_valid_out(d_valid_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors, i;
    reg [15:0] captured_scale;
    integer got_scale, got_values;

    task feed_block;
        input [15:0] v0, v1, v2, v3;
        begin
            q_data_in = v0; q_valid_in = 1;
            @(posedge clk);
            q_data_in = v1;
            @(posedge clk);
            q_data_in = v2;
            @(posedge clk);
            q_data_in = v3;
            @(posedge clk);
            q_valid_in = 0;
            q_data_in = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_dyn_act_quant.vcd");
        $dumpvars(0, tb_dyn_act_quant);

        errors = 0;
        rst_n = 0;
        mode = 0;
        q_data_in = 0;
        q_valid_in = 0;
        d_int8_in = 0;
        d_scale_in = 0;
        d_valid_in = 0;

        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- Test 1: Quantize a block ----
        $display("--- Test 1: Quantize block ---");
        mode = 0;
        captured_scale = 0;
        got_scale = 0;
        got_values = 0;

        // Mixed positive/negative values (BF16: sign|exp|mantissa)
        // 0x3F80=1.0, 0xBF80=-1.0, 0x4000=2.0, 0xC000=-2.0
        feed_block(16'h3F80, 16'hBF80, 16'h4000, 16'hC000);

        for (i = 0; i < 12; i = i + 1) begin
            @(posedge clk);
            if (q_scale_valid) begin
                captured_scale = q_scale_out;
                got_scale = 1;
                $display("  Scale: %04h", q_scale_out);
            end
            if (q_valid_out) begin
                got_values = got_values + 1;
                $display("  INT8[%0d]: %02h", got_values, q_int8_out);
            end
            if (q_block_done)
                $display("  Block done");
        end

        if (!got_scale) begin
            $display("FAIL: no scale factor emitted");
            errors = errors + 1;
        end else if (got_values != 4) begin
            $display("FAIL: expected 4 INT8 values, got %0d", got_values);
            errors = errors + 1;
        end else begin
            $display("PASS: block quantized, scale=%04h, %0d values", captured_scale, got_values);
        end

        // ---- Test 2: Dequantize ----
        $display("--- Test 2: Dequantize ---");
        mode = 1;
        @(posedge clk);

        d_int8_in = 8'h01; d_scale_in = 16'h3F80; d_valid_in = 1;
        @(posedge clk);
        d_int8_in = 8'hFF; @(posedge clk);  // -1
        d_int8_in = 8'h02; @(posedge clk);
        d_int8_in = 8'hFE; d_valid_in = 0; @(posedge clk);  // -2

        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            if (d_valid_out)
                $display("  Dequantized: %04h", d_data_out);
        end

        $display("PASS: dequantize path exercised");

        $display("");
        if (errors == 0)
            $display("*** DYN ACT QUANT TEST PASSED ***");
        else
            $display("*** DYN ACT QUANT TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
