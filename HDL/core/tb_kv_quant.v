`timescale 1ns/1ps

module tb_kv_quant;

    reg clk, rst_n, mode;
    reg [15:0] q_data_in;
    reg q_valid_in;
    wire [3:0] q_int4_out;
    wire [15:0] q_scale_out;
    wire q_scale_valid, q_valid_out, q_block_done;

    reg [3:0] d_int4_in;
    reg [15:0] d_scale_in;
    reg d_valid_in;
    wire [15:0] d_data_out;
    wire d_valid_out;

    kv_quant #(.BLOCK_SIZE(4), .DATA_WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .mode(mode),
        .q_data_in(q_data_in), .q_valid_in(q_valid_in),
        .q_int4_out(q_int4_out), .q_scale_out(q_scale_out),
        .q_scale_valid(q_scale_valid), .q_valid_out(q_valid_out),
        .q_block_done(q_block_done),
        .d_int4_in(d_int4_in), .d_scale_in(d_scale_in),
        .d_valid_in(d_valid_in),
        .d_data_out(d_data_out), .d_valid_out(d_valid_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors, i;
    reg [3:0] int4_results [0:3];
    reg [15:0] captured_scale;
    integer got_scale;

    task feed_block;
        input [15:0] v0, v1, v2, v3;
        begin
            // Drive inputs and wait for posedge DUT samples
            q_data_in = v0; q_valid_in = 1;
            @(posedge clk);  // DUT captures v0
            q_data_in = v1;
            @(posedge clk);  // DUT captures v1
            q_data_in = v2;
            @(posedge clk);  // DUT captures v2
            q_data_in = v3;
            @(posedge clk);  // DUT captures v3, block fills
            q_valid_in = 0;
            q_data_in = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_kv_quant.vcd");
        $dumpvars(0, tb_kv_quant);

        errors = 0;
        rst_n = 0;
        mode = 0;
        q_data_in = 0;
        q_valid_in = 0;
        d_int4_in = 0;
        d_scale_in = 0;
        d_valid_in = 0;

        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- Test 1: Quantize a block of 4 values ----
        $display("--- Test 1: Quantize block ---");
        mode = 0;
        captured_scale = 0;
        got_scale = 0;

        feed_block(16'h3F80, 16'h4000, 16'h4040, 16'h4080);

        // Wait for emit phase (up to 12 cycles)
        for (i = 0; i < 12; i = i + 1) begin
            @(posedge clk);
            if (q_scale_valid) begin
                captured_scale = q_scale_out;
                got_scale = 1;
                $display("  Scale: %04h", q_scale_out);
            end
            if (q_valid_out) begin
                int4_results[i % 4] = q_int4_out;
                $display("  INT4[%0d]: %02h", i % 4, q_int4_out);
            end
            if (q_block_done)
                $display("  Block done");
        end

        if (!got_scale) begin
            $display("FAIL: no scale factor emitted");
            errors = errors + 1;
        end else begin
            $display("PASS: block quantized, scale=%04h", captured_scale);
        end

        // ---- Test 2: Dequantize ----
        // Regression (magnitude-preserving dequant): each nonzero INT4 magnitude
        // must reconstruct to |int4| * scale, NOT a constant full-scale value.
        // With scale[14:0] = 0x40 = 64: int4 1->0x0040, 2->0x0080, 3->0x00C0.
        // The old bug always returned {sign, scale} regardless of magnitude, so
        // int4=2,3 would wrongly produce 0x0040.
        $display("--- Test 2: Dequantize ---");
        mode = 1;
        d_valid_in = 0;
        d_scale_in = 16'h0040;
        @(posedge clk);
        #1;   // settle past the posedge race onto the registered output

        // Stream one value per cycle; read each result one cycle later with #1
        // so the non-blocking output update is visible.
        d_int4_in = 4'h1; d_valid_in = 1;
        @(posedge clk); #1;
        if (d_data_out !== 16'h0040) begin
            $display("FAIL dequant int4=1: out=%04h exp 0040", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int4=1 -> 0040");

        d_int4_in = 4'h2;
        @(posedge clk); #1;
        if (d_data_out !== 16'h0080) begin
            $display("FAIL dequant int4=2: out=%04h exp 0080", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int4=2 -> 0080");

        d_int4_in = 4'h3;
        @(posedge clk); #1;
        if (d_data_out !== 16'h00C0) begin
            $display("FAIL dequant int4=3: out=%04h exp 00C0", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int4=3 -> 00C0");

        d_int4_in = 4'hF;   // -1, magnitude 1
        @(posedge clk); #1;
        if (d_data_out !== 16'h8040) begin
            $display("FAIL dequant int4=-1: out=%04h exp 8040", d_data_out);
            errors = errors + 1;
        end else $display("  Dequant int4=-1 (0xF) -> 8040");
        d_valid_in = 0;

        $display("PASS: dequantize path exercised");

        $display("");
        if (errors == 0)
            $display("*** KV QUANT TEST PASSED ***");
        else
            $display("*** KV QUANT TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
