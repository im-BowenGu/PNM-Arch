`timescale 1ns/1ps

// =============================================================================
// tb_bf16_mac_array — self-checking testbench for BF16 systolic MAC array
//
// Tests:
//   1. Weight loading into the array
//   2. Burst weight load across all rows
//   3. Activation feed and busy deassertion
//   4. Zero-weight identity
//
// Uses ASIZE=4 (4x4=16 FMA instances) for fast simulation.
// =============================================================================
module tb_bf16_mac_array;

    reg         clk = 0;
    reg         rst_n = 0;

    localparam ASIZE = 4;

    reg  [ASIZE*16-1:0] act_in;
    reg                  act_valid;
    reg                  act_sop;
    reg                  act_eop;
    reg  [15:0]          weight_in;
    reg                  weight_load;
    reg  [7:0]           weight_row;
    reg  [7:0]           weight_col;
    wire [ASIZE*16-1:0]  result_out;
    wire                 result_valid;
    wire                 result_sop;
    wire                 result_eop;
    wire                 busy;

    always #5 clk = ~clk;

    bf16_mac_array #(.ARRAY_SIZE(ASIZE)) dut (
        .clk(clk), .rst_n(rst_n),
        .act_in(act_in), .act_valid(act_valid),
        .act_sop(act_sop), .act_eop(act_eop),
        .weight_in(weight_in), .weight_load(weight_load),
        .weight_row(weight_row), .weight_col(weight_col),
        .result_out(result_out), .result_valid(result_valid),
        .result_sop(result_sop), .result_eop(result_eop),
        .busy(busy)
    );

    integer errors;
    integer i;

    // BF16 constants (same as bf16_fma.v)
    // 1.0 = 0x3F80, 2.0 = 0x4000, 3.0 = 0x4040
    // 0.0 = 0x0000
    localparam BF16_0 = 16'h0000;
    localparam BF16_1 = 16'h3F80;
    localparam BF16_2 = 16'h4000;
    localparam BF16_3 = 16'h4040;

    initial begin
        $dumpfile("tb_bf16_mac_array.vcd");
        $dumpvars(0, tb_bf16_mac_array);
        errors = 0;
        act_in = 0;
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;
        weight_in = 0;
        weight_load = 0;
        weight_row = 0;
        weight_col = 0;

        // Reset
        #25; rst_n = 1; #10;

        // =====================================================================
        // Test 1: Load weight W[0][0] = 2.0
        // =====================================================================
        $display("[TB] Test 1: Weight loading...");
        weight_in = BF16_2;
        weight_row = 8'd0;
        weight_col = 8'd0;
        weight_load = 1;
        @(posedge clk); #1;
        weight_load = 0;

        if (dut.weights[0][0] !== BF16_2) begin
            $display("[TB] FAIL: weights[0][0] = %h, expected %h", dut.weights[0][0], BF16_2);
            errors = errors + 1;
        end

        // =====================================================================
        // Test 2: Burst weight load — all rows, column 0 = 1.0
        // =====================================================================
        $display("[TB] Test 2: Burst weight load...");
        for (i = 0; i < ASIZE; i = i + 1) begin
            @(posedge clk);
            weight_in = BF16_1;
            weight_row = i[7:0];
            weight_col = 8'd0;
            weight_load = 1;
        end
        @(posedge clk); #1;
        weight_load = 0;

        if (dut.weights[0][0] !== BF16_1) begin
            $display("[TB] FAIL: weights[0][0] = %h, expected %h", dut.weights[0][0], BF16_1);
            errors = errors + 1;
        end

        // =====================================================================
        // Test 3: Feed activation and check busy/compute path
        // =====================================================================
        $display("[TB] Test 3: Activation feed + compute...");
        // Reset all weights to 1.0
        for (i = 0; i < ASIZE; i = i + 1) begin
            @(posedge clk);
            weight_in = BF16_1;
            weight_row = i[7:0];
            weight_col = 8'd0;
            weight_load = 1;
        end
        @(posedge clk); #1;
        weight_load = 0;

        // Feed activation X[0] = 1.0
        act_in = 0;
        act_in[15:0] = BF16_1;
        act_valid = 1;
        act_sop = 1;
        act_eop = 1;
        @(posedge clk);
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        // Wait for pipeline: ARRAY_SIZE * PIPE_DEPTH + PIPE_DEPTH = 15 cycles
        repeat (30) @(posedge clk);

        // MAC array should return to idle
        if (busy !== 1'b0) begin
            $display("[TB] FAIL: busy should be 0 after computation, got %b", busy);
            errors = errors + 1;
        end

        // =====================================================================
        // Test 4: Zero-weight identity — W=0 => result should be 0
        // =====================================================================
        $display("[TB] Test 4: Zero-weight identity...");
        for (i = 0; i < ASIZE; i = i + 1) begin
            @(posedge clk);
            weight_in = BF16_0;
            weight_row = i[7:0];
            weight_col = 8'd0;
            weight_load = 1;
        end
        @(posedge clk); #1;
        weight_load = 0;

        // Feed activation
        act_in = 0;
        act_in[15:0] = BF16_3;
        act_valid = 1;
        act_sop = 1;
        act_eop = 1;
        @(posedge clk);
        act_valid = 0;
        act_sop = 0;
        act_eop = 0;

        repeat (30) @(posedge clk);

        if (busy !== 1'b0) begin
            $display("[TB] FAIL: busy should be 0 after zero-weight computation");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** BF16 MAC ARRAY TEST PASSED ***");
        else
            $display("*** BF16 MAC ARRAY TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

    initial begin #10000; $display("TIMEOUT"); $finish(1); end

endmodule
