`timescale 1ns/1ps

module tb_int4_mac_array;

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

    int4_mac_array #(
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

    initial begin
        $dumpfile("tb_int4_mac_array.vcd");
        $dumpvars(0, tb_int4_mac_array);

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

        // Load identity weights (diagonal = 1, rest = 0)
        $display("--- Loading identity weights ---");
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                @(posedge clk);
                weight_load = 1;
                weight_row = i[7:0];
                weight_col = j[7:0];
                weight_in = (i == j) ? 8'd1 : 8'd0;
            end
        end
        @(posedge clk);
        weight_load = 0;

        // Feed activation vector: [1, 2, 3, 4]
        $display("--- Feeding activations ---");
        @(posedge clk);
        act_in = {8'd4, 8'd3, 8'd2, 8'd1};
        act_valid = 1;
        act_sop = 1;
        act_eop = 1;
        @(posedge clk);
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        // Wait for result
        $display("--- Waiting for result ---");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (result_valid) begin
                $display("  Result[0]: %0d", result_out[31:0]);
                $display("  Result[1]: %0d", result_out[63:32]);
                $display("  Result[2]: %0d", result_out[95:64]);
                $display("  Result[3]: %0d", result_out[127:96]);
                // Identity matrix * [1,2,3,4] = [1,2,3,4]
                if (result_out[31:0] !== 32'd1 ||
                    result_out[63:32] !== 32'd2 ||
                    result_out[95:64] !== 32'd3 ||
                    result_out[127:96] !== 32'd4) begin
                    $display("FAIL: identity matrix result mismatch");
                    errors = errors + 1;
                end else begin
                    $display("PASS: identity matrix result correct");
                end
            end
        end

        $display("");
        if (errors == 0)
            $display("*** INT4 MAC ARRAY TEST PASSED ***");
        else
            $display("*** INT4 MAC ARRAY TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
