`timescale 1ns/1ps

// tb_fp32_mac_array — self-checking testbench for fp32_mac_array
//
// Tests: weight loading, 2×2 matrix multiply, result collection.
// Exit 0 on success, non-zero on failure.

module tb_fp32_mac_array;

    localparam ASIZE = 2;  // 2×2 array for fast simulation
    localparam PDEPTH = 4;

    reg clk, rst_n;
    reg [ASIZE*32-1:0] act_in;
    reg act_valid, act_sop, act_eop;
    reg weight_load;
    reg [7:0] weight_row, weight_col;
    reg [31:0] weight_data;
    wire [ASIZE*32-1:0] result_out;
    wire result_valid, result_sop, result_eop, busy;

    fp32_mac_array #(.ARRAY_SIZE(ASIZE), .PIPE_DEPTH(PDEPTH)) uut (
        .clk(clk), .rst_n(rst_n),
        .act_in(act_in), .act_valid(act_valid), .act_sop(act_sop), .act_eop(act_eop),
        .weight_load(weight_load), .weight_row(weight_row), .weight_col(weight_col),
        .weight_data(weight_data),
        .result_out(result_out), .result_valid(result_valid),
        .result_sop(result_sop), .result_eop(result_eop), .busy(busy)
    );

    // FP32 constants
    localparam [31:0] FP32_1_0 = 32'h3F800000; // 1.0
    localparam [31:0] FP32_2_0 = 32'h40000000; // 2.0
    localparam [31:0] FP32_3_0 = 32'h40400000; // 3.0
    localparam [31:0] FP32_4_0 = 32'h40800000; // 4.0
    localparam [31:0] FP32_5_0 = 32'h40A00000; // 5.0
    localparam [31:0] FP32_6_0 = 32'h40C00000; // 6.0
    localparam [31:0] FP32_7_0 = 32'h40E00000; // 7.0
    localparam [31:0] FP32_8_0 = 32'h41000000; // 8.0
    localparam [31:0] FP32_10_0 = 32'h41200000; // 10.0
    localparam [31:0] FP32_14_0 = 32'h41600000; // 14.0

    integer errors, pass_count;
    integer timeout_cnt;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_fp32_mac_array.vcd");
        $dumpvars(0, tb_fp32_mac_array);
        errors = 0;
        pass_count = 0;
        rst_n = 0;
        act_in = 0; act_valid = 0; act_sop = 0; act_eop = 0;
        weight_load = 0; weight_row = 0; weight_col = 0; weight_data = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // Load weights: W = [[1,2],[3,4]]
        weight_load = 1;
        weight_row = 0; weight_col = 0; weight_data = FP32_1_0; @(posedge clk);
        weight_row = 0; weight_col = 1; weight_data = FP32_2_0; @(posedge clk);
        weight_row = 1; weight_col = 0; weight_data = FP32_3_0; @(posedge clk);
        weight_row = 1; weight_col = 1; weight_data = FP32_4_0; @(posedge clk);
        weight_load = 0;
        @(posedge clk);

        // Input activations: A = [1,2] (one row)
        // Expected: result = A × W = [1*1+2*3, 1*2+2*4] = [7, 10]
        act_in = {FP32_2_0, FP32_1_0};  // {col1, col0} = {2.0, 1.0}
        act_valid = 1;
        act_sop = 1;
        act_eop = 1;
        @(posedge clk);
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        // Wait for result (ASIZE * PDEPTH + pipeline stages)
        timeout_cnt = 0;
        while (!result_valid && timeout_cnt < 50) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        if (!result_valid) begin
            $display("FAIL: no result_valid within timeout");
            errors = errors + 1;
        end else begin
            // result_out = {col1_result, col0_result} = {10.0, 7.0}
            if (result_out[31:0] !== FP32_7_0) begin
                $display("FAIL: result[0] = %h, expected %h (7.0)", result_out[31:0], FP32_7_0);
                errors = errors + 1;
            end else begin
                pass_count = pass_count + 1;
            end
            if (result_out[63:32] !== FP32_10_0) begin
                $display("FAIL: result[1] = %h, expected %h (10.0)", result_out[63:32], FP32_10_0);
                errors = errors + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end

        $display("*** FP32 MAC ARRAY TEST: %0d passed, %0d errors ***", pass_count, errors);
        if (errors != 0) $finish(1);
        else $finish(0);
    end

endmodule
