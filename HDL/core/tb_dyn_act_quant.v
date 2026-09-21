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
        // Regression (magnitude-preserving dequant): each nonzero INT8 magnitude
        // must reconstruct to |int8| * scale, NOT a constant full-scale value.
        // With scale[14:0] = 0x40 = 64: int8 1->0x0040, 2->0x0080, 3->0x00C0.
        // The old bug always returned {sign, scale} regardless of magnitude, so
        // int8=2,3 would wrongly produce 0x0040.
        $display("--- Test 2: Dequantize ---");
        mode = 1;
        d_valid_in = 0;
        d_scale_in = 16'h0040;
        @(posedge clk);
        #1;

        d_int8_in = 8'h01; d_valid_in = 1;
        @(posedge clk); #1;
        if (d_data_out !== 16'h0040) begin
            $display("FAIL dequant int8=1: out=%04h exp 0040", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int8=1 -> 0040");

        d_int8_in = 8'h02;
        @(posedge clk); #1;
        if (d_data_out !== 16'h0080) begin
            $display("FAIL dequant int8=2: out=%04h exp 0080", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int8=2 -> 0080");

        d_int8_in = 8'h03;
        @(posedge clk); #1;
        if (d_data_out !== 16'h00C0) begin
            $display("FAIL dequant int8=3: out=%04h exp 00C0", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int8=3 -> 00C0");

        d_int8_in = 8'hFF;   // -1, magnitude 1
        @(posedge clk); #1;
        if (d_data_out !== 16'h8040) begin
            $display("FAIL dequant int8=-1: out=%04h exp 8040", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int8=-1 (0xFF) -> 8040");

        d_int8_in = 8'hFE;   // -2, magnitude 2
        @(posedge clk); #1;
        if (d_data_out !== 16'h8080) begin
            $display("FAIL dequant int8=-2: out=%04h exp 8080", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int8=-2 (0xFE) -> 8080");
        d_valid_in = 0;

        $display("PASS: dequantize path exercised");

        $display("");
        if (errors == 0)
            $display("*** DYN ACT QUANT TEST PASSED ***");
        else
            $display("*** DYN ACT QUANT TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
