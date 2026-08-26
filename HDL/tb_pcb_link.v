`timescale 1ns/1ps

// =============================================================================
// tb_pcb_link — PCB interconnect model testbench
//
// Verifies that pcb_link / pcb_triple_link behave as a pure timed wire:
//   T1: single-flit passthrough (DELAY_NS=10), SOP/EOP preserved
//   T2: multi-cycle delay (DELAY_NS=40 -> 4 stages + output reg), exact latency
//   T3: 200-packet stream through a board-trace link, byte-exact ordering
//   T4: triple-link aggregate flit counter
//
// All stimulus is driven and sampled on negedge clk (race-free).
// Expected: *** PCB LINK TEST PASSED ***
// =============================================================================

module tb_pcb_link;

    localparam W = 32;

    reg clk, rst_n;
    always #5 clk = ~clk;

    integer errors;

    // ------------------------------------------------------------------
    // DUT1: short link (spine mezzanine profile)
    // ------------------------------------------------------------------
    reg  [W-1:0] d1_tx_data;
    reg          d1_tx_valid, d1_tx_sop, d1_tx_eop;
    wire         d1_tx_ready;
    wire [W-1:0] d1_rx_data;
    wire         d1_rx_valid, d1_rx_sop, d1_rx_eop;

    pcb_link #(.WIDTH(W), .DELAY_NS(10), .NAME("tb_short")) u_link1 (
        .clk(clk), .rst_n(rst_n),
        .tx_data(d1_tx_data), .tx_valid(d1_tx_valid),
        .tx_sop(d1_tx_sop), .tx_eop(d1_tx_eop), .tx_ready(d1_tx_ready),
        .rx_data(d1_rx_data), .rx_valid(d1_rx_valid),
        .rx_sop(d1_rx_sop), .rx_eop(d1_rx_eop)
    );

    // ------------------------------------------------------------------
    // DUT2: long link (motherboard trace profile)
    // ------------------------------------------------------------------
    reg  [W-1:0] d2_tx_data;
    reg          d2_tx_valid, d2_tx_sop, d2_tx_eop;
    wire         d2_tx_ready;
    wire [W-1:0] d2_rx_data;
    wire         d2_rx_valid, d2_rx_sop, d2_rx_eop;

    pcb_link #(.WIDTH(W), .DELAY_NS(40), .NAME("tb_trace")) u_link4 (
        .clk(clk), .rst_n(rst_n),
        .tx_data(d2_tx_data), .tx_valid(d2_tx_valid),
        .tx_sop(d2_tx_sop), .tx_eop(d2_tx_eop), .tx_ready(d2_tx_ready),
        .rx_data(d2_rx_data), .rx_valid(d2_rx_valid),
        .rx_sop(d2_rx_sop), .rx_eop(d2_rx_eop)
    );

    // ------------------------------------------------------------------
    // DUT3: triple link (X/Y/spine population)
    // ------------------------------------------------------------------
    reg  [W-1:0] t_tx_data;
    reg          t_tx_valid, t_tx_sop, t_tx_eop;
    wire         t_tx_ready;
    wire [W-1:0] t_rx_data;
    wire         t_rx_valid, t_rx_sop, t_rx_eop;
    wire [31:0]  total_flits;

    pcb_triple_link #(.WIDTH(W), .DELAY_NS(20)) u_tri (
        .clk(clk), .rst_n(rst_n),
        .tx0_data(t_tx_data), .tx0_valid(t_tx_valid),
        .tx0_sop(t_tx_sop), .tx0_eop(t_tx_eop), .tx0_ready(t_tx_ready),
        .rx0_data(t_rx_data), .rx0_valid(t_rx_valid),
        .rx0_sop(t_rx_sop), .rx0_eop(t_rx_eop),
        .tx1_data({W{1'b0}}), .tx1_valid(1'b0), .tx1_sop(1'b0), .tx1_eop(1'b0),
        .tx1_ready(), .rx1_data(), .rx1_valid(), .rx1_sop(), .rx1_eop(),
        .tx2_data({W{1'b0}}), .tx2_valid(1'b0), .tx2_sop(1'b0), .tx2_eop(1'b0),
        .tx2_ready(), .rx2_data(), .rx2_valid(), .rx2_sop(), .rx2_eop(),
        .total_flits(total_flits)
    );

    // ------------------------------------------------------------------
    // Scoreboard for DUT1 stream (T3)
    // ------------------------------------------------------------------
    reg [W-1:0] exp_q [0:4095];
    integer     head;
    integer     got_sop, got_eop;
    integer     sent_bytes;
    reg         score_en;

    always @(negedge clk) begin
        if (rst_n && score_en && d1_rx_valid) begin
            if (d1_rx_data !== exp_q[head]) begin
                $display("FAIL: byte %0d got=%08h exp=%08h",
                         head, d1_rx_data, exp_q[head]);
                errors = errors + 1;
            end
            head    = head + 1;
            if (d1_rx_sop) got_sop = got_sop + 1;
            if (d1_rx_eop) got_eop = got_eop + 1;
        end
    end

    // Deterministic LCG stimulus
    integer lcg;
    task step_lcg; begin lcg = lcg * 32'h41C64E6D + 32'h6073; end endtask

    // Drive one packet on DUT1 and record expected bytes
    task send_pkt_d1;
        input [W-1:0] base;
        input integer nbytes;
        integer j;
        begin
            for (j = 0; j < nbytes; j = j + 1) begin
                @(negedge clk);
                d1_tx_valid = 1'b1;
                d1_tx_sop   = (j == 0);
                d1_tx_eop   = (j == nbytes-1);
                d1_tx_data  = base + j;
                exp_q[sent_bytes + j] = base + j;
            end
            sent_bytes = sent_bytes + nbytes;
            @(negedge clk);
            d1_tx_valid = 1'b0; d1_tx_sop = 1'b0; d1_tx_eop = 1'b0;
        end
    endtask

    integer n, len, lat;
    reg [31:0] pay;

    initial begin
        clk = 0; rst_n = 0;
        errors = 0; lcg = 32'h12345678;
        d1_tx_data = 0; d1_tx_valid = 0; d1_tx_sop = 0; d1_tx_eop = 0;
        d2_tx_data = 0; d2_tx_valid = 0; d2_tx_sop = 0; d2_tx_eop = 0;
        t_tx_data  = 0; t_tx_valid  = 0; t_tx_sop  = 0; t_tx_eop  = 0;
        head = 0; got_sop = 0; got_eop = 0; sent_bytes = 0;
        score_en = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        $display("--- T1: single-flit passthrough ---");
        @(negedge clk);
        d1_tx_valid = 1'b1; d1_tx_sop = 1'b1; d1_tx_eop = 1'b1;
        d1_tx_data  = 32'hA5A51234;
        @(negedge clk);
        d1_tx_valid = 1'b0; d1_tx_sop = 1'b0; d1_tx_eop = 1'b0;
        @(negedge clk);
        if (!d1_rx_valid || !d1_rx_sop || !d1_rx_eop ||
            d1_rx_data !== 32'hA5A51234) begin
            $display("FAIL: T1 v=%b s=%b e=%b d=%08h",
                     d1_rx_valid, d1_rx_sop, d1_rx_eop, d1_rx_data);
            errors = errors + 1;
        end else $display("  OK: flit intact (v/s/e/data)");

        $display("--- T2: 40ns trace, exact latency ---");
        @(negedge clk);
        d2_tx_valid = 1'b1; d2_tx_sop = 1'b1; d2_tx_eop = 1'b1;
        d2_tx_data  = 32'hDEAD0040;
        @(negedge clk);
        d2_tx_valid = 1'b0; d2_tx_sop = 1'b0; d2_tx_eop = 1'b0;
        lat = 0;
        while (!d2_rx_valid && lat < 20) begin
            @(negedge clk);
            lat = lat + 1;
        end
        if (!d2_rx_valid || d2_rx_data !== 32'hDEAD0040 || lat != 4) begin
            $display("FAIL: T2 latency=%0d data=%08h valid=%b",
                     lat, d2_rx_data, d2_rx_valid);
            errors = errors + 1;
        end else $display("  OK: 4-stage trace delivered in %0d cycles", lat);

        $display("--- T3: 200-packet stream, byte-exact ---");
        head = 0; got_sop = 0; got_eop = 0;
        score_en = 1;
        for (n = 0; n < 200; n = n + 1) begin
            step_lcg;
            len = (lcg[7:0] % 12) + 1;
            step_lcg;
            pay = lcg ^ (n * 32'h01010101);
            send_pkt_d1(pay, len);
        end
        n = 0;
        while ((head < sent_bytes || got_eop != 200) && n < 5000) begin
            @(negedge clk);
            n = n + 1;
        end
        score_en = 0;
        if (head != sent_bytes || got_sop != 200 || got_eop != 200) begin
            $display("FAIL: T3 bytes %0d/%0d sop=%0d eop=%0d",
                     head, sent_bytes, got_sop, got_eop);
            errors = errors + 1;
        end else $display("  OK: 200 packets, %0d bytes, in order", head);

        $display("--- T4: triple-link flit counter ---");
        for (n = 0; n < 16; n = n + 1) begin
            for (len = 0; len < 3; len = len + 1) begin
                @(negedge clk);
                t_tx_valid = 1'b1;
                t_tx_sop   = (len == 0);
                t_tx_eop   = (len == 2);
                t_tx_data  = 32'hB0000000 + n;
            end
            @(negedge clk);
            t_tx_valid = 1'b0; t_tx_sop = 1'b0; t_tx_eop = 1'b0;
        end
        repeat (8) @(negedge clk);
        if (total_flits != 32'd16) begin
            $display("FAIL: T4 total_flits=%0d", total_flits);
            errors = errors + 1;
        end else $display("  OK: total_flits=%0d", total_flits);

        if (errors == 0)
            $display("*** PCB LINK TEST PASSED ***");
        else
            $display("*** PCB LINK TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
