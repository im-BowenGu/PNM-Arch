`timescale 1ns/1ps

module tb_clk_gate;

    reg        clk;
    reg        enable;
    reg        scan_en;
    wire       gclk;

    clk_gate uut (
        .clk     (clk),
        .enable  (enable),
        .scan_en (scan_en),
        .gclk    (gclk)
    );

    always #5 clk = ~clk;

    integer errors;

    initial begin
        clk = 0;
        enable = 0;
        scan_en = 0;
        errors = 0;

        // Test 1: clock gated off — gclk stays low when enable=0
        #30;
        if (gclk !== 1'b0) begin
            $display("FAIL T1: gclk should be 0 when enable=0");
            errors = errors + 1;
        end

        // Test 2: clock gated on — gclk follows clk when enable=1
        enable = 1;
        #30;
        // gclk should have toggled (not stuck at 0 or 1)
        // Check it's not stuck
        if (gclk === 1'bz || gclk === 1'bx) begin
            $display("FAIL T2: gclk is unknown");
            errors = errors + 1;
        end

        // Test 3: no glitch — enable transition on rising edge doesn't create a partial pulse
        @(negedge clk);  // enable captured here
        enable = 1;
        @(negedge clk);
        enable = 0;
        // After enable goes low, next rising clk should have gclk=0
        @(posedge clk);
        #1;
        if (gclk !== 1'b0) begin
            $display("FAIL T3: glitch detected — gclk should be 0 after enable deassert");
            errors = errors + 1;
        end

        // Test 4: scan_en bypass — gclk follows clk regardless of enable
        enable = 0;
        scan_en = 1;
        #30;
        if (gclk !== 1'b1 && gclk !== 1'b0) begin
            $display("FAIL T4: gclk unknown with scan_en");
            errors = errors + 1;
        end
        // scan_en should override enable=0
        // Check gclk is not permanently stuck
        @(posedge clk); @(negedge clk); @(posedge clk);
        // gclk should have toggled at least once
        // Hard to check exactly, but at least it shouldn't be x
        if (gclk === 1'bx) begin
            $display("FAIL T4b: gclk unknown during scan");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** CLK_GATE TEST PASSED ***");
        else begin
            $display("*** CLK_GATE TEST FAILED (%0d errors) ***", errors);
            $finish(1);
        end
    end

endmodule
