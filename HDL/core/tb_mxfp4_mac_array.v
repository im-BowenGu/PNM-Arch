`timescale 1ns/1ps

module tb_mxfp4_mac_array;

    parameter ARRAY_SIZE = 4;

    reg clk, rst_n;
    reg [ARRAY_SIZE*8-1:0] act_in;
    reg act_valid, act_sop, act_eop;
    reg [7:0] weight_in;
    reg weight_load;
    reg [7:0] weight_row, weight_col;
    reg [7:0] scale_in;
    reg scale_load;
    wire [ARRAY_SIZE*32-1:0] result_out;
    wire result_valid, result_sop, result_eop, busy;

    integer errors, i, j;

    mxfp4_mac_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PIPE_DEPTH(2)
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .act_in(act_in), .act_valid(act_valid),
        .act_sop(act_sop), .act_eop(act_eop),
        .weight_in(weight_in), .weight_load(weight_load),
        .weight_row(weight_row), .weight_col(weight_col),
        .scale_in(scale_in), .scale_load(scale_load),
        .result_out(result_out), .result_valid(result_valid),
        .result_sop(result_sop), .result_eop(result_eop),
        .busy(busy)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // E2M1 magnitude code: 2=1.0 (d8=8)
    function [7:0] encode; input [3:0] e2m1; encode = {4'h0, e2m1}; endfunction

    initial begin
        $dumpfile("tb_mxfp4_mac_array.vcd");
        $dumpvars(0, tb_mxfp4_mac_array);

        errors = 0;
        rst_n = 0;
        act_in = 0;
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;
        weight_in = 0;
        weight_load = 0;
        weight_row = 0;
        weight_col = 0;
        scale_in = 0;
        scale_load = 0;

        // Reset
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Load block scale for row 0: shift 1 (2^1), others default 0.
        $display("--- Loading block scale row0 = 1 ---");
        @(posedge clk);
        scale_load = 1;
        weight_row = 8'd0;
        scale_in = 8'd1;
        @(posedge clk);
        scale_load = 0;
        weight_row = 0;

        // Load weights: col 1, row 0 = 1.0 (code 2, d8=8), all others 0.
        $display("--- Loading weights ---");
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                @(posedge clk);
                weight_load = 1;
                weight_row = i[7:0];
                weight_col = j[7:0];
                weight_in = (i == 0 && j == 1) ? encode(4'b0010) : 8'h00;
            end
        end
        @(posedge clk);
        weight_load = 0;

        // Feed activation [1.0, 0, 0, 0] (act code 2, d8=8). Row 0 has block
        // scale 1, so col1 raw = act_d8(8) * (weight_d8(8) << 1 = 16) = 128
        // (physical 2.0; without scale it would be 64 -> 1.0).
        $display("--- Feeding activation ---");
        @(posedge clk);
        act_in = {8'h00, 8'h00, 8'h00, encode(4'b0010)};
        act_sop = 1;
        act_eop = 1;
        #1;
        act_valid = 1;
        @(posedge clk);
        #1;
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        $display("--- Waiting for scaled result ---");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (result_valid) begin
                if (result_out[63:32] !== 32'd128) begin
                    $display("FAIL: MXFP4 scaled col result %0d, expected 128",
                        result_out[63:32]);
                    errors = errors + 1;
                end else begin
                    $display("PASS: MXFP4 block scale applied (128/64=2.0)");
                end
                if (result_sop !== 1'b1 || result_eop !== 1'b1) begin
                    $display("FAIL: sop/eop not queued on result cycle");
                    errors = errors + 1;
                end
            end
        end

        // Verify scale hold: reload row 0 scale = 2 and re-feed; col1 should
        // become act_d8(8) * (8 << 2 = 32) = 256.
        $display("--- Reloading block scale row0 = 2 ---");
        @(posedge clk); @(posedge clk);
        scale_load = 1;
        weight_row = 8'd0;
        scale_in = 8'd2;
        @(posedge clk);
        scale_load = 0;
        weight_row = 0;

        @(posedge clk);
        act_in = {8'h00, 8'h00, 8'h00, encode(4'b0010)};
        act_sop = 1;
        act_eop = 1;
        #1;
        act_valid = 1;
        @(posedge clk);
        #1;
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        $display("--- Waiting for rescaled result ---");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (result_valid) begin
                if (result_out[63:32] !== 32'd256) begin
                    $display("FAIL: recomputed scale col result %0d, expected 256",
                        result_out[63:32]);
                    errors = errors + 1;
                end else begin
                    $display("PASS: MXFP4 scale reload correct (256/64=4.0)");
                end
            end
        end

        $display("");
        if (errors == 0)
            $display("*** MXFP4 MAC ARRAY TEST PASSED ***");
        else
            $display("*** MXFP4 MAC ARRAY TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
