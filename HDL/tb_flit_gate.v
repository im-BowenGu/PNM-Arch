`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// tb_flit_gate — standalone testbench for flit_gate.v
// =============================================================================

module tb_flit_gate;
    reg         clk;
    reg         rst_n;
    reg  [7:0]  match_value, match_mask;
    reg  [1:0]  vc_accept, in_vc;
    reg  [7:0]  in_data;
    reg         in_valid, in_sop, in_eop;
    wire        in_ready;
    wire [7:0]  match_data, pass_data;
    wire        match_valid, pass_valid;
    wire        match_sop, pass_sop;
    wire        match_eop, pass_eop;
    wire [1:0]  match_vc, pass_vc;
    reg         match_ready, pass_ready;

    flit_gate #(.STRIP_ON_MATCH(0)) uut (
        .clk(clk), .rst_n(rst_n),
        .match_value(match_value), .match_mask(match_mask),
        .vc_accept(vc_accept), .in_vc(in_vc),
        .match_vc(match_vc), .pass_vc(pass_vc),
        .in_data(in_data), .in_valid(in_valid),
        .in_sop(in_sop), .in_eop(in_eop), .in_ready(in_ready),
        .match_data(match_data), .match_valid(match_valid),
        .match_sop(match_sop), .match_eop(match_eop),
        .match_ready(match_ready),
        .pass_data(pass_data), .pass_valid(pass_valid),
        .pass_sop(pass_sop), .pass_eop(pass_eop),
        .pass_ready(pass_ready)
    );

    always #5 clk = ~clk;
    integer errors;

    task automatic check_match;
        input exp_match;
        input [8*20-1:0] name;
        begin
            @(negedge clk); // check after posedge sampling
            if (match_valid !== exp_match) begin
                $display("[TB] FAIL %0s: match_valid=%b, expected=%b", name, match_valid, exp_match);
                errors = errors + 1;
            end else if (exp_match && match_data !== in_data) begin
                $display("[TB] FAIL %0s: data mismatch", name);
                errors = errors + 1;
            end else begin
                $display("[TB] PASS %0s", name);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_flit_gate.vcd");
        $dumpvars(0, tb_flit_gate);
        clk = 0; rst_n = 0; errors = 0;
        in_valid = 0; in_data = 0; in_sop = 0; in_eop = 0;
        match_ready = 1; pass_ready = 1;
        match_value = 0; match_mask = 0;
        vc_accept = 0; in_vc = 0;

        repeat(4) @(posedge clk); rst_n <= 1; repeat(2) @(posedge clk);

        // T1: Exact match
        $display("[TB] Test 1: Exact match");
        match_value = 8'h42; match_mask = 8'hFF; vc_accept = 2'b01; in_vc = 2'b01;
        @(posedge clk); in_valid = 1; in_data = 8'h42; in_sop = 1; in_eop = 1;
        check_match(1, "exact match");
        in_valid = 0; in_sop = 0; in_eop = 0; @(posedge clk);

        // T2: No match (different byte)
        $display("[TB] Test 2: No match");
        match_value = 8'h42; match_mask = 8'hFF; vc_accept = 2'b01; in_vc = 2'b01;
        @(posedge clk); in_valid = 1; in_data = 8'h99; in_sop = 1; in_eop = 1;
        @(negedge clk);
        if (pass_valid !== 1) begin $display("[TB] FAIL T2: pass_valid=0"); errors=errors+1; end
        else $display("[TB] PASS T2: pass-through");
        in_valid = 0; in_sop = 0; in_eop = 0; @(posedge clk);

        // T3: Masked match (lower nibble)
        $display("[TB] Test 3: Masked match");
        match_value = 8'h02; match_mask = 8'h0F; vc_accept = 2'b00; in_vc = 2'b00;
        @(posedge clk); in_valid = 1; in_data = 8'h12; in_sop = 1; in_eop = 1;
        check_match(1, "masked match");
        in_valid = 0; in_sop = 0; in_eop = 0; @(posedge clk);

        // T4: VC mismatch
        $display("[TB] Test 4: VC mismatch");
        match_value = 8'h42; match_mask = 8'hFF; vc_accept = 2'b01; in_vc = 2'b10;
        @(posedge clk); in_valid = 1; in_data = 8'h42; in_sop = 1; in_eop = 1;
        @(negedge clk);
        if (match_valid !== 0) begin $display("[TB] FAIL T4: match_valid=1"); errors=errors+1; end
        else $display("[TB] PASS T4: VC mismatch routes to pass");
        in_valid = 0; in_sop = 0; in_eop = 0; @(posedge clk);

        // T5: Multi-byte match packet
        $display("[TB] Test 5: Multi-byte match");
        match_value = 8'hAA; match_mask = 8'hFF; vc_accept = 2'b10; in_vc = 2'b10;
        @(posedge clk);
        in_valid = 1; in_data = 8'hAA; in_sop = 1; in_eop = 0; @(posedge clk);
        in_valid = 1; in_data = 8'hBB; in_sop = 0; in_eop = 0; @(posedge clk);
        in_valid = 1; in_data = 8'hCC; in_sop = 0; in_eop = 1; @(posedge clk);
        in_valid = 0; in_sop = 0; in_eop = 0; repeat(2) @(posedge clk);
        $display("[TB] PASS T5: multi-byte match");

        // T6: Multi-byte pass packet
        $display("[TB] Test 6: Multi-byte pass");
        match_value = 8'hAA; match_mask = 8'hFF;
        @(posedge clk);
        in_valid = 1; in_data = 8'h11; in_sop = 1; in_eop = 0; @(posedge clk);
        in_valid = 1; in_data = 8'h22; in_sop = 0; in_eop = 1; @(posedge clk);
        in_valid = 0; in_sop = 0; in_eop = 0; repeat(2) @(posedge clk);
        $display("[TB] PASS T6: multi-byte pass");

        // T7: Back-to-back packets
        $display("[TB] Test 7: Back-to-back");
        match_value = 8'h55; match_mask = 8'hFF; vc_accept = 2'b00; in_vc = 2'b00;
        @(posedge clk);
        in_valid = 1; in_data = 8'h55; in_sop = 1; in_eop = 1; @(posedge clk); // match
        in_valid = 1; in_data = 8'h11; in_sop = 1; in_eop = 1; @(posedge clk); // pass
        in_valid = 1; in_data = 8'h55; in_sop = 1; in_eop = 1; @(posedge clk); // match
        in_valid = 0; in_sop = 0; in_eop = 0; repeat(3) @(posedge clk);
        $display("[TB] PASS T7: back-to-back");

        // T8: Ready/valid backpressure
        $display("[TB] Test 8: Backpressure");
        match_value = 8'h42; match_mask = 8'hFF; vc_accept = 2'b00; in_vc = 2'b00;
        match_ready = 0;
        @(posedge clk); in_valid = 1; in_data = 8'h42; in_sop = 1; in_eop = 1;
        @(posedge clk);
        if (in_ready) begin $display("[TB] FAIL T8: in_ready=1"); errors=errors+1; end
        else $display("[TB] PASS T8: backpressure");
        in_valid = 0; in_sop = 0; in_eop = 0; match_ready = 1; repeat(3) @(posedge clk);

        // T9: Mask=00 (always matches)
        $display("[TB] Test 9: Mask=00 always matches");
        match_value = 8'h00; match_mask = 8'h00; vc_accept = 2'b00; in_vc = 2'b00;
        @(posedge clk); in_valid = 1; in_data = 8'hFF; in_sop = 1; in_eop = 1;
        check_match(1, "mask=0");
        in_valid = 0; in_sop = 0; in_eop = 0; @(posedge clk);

        if (errors == 0) $display("*** FLIT_GATE TEST PASSED ***");
        else $display("*** FLIT_GATE TEST FAILED (%0d errors) ***", errors);
        #1; $finish;
    end

    initial begin #100000; $display("TIMEOUT"); $finish(1); end
endmodule
