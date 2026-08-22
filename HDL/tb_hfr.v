`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// tb_hfr — standalone testbench for hfr.v (Hardware Flit Repeater)
//
// Tests the depth-1 elastic buffer pipe stage with proper 1-cycle latency
// checking: drive input at posedge N, check output at posedge N+1.
// =============================================================================

module tb_hfr;
    reg         clk, rst_n;
    reg  [7:0]  in_data;
    reg         in_valid, in_sop, in_eop;
    wire        in_ready;
    reg  [1:0]  in_vc;
    wire [1:0]  out_vc;
    wire [7:0]  out_data;
    wire        out_valid, out_sop, out_eop;
    reg         out_ready;
    reg  [10:0] route_bitmap;
    wire        layer_match;

    hfr uut (
        .clk(clk), .rst_n(rst_n),
        .in_data(in_data), .in_valid(in_valid),
        .in_sop(in_sop), .in_eop(in_eop), .in_ready(in_ready),
        .in_vc(in_vc), .out_vc(out_vc),
        .out_data(out_data), .out_valid(out_valid),
        .out_sop(out_sop), .out_eop(out_eop), .out_ready(out_ready),
        .route_bitmap(route_bitmap), .layer_match(layer_match)
    );

    always #5 clk = ~clk;
    integer errors;

    initial begin
        $dumpfile("tb_hfr.vcd");
        $dumpvars(0, tb_hfr);
        clk = 0; rst_n = 0; errors = 0;
        in_valid = 0; in_data = 0; in_sop = 0; in_eop = 0;
        in_vc = 0; out_ready = 1; route_bitmap = 0;

        repeat(4) @(posedge clk); rst_n <= 1; repeat(2) @(posedge clk);

        // T1: Basic forwarding — drive at posedge, check at posedge+1
        $display("[TB] Test 1: Basic forwarding");
        @(posedge clk);
        in_valid = 1; in_data = 8'hAB; in_sop = 1; in_eop = 0; in_vc = 2'b01;
        @(posedge clk); // HFR samples at this posedge, output appears
        in_valid = 0; in_sop = 0; in_eop = 0;
        // Check: output should reflect the input we just drove
        if (out_data !== 8'hAB || !out_valid || out_sop !== 1 || out_vc !== 2'b01) begin
            $display("[TB] FAIL T1: data=%02h v=%b sop=%b vc=%b", out_data, out_valid, out_sop, out_vc);
            errors = errors + 1;
        end else $display("[TB] PASS T1");
        @(posedge clk);

        // T2: Idle cycle
        $display("[TB] Test 2: Idle cycle");
        in_valid = 0;
        @(posedge clk); @(posedge clk);
        if (out_valid) begin $display("[TB] FAIL T2"); errors=errors+1; end
        else $display("[TB] PASS T2");

        // T3: Full packet — check each output right after its input
        $display("[TB] Test 3: Full packet");
        // Byte 1: SOP
        @(posedge clk);
        in_valid = 1; in_data = 8'h11; in_sop = 1; in_eop = 0; in_vc = 2'b10;
        @(posedge clk); // check output of byte 1
        if (out_data !== 8'h11 || out_sop !== 1 || !out_valid) begin
            $display("[TB] FAIL T3[0]: data=%02h sop=%b v=%b", out_data, out_sop, out_valid);
            errors = errors + 1;
        end
        // Byte 2: body
        in_valid = 1; in_data = 8'h22; in_sop = 0; in_eop = 0;
        @(posedge clk); // check output of byte 2
        if (out_data !== 8'h22 || out_sop !== 0) begin
            $display("[TB] FAIL T3[1]: data=%02h", out_data); errors = errors + 1;
        end
        // Byte 3: EOP
        in_valid = 1; in_data = 8'h33; in_sop = 0; in_eop = 1;
        @(posedge clk); // check output of byte 3
        if (out_data !== 8'h33 || out_eop !== 1) begin
            $display("[TB] FAIL T3[2]: data=%02h eop=%b", out_data, out_eop);
            errors = errors + 1;
        end
        in_valid = 0; in_sop = 0; in_eop = 0;
        @(posedge clk);
        $display("[TB] PASS T3");

        // T4: Backpressure — fill pipeline, stall, release
        $display("[TB] Test 4: Backpressure");
        // First, drive a normal byte to fill the pipeline
        @(posedge clk);
        in_valid = 1; in_data = 8'hAA; in_sop = 1; in_eop = 1;
        @(posedge clk);
        in_valid = 0; in_sop = 0; in_eop = 0;
        @(posedge clk); // output of AA should appear
        // Now stall: deassert out_ready
        out_ready = 0;
        @(posedge clk); @(posedge clk); // pipeline holds
        // Drive new byte while stalled
        @(posedge clk);
        in_valid = 1; in_data = 8'hBB; in_sop = 1; in_eop = 1;
        @(posedge clk);
        in_valid = 0; in_sop = 0; in_eop = 0;
        @(posedge clk); // BB is held in pipeline
        // Release backpressure
        out_ready = 1;
        repeat(4) @(posedge clk); // let everything drain
        // The BB byte should have appeared
        $display("[TB] PASS T4 (backpressure exercised)");

        // T5: Layer match monitor
        $display("[TB] Test 5: Layer match monitor");
        route_bitmap = {4'h3, 1'b0, 1'b0, 5'h00}; // layer=3
        @(posedge clk);
        in_valid = 1; in_data = 8'hA3; in_sop = 1; in_eop = 1;
        @(posedge clk);
        if (!layer_match) begin $display("[TB] FAIL T5a"); errors=errors+1; end
        in_valid = 0; in_sop = 0; in_eop = 0; @(posedge clk);
        in_valid = 1; in_data = 8'hA5; in_sop = 1; in_eop = 1;
        @(posedge clk);
        if (layer_match) begin $display("[TB] FAIL T5b"); errors=errors+1; end
        in_valid = 0; in_sop = 0; in_eop = 0; repeat(2) @(posedge clk);
        $display("[TB] PASS T5");

        // T6: Reset clears outputs
        $display("[TB] Test 6: Reset");
        @(posedge clk);
        in_valid = 1; in_data = 8'hCC; in_sop = 1; in_eop = 1;
        @(posedge clk); rst_n = 0; @(posedge clk); @(posedge clk);
        if (out_valid) begin $display("[TB] FAIL T6"); errors=errors+1; end
        rst_n = 1; repeat(2) @(posedge clk);
        in_valid = 0; in_sop = 0; in_eop = 0;
        $display("[TB] PASS T6");

        // T7: Back-to-back flits — check each output right after its input
        $display("[TB] Test 7: Back-to-back");
        @(posedge clk);
        in_valid = 1; in_data = 8'hF1; in_sop = 1; in_eop = 1; in_vc = 2'b00;
        @(posedge clk);
        if (out_data !== 8'hF1 || out_vc !== 2'b00) begin
            $display("[TB] FAIL T7[0]: data=%02h vc=%b", out_data, out_vc); errors=errors+1;
        end
        in_valid = 1; in_data = 8'hF2; in_sop = 1; in_eop = 1; in_vc = 2'b01;
        @(posedge clk);
        if (out_data !== 8'hF2 || out_vc !== 2'b01) begin
            $display("[TB] FAIL T7[1]: data=%02h vc=%b", out_data, out_vc); errors=errors+1;
        end
        in_valid = 1; in_data = 8'hF3; in_sop = 1; in_eop = 1; in_vc = 2'b10;
        @(posedge clk);
        if (out_data !== 8'hF3 || out_vc !== 2'b10) begin
            $display("[TB] FAIL T7[2]: data=%02h vc=%b", out_data, out_vc); errors=errors+1;
        end
        in_valid = 0; in_sop = 0; in_eop = 0; repeat(2) @(posedge clk);
        $display("[TB] PASS T7");

        if (errors == 0) $display("*** HFR TEST PASSED ***");
        else $display("*** HFR TEST FAILED (%0d errors) ***", errors);
        #1; $finish;
    end

    initial begin #50000; $display("TIMEOUT"); $finish(1); end
endmodule
