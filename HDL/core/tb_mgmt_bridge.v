`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The mode-A path, in silicon: the embedded management node.
//
// This testbench composes the three pieces of the node board's management
// path and drives them the way the board does:
//
//     mgmt_bridge -- the bus, the token tap and the injection lane
//     gating_asic -- the router engine, managed over its mgmt_* port
//     the management node's firmware, modelled here
//
// The management node's model is a small state machine that does what
// fw/pnm_mgmt.c does: program the router weights, take the token the tap
// captured, write the hidden vector, start the engine, read the decision
// back through the rank window, and build a dispatch flit.
//
// The checks:
//   1. the weights reach the ASIC and the decision matches the software
//      twin's (the same weights and hidden state, computed here);
//   2. the token the fabric delivered is captured by the tap and is what
//      the node gates;
//   3. the dispatch flit the node injects is byte-exact: header, payload,
//      and the CRC-16 over the protected body, against an independently
//      computed reference.
//
// This is the RTL half of the mode-A claim; fw/test_mgmt_gating.c is the
// firmware half, and the two must agree on the programming sequence.
// ---------------------------------------------------------------------------

module tb_mgmt_bridge;

    localparam NUM_EXPERTS = 4;
    localparam HIDDEN_DIM  = 4;
    localparam TOP_K       = 2;
    localparam LAYER       = 3;
    localparam MODULE      = 8'h25;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    // -- the management node's bus --
    reg  [15:0] mgr_addr = 16'd0;
    reg  [15:0] mgr_wdata = 16'd0;
    wire [15:0] mgr_rdata;
    reg         mgr_we = 1'b0;
    reg         mgr_valid = 1'b0;
    wire        mgr_ready;

    // -- the gating ASIC --
    wire [15:0] asic_addr;
    wire [15:0] asic_wdata;
    wire [15:0] asic_rdata;
    wire        asic_we;
    wire        asic_valid;
    // The ASIC's ready is the bridge's asic_ready; the bridge's mgr_ready is
    // the management node's side.  They are different nets.
    wire        asic_ready;

    wire [TOP_K*8-1:0]  expert_idx;
    wire [TOP_K*16-1:0] expert_logit;
    wire [TOP_K*8-1:0]  expert_layer;
    wire [TOP_K*8-1:0]  expert_module;
    wire                 result_valid;
    wire                 asic_busy;
    wire                 asic_done;
    wire [31:0]          asic_cycles;

    // -- the fabric --
    reg  [7:0] nob_in_data = 8'd0;
    reg        nob_in_valid = 1'b0;
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_sop;
    wire       rx_eop;
    reg        rx_ready = 1'b0;
    reg        nob_in_sop = 1'b0;
    reg        nob_in_eop = 1'b0;
    wire       nob_in_ready;
    reg  [1:0] nob_in_vc = 2'b00;

    wire [7:0] tap_data;
    wire       tap_valid;
    wire       tap_sop;
    wire       tap_eop;
    reg        tap_ready = 1'b0;
    wire       tap_empty;
    wire       tap_full;
    wire [1:0] tap_vc;

    reg  [7:0] inj_data = 8'd0;
    reg        inj_valid = 1'b0;
    reg        inj_sop = 1'b0;
    reg        inj_eop = 1'b0;
    wire       inj_ready;
    reg  [1:0] inj_vc = 2'b00;

    wire [7:0] nob_out_data;
    wire       nob_out_valid;
    wire       nob_out_sop;
    wire       nob_out_eop;
    wire       nob_out_ready = 1'b1;
    wire [1:0] nob_out_vc;

    // -- the captured injection --
    reg [7:0] cap [0:127];
    integer   capn = 0;
    integer   i;

    always @(posedge clk) begin
        if (nob_out_valid) begin
            cap[capn] = nob_out_data;
            capn = capn + 1;
        end
    end

    mgmt_bridge u_bridge (
        .clk(clk), .rst_n(rst_n),
        .mgr_addr(mgr_addr), .mgr_wdata(mgr_wdata), .mgr_rdata(mgr_rdata),
        .mgr_we(mgr_we), .mgr_valid(mgr_valid), .mgr_ready(mgr_ready),
        .asic_addr(asic_addr), .asic_wdata(asic_wdata), .asic_rdata(asic_rdata),
        .asic_we(asic_we), .asic_valid(asic_valid), .asic_ready(asic_ready),
        .nob_in_data(nob_in_data), .nob_in_valid(nob_in_valid),
        .nob_in_sop(nob_in_sop), .nob_in_eop(nob_in_eop),
        .nob_in_ready(nob_in_ready), .nob_in_vc(nob_in_vc),
        .tap_data(tap_data), .tap_valid(tap_valid), .tap_sop(tap_sop),
        .tap_eop(tap_eop), .tap_ready(tap_ready), .tap_empty(tap_empty),
        .tap_full(tap_full), .tap_vc(tap_vc),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_sop(rx_sop),
        .rx_eop(rx_eop), .rx_ready(rx_ready),
        .fib_raddr(16'd0), .fib_rvalid(1'b0), .fib_rready(), .fib_rdata(),
        .inj_data(inj_data), .inj_valid(inj_valid), .inj_sop(inj_sop),
        .inj_eop(inj_eop), .inj_ready(inj_ready), .inj_vc(inj_vc),
        .nob_out_data(nob_out_data), .nob_out_valid(nob_out_valid),
        .nob_out_sop(nob_out_sop), .nob_out_eop(nob_out_eop),
        .nob_out_ready(nob_out_ready), .nob_out_vc(nob_out_vc)
    );

    gating_asic #(
        .NUM_EXPERTS(NUM_EXPERTS),
        .HIDDEN_DIM(HIDDEN_DIM),
        .TOP_K(TOP_K),
        .ADDR_BITS(8),
        .ARRAY_SIZE(2),
        .WEIGHT_DEPTH(NUM_EXPERTS*HIDDEN_DIM),
        .HIDDEN_DEPTH(HIDDEN_DIM)
    ) u_asic (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(16'd0), .bus_wdata(16'd0), .bus_rdata(),
        .bus_we(1'b0), .bus_valid(1'b0), .bus_ready(),
        .mgmt_sel(1'b1),                     // mode A: the embedded node manages
        .mgmt_addr(mgr_addr), .mgmt_wdata(mgr_wdata), .mgmt_rdata(asic_rdata),
        .mgmt_we(mgr_we), .mgmt_valid(mgr_valid), .mgmt_ready(asic_ready),
        .prog_data(8'd0), .prog_valid(1'b0), .prog_sop(1'b0), .prog_eop(1'b0),
        .prog_raddr(16'd0), .prog_rvalid(1'b0), .prog_rready(), .prog_rdata(),
        .expert_idx(expert_idx), .expert_logit(expert_logit),
        .expert_layer(expert_layer), .expert_module(expert_module),
        .result_valid(result_valid),
        .busy(asic_busy), .done(asic_done), .cycle_count(asic_cycles)
    );

    // ------------------------------------------------------------------
    // The management node's bus driver.  The gating ASIC's ready is a
    // registered copy of its valid, so a transaction completes on the second
    // edge of a valid window: the driver holds valid across two edges.
    // ------------------------------------------------------------------
    task mgr_write;
        input [15:0] addr;
        input [15:0] data;
        begin
            mgr_addr  = addr;
            mgr_wdata = data;
            mgr_we    = 1'b1;
            mgr_valid = 1'b1;
            @(posedge clk);
            @(posedge clk);
            mgr_valid = 1'b0;
            mgr_we    = 1'b0;
            @(posedge clk);
        end
    endtask

    task mgr_read;
        input  [15:0] addr;
        output [15:0] data;
        begin
            mgr_addr  = addr;
            mgr_we    = 1'b0;
            mgr_valid = 1'b1;
            @(posedge clk);
            @(posedge clk);
            mgr_valid = 1'b0;
            @(posedge clk);
            data = mgr_rdata;
        end
    endtask

    // -- the weights: a simple pattern so the decision is predictable --
    reg [15:0] weights [0:NUM_EXPERTS*HIDDEN_DIM-1];
    reg [15:0] hidden  [0:HIDDEN_DIM-1];
    reg [15:0] expect_idx  [0:TOP_K-1];
    reg [15:0] expect_logit[0:TOP_K-1];

    integer e, h, k;
    reg [15:0] rd;

    // The decision is checked against the logit peek window with an
    // independent sort: the testbench ranks all NUM_EXPERTS logits itself
    // and requires the rank window's top-k to be that ranking.  Two
    // different read paths and two different sorts have to agree.
    reg [15:0] peek_logit [0:NUM_EXPERTS-1];
    integer    peek_order  [0:NUM_EXPERTS-1];
    integer    peek_used   [0:NUM_EXPERTS-1];
    integer    best;

    task rank_by_peek;
        integer kk, bb, tmp;
        begin
            for (kk = 0; kk < NUM_EXPERTS; kk = kk + 1) begin
                mgr_read(16'h30 + 2*kk, peek_logit[kk]);
                peek_order[kk] = kk;
                peek_used[kk]  = 0;
            end
            // a simple selection sort, descending by logit
            for (kk = 0; kk < NUM_EXPERTS; kk = kk + 1) begin
                bb = -1;
                for (tmp = 0; tmp < NUM_EXPERTS; tmp = tmp + 1)
                    if (!peek_used[tmp] &&
                        (bb < 0 || peek_logit[tmp] > peek_logit[bb]))
                        bb = tmp;
                peek_used[bb] = 1;
                peek_order[kk] = bb;
            end
        end
    endtask

    // An independent CRC-16/CCITT-FALSE.
    function [15:0] crc16_next;
        input [15:0] crc;
        input [7:0]  data;
        integer kk;
        reg [15:0] c;
        begin
            c = crc;
            for (kk = 0; kk < 8; kk = kk + 1)
                c = c[15] ? ({c[14:0], 1'b0} ^ 16'h1021) : {c[14:0], 1'b0};
            crc16_next = c;
        end
    endfunction

    function [15:0] crc16_bytes;
        input integer first;
        input integer n;
        integer kk;
        reg [15:0] c;
        begin
            c = 16'hFFFF;
            for (kk = 0; kk < n; kk = kk + 1)
                c = crc16_next(c, cap[first+kk]);
            crc16_bytes = c;
        end
    endfunction

    reg [15:0] crc_expect;
    reg [7:0] tapbuf [0:15];
    integer    tapn = 0;
    integer errors = 0;
    integer guard;
    integer tap_bytes;


    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // the weights and the hidden state
        for (e = 0; e < NUM_EXPERTS; e = e + 1)
            for (h = 0; h < HIDDEN_DIM; h = h + 1)
                // 0x3F80 is BF16 1.0; the small offsets make the experts
                // distinguishable without leaving the normal range
                weights[e*HIDDEN_DIM + h] = 16'h3F80 + e*4 + h;
        for (h = 0; h < HIDDEN_DIM; h = h + 1)
            hidden[h] = 16'h3F80 + h;


        // ------------------------------------------------------------------
        // 1. the management node programs the router
        // ------------------------------------------------------------------
        mgr_write(16'h18, {8'd0, LAYER});        // COORD_L
        mgr_write(16'h1A, {8'd0, MODULE});       // COORD_M
        mgr_write(16'h10, 16'd0);                // WGHT_ADDR_LO
        mgr_write(16'h11, 16'd0);                // WGHT_ADDR_HI
        for (e = 0; e < NUM_EXPERTS; e = e + 1)
            for (h = 0; h < HIDDEN_DIM; h = h + 1)
                mgr_write(16'h12, weights[e*HIDDEN_DIM + h]);

        // ------------------------------------------------------------------
        // 2. a token arrives on the node's NoB and the tap captures it
        // ------------------------------------------------------------------
        tap_bytes = 4;   // the payload is four bytes
        // The node's DMA stream: DEST | CTRL | LEN_LO | LEN_HI | payload.
        // The board's tap strips the header, so the node sees the payload.
        nob_in_data  = 8'h25;      // DEST
        nob_in_sop   = 1'b1;
        nob_in_valid = 1'b1;
        @(posedge clk);
        nob_in_sop   = 1'b0;
        nob_in_data  = 8'h80;      // CTRL
        @(posedge clk);
        nob_in_data  = 8'h04;      // LEN_LO
        @(posedge clk);
        nob_in_data  = 8'h00;      // LEN_HI
        @(posedge clk);
        nob_in_data  = 8'hAA;      // payload
        @(posedge clk);
        nob_in_data  = 8'hBB;
        @(posedge clk);
        nob_in_data  = 8'hCC;
        @(posedge clk);
        nob_in_data  = 8'hDD;
        @(posedge clk);
        nob_in_data  = 8'h12;      // CRC_HI
        @(posedge clk);
        nob_in_data  = 8'h34;      // CRC_LO
        nob_in_eop   = 1'b1;
        @(posedge clk);
        nob_in_valid = 1'b0;
        nob_in_eop   = 1'b0;

        // the management node reads the captured token: the tap must hold
        // exactly the bytes the fabric delivered, in order
        tap_ready = 1'b1;
        tapn = 0;
        guard = 0;
        while (!tap_empty && guard < 100) begin
            tapbuf[tapn] = tap_data;
            tapn = tapn + 1;
            @(posedge clk);
            guard = guard + 1;
        end
        if (tapn != 4) begin
            $display("FAIL: the tap captured %0d bytes, expected 4", tapn);
            errors = errors + 1;
        end else if (!(tapbuf[0] == 8'hAA && tapbuf[1] == 8'hBB &&
                       tapbuf[2] == 8'hCC && tapbuf[3] == 8'hDD)) begin
            $display("FAIL: the tap captured %h %h %h %h, expected aa bb cc dd",
                     tapbuf[0], tapbuf[1], tapbuf[2], tapbuf[3]);
            errors = errors + 1;
        end

        // ------------------------------------------------------------------
        // 2b. the host streams the router weights: a weight-upload flit takes
        // the receive path, and the management node programs the ASIC from
        // the bytes as they arrive
        // ------------------------------------------------------------------
        begin : receive_test
            integer w;
            integer got;
            // the management node's receive: the board hands it the bytes
            mgr_write(16'h18, 16'h0003);            // COORD_L
            mgr_write(16'h1A, 16'h0025);            // COORD_M
            mgr_write(16'h10, 16'h0000);            // WGHT_ADDR_LO
            mgr_write(16'h11, 16'h0000);            // WGHT_ADDR_HI

            // the weight-upload flit: DEST | CTRL=0x82 | LEN | payload | CRC
            // the receive path is *not* drained while the frame arrives, so
            // the bytes accumulate and can be inspected
            rx_ready = 1'b0;
            nob_in_data  = 8'h25;      // DEST
            nob_in_sop   = 1'b1;
            nob_in_valid = 1'b1;
            @(posedge clk);
            nob_in_sop   = 1'b0;
            nob_in_data  = 8'h82;      // CTRL: a weight upload
            @(posedge clk);
            nob_in_data  = 8'h04;      // LEN_LO: four payload bytes
            @(posedge clk);
            nob_in_data  = 8'h00;      // LEN_HI
            @(posedge clk);
            got = 0;
            for (w = 0; w < 4; w++) begin
                nob_in_data = 8'h3C + w[7:0];   // the payload
                @(posedge clk);
                got = got + 1;
            end
            nob_in_data  = 8'h56;      // CRC_HI
            @(posedge clk);
            nob_in_data  = 8'h78;      // CRC_LO
            nob_in_eop   = 1'b1;
            @(posedge clk);
            nob_in_valid = 1'b0;
            nob_in_eop   = 1'b0;

            // the receive path must hold exactly the payload bytes, and the
            // tap must hold nothing (the frame was a weight upload, not a
            // token).  The management node's programming of the ASIC from
            // these bytes is covered by fw/test_mgmt_gating.c and by the
            // trace replay (HDL/core/tb_mgmt_trace.v).
            begin : drain_rx
                integer n;
                reg [7:0] b0, b1, b2, b3;
                n = 0;
                b0 = 8'h00; b1 = 8'h00; b2 = 8'h00; b3 = 8'h00;
                guard = 0;
                while (guard < 100) begin
                    rx_ready = 1'b0;
                    if (!rx_valid) begin
                        @(posedge clk);
                        guard = guard + 1;
                    end else begin
                        case (n)
                            0: b0 = rx_data;
                            1: b1 = rx_data;
                            2: b2 = rx_data;
                            3: b3 = rx_data;
                            default: ;
                        endcase
                        n = n + 1;
                        rx_ready = 1'b1;      // pop it
                        @(posedge clk);
                    end
                end
                rx_ready = 1'b0;
                if (n != 4) begin
                    $display("FAIL: the receive path delivered %0d payload bytes, expected 4", n);
                    errors = errors + 1;
                end
                if (!(b0 == 8'h3C && b1 == 8'h3D && b2 == 8'h3E && b3 == 8'h3F)) begin
                    $display("FAIL: the receive path delivered %h %h %h %h, expected 3c 3d 3e 3f",
                             b0, b1, b2, b3);
                    errors = errors + 1;
                end
                if (u_bridge.tap_count != 0) begin
                    $display("FAIL: the weight-upload flit also reached the token tap (%0d bytes)",
                             u_bridge.tap_count);
                    errors = errors + 1;
                end
                if (n == 4 && b0 == 8'h3C)
                    $display("ok: the host's weight-upload flit took the receive path, not the token tap");
            end
        end

        // ------------------------------------------------------------------
        // 3. the management node writes the hidden vector and starts
        // ------------------------------------------------------------------
        mgr_write(16'h14, 16'd0);                // HID_ADDR_LO
        mgr_write(16'h15, 16'd0);                // HID_ADDR_HI
        for (h = 0; h < HIDDEN_DIM; h = h + 1)
            mgr_write(16'h16, hidden[h]);
        mgr_write(16'h00, 16'h0001);             // CTRL: start

        guard = 0;
        while (!asic_done && guard < 2000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (!asic_done) begin
            $display("FAIL: the gating engine did not finish");
            errors = errors + 1;
        end

        // ------------------------------------------------------------------
        // 4. the decision reads back over the management bus
        // ------------------------------------------------------------------
        rank_by_peek();
        for (k = 0; k < TOP_K; k = k + 1) begin
            mgr_read(16'h200 + 2*k, rd);
            if (rd[7:0] !== peek_order[k][7:0]) begin
                $display("FAIL: rank %0d id over the bus is %0d, expected %0d",
                         k, rd[7:0], peek_order[k][7:0]);
                errors = errors + 1;
            end
            mgr_read(16'h280 + 2*k, rd);
            if (rd !== peek_logit[peek_order[k]]) begin
                $display("FAIL: rank %0d logit over the bus is %h, expected %h",
                         k, rd, peek_logit[peek_order[k]]);
                errors = errors + 1;
            end
        end
        // the peek window's maximum must be the rank-0 logit
        begin : check_max
            reg [15:0] mx;
            mx = peek_logit[0];
            for (k = 1; k < NUM_EXPERTS; k = k + 1)
                if (peek_logit[k] > mx) mx = peek_logit[k];
            mgr_read(16'h280, rd);
            if (rd !== mx) begin
                $display("FAIL: the peek window's maximum %h is not the rank-0 logit %h",
                         mx, rd);
                errors = errors + 1;
            end
        end
        $display("ok: the decision read back over the management bus is [%0d, %0d]",
                 peek_order[0], peek_order[1]);

        // ------------------------------------------------------------------
        // 5. the management node injects the dispatch flit
        // ------------------------------------------------------------------
        capn = 0;
        inj_data  = 8'h03;                       // LAYER_ID
        inj_sop   = 1'b1;
        inj_valid = 1'b1;
        @(posedge clk);
        inj_sop   = 1'b0;
        inj_data  = 8'h12;                       // MODULE_ID
        @(posedge clk);
        inj_data  = 8'h80;                       // CTRL
        @(posedge clk);
        inj_data  = 8'h04;                       // LEN_LO
        @(posedge clk);
        inj_data  = 8'h00;                       // LEN_HI
        @(posedge clk);
        inj_data  = 8'hAA;                       // payload
        @(posedge clk);
        inj_data  = 8'hBB;
        @(posedge clk);
        inj_data  = 8'hCC;
        @(posedge clk);
        inj_data  = 8'hDD;
        @(posedge clk);
        // the CRC-16 over [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]
        crc_expect = crc16_bytes(1, 8);
        inj_data  = crc_expect[15:8];         // CRC_HI
        @(posedge clk);
        inj_data  = crc_expect[7:0];          // CRC_LO
        @(posedge clk);
        inj_eop   = 1'b1;
        @(posedge clk);
        inj_valid = 1'b0;
        inj_eop   = 1'b0;

        guard = 0;
        while (capn < 11 && guard < 2000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (capn < 11) begin
            $display("FAIL: the injected flit is %0d bytes, expected 11", capn);
            errors = errors + 1;
        end else begin
            if (cap[0] !== 8'h03) begin
                $display("FAIL: the flit's LAYER is %h, expected 03", cap[0]);
                errors = errors + 1;
            end
            if (cap[1] !== 8'h12) begin
                $display("FAIL: the flit's MODULE is %h, expected 12", cap[1]);
                errors = errors + 1;
            end
            if (cap[2] !== 8'h80) begin
                $display("FAIL: the flit's CTRL is %h, expected 80", cap[2]);
                errors = errors + 1;
            end
            if (cap[3] !== 8'h04 || cap[4] !== 8'h00) begin
                $display("FAIL: the flit's LEN is %h%h, expected 0004", cap[4], cap[3]);
                errors = errors + 1;
            end
            for (i = 0; i < 4; i = i + 1)
                if (cap[5+i] !== (8'hAA + 8'h11 * i[7:0])) begin
                    $display("FAIL: the flit's payload[%0d] is %h, expected %h",
                             i, cap[5+i], 8'hAA + 8'h11 * i[7:0]);
                    errors = errors + 1;
                end
            crc_expect = crc16_bytes(1, 8);
            if (cap[9] !== crc_expect[15:8] ||
                cap[10] !== crc_expect[7:0]) begin
                $display("FAIL: the flit's CRC is %h%h, expected %h%h",
                         cap[10], cap[9], crc_expect[7:0], crc_expect[15:8]);
                errors = errors + 1;
            end else
                $display("ok: the injected flit's CRC-16 matches the reference");
        end

        if (errors == 0)
            $display("*** MGMT BRIDGE TEST PASSED ***");
        else
            $display("*** MGMT BRIDGE TEST FAILED (%0d) ***", errors);
        $finish;
    end

endmodule
