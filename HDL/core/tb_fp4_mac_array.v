`timescale 1ns/1ps

module tb_fp4_mac_array;

    parameter ARRAY_SIZE = 4;

    reg clk, rst_n;
    reg [ARRAY_SIZE*8-1:0] act_in;
    reg act_valid, act_sop, act_eop;
    reg [7:0] weight_in;
    reg weight_load;
    reg [7:0] weight_row, weight_col;
    wire [ARRAY_SIZE*32-1:0] result_out;
    wire result_valid, result_sop, result_eop, busy;

    integer errors, i, j;

    fp4_mac_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PIPE_DEPTH(2)
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .act_in(act_in), .act_valid(act_valid),
        .act_sop(act_sop), .act_eop(act_eop),
        .weight_in(weight_in), .weight_load(weight_load),
        .weight_row(weight_row), .weight_col(weight_col),
        .result_out(result_out), .result_valid(result_valid),
        .result_sop(result_sop), .result_eop(result_eop),
        .busy(busy)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // E2M1 magnitude code for the low nibble plane (OCP MX):
    //   0=0, 1=0.5, 2=1.0, 3=1.5, 4=2.0, 5=3.0, 6=4.0, 7=6.0
    function [7:0] encode; input [3:0] e2m1; encode = {4'h0, e2m1}; endfunction

    initial begin
        $dumpfile("tb_fp4_mac_array.vcd");
        $dumpvars(0, tb_fp4_mac_array);

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

        // Reset
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Load identity weights: diagonal = 1.0 (code 2, d8=8), off-diagonal = 0
        $display("--- Loading identity weights ---");
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                @(posedge clk);
                weight_load = 1;
                weight_row = i[7:0];
                weight_col = j[7:0];
                weight_in = (i == j) ? encode(4'b0010) : 8'h00; // 1.0 / 0.0
            end
        end
        @(posedge clk);
        weight_load = 0;

        // Feed activations [1.0, 2.0, 3.0, 0.5] -> codes [2,4,5,1], d8 [8,16,24,4]
        $display("--- Feeding activations ---");
        @(posedge clk);
        act_in = {encode(4'b0001), encode(4'b0101), encode(4'b0100), encode(4'b0010)};
        act_valid = 1;
        act_sop = 1;
        act_eop = 1;
        @(posedge clk);
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        // Each row's weight is 1.0 (d8=8) in the identity, so col j = act_d8[j]*8.
        $display("--- Waiting for result ---");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (result_valid) begin
                // col0 = 8*8  = 64 (1.0)
                // col1 = 16*8 = 128 (2.0)
                // col2 = 24*8 = 192 (3.0)
                // col3 = 4*8  = 32  (0.5)
                if (result_out[31:0]    !== 32'd64 ||
                    result_out[63:32]   !== 32'd128 ||
                    result_out[95:64]   !== 32'd192 ||
                    result_out[127:96]  !== 32'd32) begin
                    $display("FAIL: identity result mismatch: [%0d %0d %0d %0d]",
                        result_out[31:0], result_out[63:32],
                        result_out[95:64], result_out[127:96]);
                    errors = errors + 1;
                end else begin
                    $display("PASS: identity result correct [1.0 2.0 3.0 0.5]");
                end
                if (result_sop !== 1'b1) begin
                    $display("FAIL: result_sop not 1 on result cycle");
                    errors = errors + 1;
                end
                if (result_eop !== 1'b1) begin
                    $display("FAIL: result_eop not 1 on result cycle");
                    errors = errors + 1;
                end
                @(posedge clk);
                if (result_valid) begin
                    $display("FAIL: result_valid stuck high after result");
                    errors = errors + 1;
                end
            end
        end

        // Reload a column with a non-identity weight (1.5, code 3, d8=12) in col 1,
        // then feed activations again to verify the multiply path.
        $display("--- Loading 1.5 weight in column 1 ---");
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
            @(posedge clk);
            weight_load = 1;
            weight_row = i[7:0];
            weight_col = 8'd1;
            weight_in = (i == 0) ? encode(4'b0011) : 8'h00; // 1.5 in row 0
        end
        @(posedge clk);
        weight_load = 0;

        // Activations [1.0, 0, 0, 0] -> only row 0 contributes to col1.
        // col1 raw = act_d8(1.0=8) * weight_d8(1.5=12) = 96 (physical 1.5).
        $display("--- Feeding scalar activation ---");
        @(posedge clk);
        act_in = {8'h00, 8'h00, 8'h00, encode(4'b0010)};
        act_valid = 1;
        act_sop = 1;
        act_eop = 1;
        @(posedge clk);
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        $display("--- Waiting for weighted result ---");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (result_valid) begin
                if (result_out[63:32] !== 32'd96) begin
                    $display("FAIL: 1.5-weighted col result %0d, expected 96",
                        result_out[63:32]);
                    errors = errors + 1;
                end else begin
                    $display("PASS: 1.5-weighted column result correct (96/64=1.5)");
                end
            end
        end

        $display("");
        if (errors == 0)
            $display("*** FP4 MAC ARRAY TEST PASSED ***");
        else
            $display("*** FP4 MAC ARRAY TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
