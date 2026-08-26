`timescale 1ns/1ps

module tb_rst_sync;

    reg        clk;
    reg        rst_n_async;
    wire       rst_n_sync;

    rst_sync #(.STAGES(2)) uut (
        .clk        (clk),
        .rst_n_async(rst_n_async),
        .rst_n_sync (rst_n_sync)
    );

    always #5 clk = ~clk;

    integer errors;

    initial begin
        clk = 0;
        rst_n_async = 0;
        errors = 0;

        // Test 1: async assert — output stays low while reset is active
        #20;
        if (rst_n_sync !== 1'b0) begin
            $display("FAIL T1: rst_n_sync should be 0 during async reset");
            errors = errors + 1;
        end

        // Test 2: sync deassert — output goes high exactly STAGES cycles after release
        @(negedge clk);
        rst_n_async = 1;
        // After 1 stage: sr[0]=1, sr[1]=0 -> output 0
        @(posedge clk);
        #1;
        if (rst_n_sync !== 1'b0) begin
            $display("FAIL T2a: rst_n_sync should still be 0 after 1 stage");
            errors = errors + 1;
        end
        // After 2 stages: sr[1]=1 -> output 1
        @(posedge clk);
        #1;
        if (rst_n_sync !== 1'b1) begin
            $display("FAIL T2b: rst_n_sync should be 1 after 2 stages");
            errors = errors + 1;
        end

        // Test 3: async assert again — output drops immediately
        #10;
        rst_n_async = 0;
        #1;
        if (rst_n_sync !== 1'b0) begin
            $display("FAIL T3: rst_n_sync should drop immediately on async assert");
            errors = errors + 1;
        end

        // Test 4: re-release — output recovers after 2 cycles
        @(negedge clk);
        rst_n_async = 1;
        @(posedge clk); @(posedge clk);
        #1;
        if (rst_n_sync !== 1'b1) begin
            $display("FAIL T4: rst_n_sync should recover after 2 cycles");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** RST_SYNC TEST PASSED ***");
        else begin
            $display("*** RST_SYNC TEST FAILED (%0d errors) ***", errors);
            $finish(1);
        end
    end

endmodule
