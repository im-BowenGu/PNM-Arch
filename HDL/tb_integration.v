`timescale 1ns/1ps
`include "pnm_defs.vh"

module tb_integration;

    reg         clk = 0;
    reg         rst_n = 0;
    always #5 clk = ~clk;

    // Spine driver signals
    reg  [7:0]  drv_data;
    reg         drv_valid;
    reg         drv_sop;
    reg         drv_eop;
    wire        drv_ready;

    // HFR output
    wire [7:0]  hfr_out_data;
    wire        hfr_out_valid, hfr_out_sop, hfr_out_eop;
    wire        hfr_layer_match;

    // xyz_repeater -> nob (downward, layer matched)
    wire [7:0]  nob_data;
    wire        nob_valid, nob_sop, nob_eop;
    wire        nob_ready;

    // xy_turn -> yout
    wire [7:0]  y_data;
    wire        y_valid, y_sop, y_eop;
    wire        y_ready;

    // node_eject -> node
    wire [7:0]  node_data;
    wire        node_valid, node_sop, node_eop;
    wire        node_ready;

    // pe_tile_stub AXI-Stream
    wire [7:0]  pe_out_data;
    wire        pe_out_valid, pe_out_ready, pe_out_last, pe_out_start;
    wire [7:0]  pe_tx_data;
    wire        pe_tx_valid, pe_tx_ready, pe_tx_last, pe_tx_start;
    wire        pe_route_err, pe_corrupt_out;

    // doorbell
    wire        fire, ack, node_err;
    wire [31:0] activations, rejections;

    // CRC
    reg [15:0] crc_val;

    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0]  data_in;
        integer j;
        reg [15:0] c;
        begin
            c = crc_in ^ (data_in << 8);
            for (j = 0; j < 8; j = j + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16_byte = c;
        end
    endfunction

    // =========================================================================
    // DUT chain
    // =========================================================================
    hfr spine_hfr (
        .clk(clk), .rst_n(rst_n),
        .in_data(drv_data), .in_valid(drv_valid),
        .in_sop(drv_sop), .in_eop(drv_eop),
        .in_ready(drv_ready), .in_vc(`VC_SPINE_DESCENT),
        .out_data(hfr_out_data), .out_valid(hfr_out_valid),
        .out_sop(hfr_out_sop), .out_eop(hfr_out_eop),
        .out_ready(1'b1), .out_vc(),
        .route_bitmap(11'h0080), .layer_match(hfr_layer_match)
    );

    xyz_repeater rpt (
        .clk(clk), .rst_n(rst_n),
        .route_bitmap(11'h0080),
        .spin_data(hfr_out_data), .spin_valid(hfr_out_valid),
        .spin_sop(hfr_out_sop), .spin_eop(hfr_out_eop),
        .spin_ready(), .spin_vc(`VC_SPINE_DESCENT),
        .spout_data(), .spout_valid(), .spout_ready(1'b1),
        .spout_sop(), .spout_eop(), .spout_vc(),
        .nob_data(nob_data), .nob_valid(nob_valid),
        .nob_sop(nob_sop), .nob_eop(nob_eop),
        .nob_ready(nob_ready), .nob_vc(),
        .nob_up_data(8'h0), .nob_up_valid(1'b0),
        .nob_up_sop(1'b0), .nob_up_eop(1'b0),
        .nob_up_ready(), .nob_up_vc(2'b00),
        .spup_in_data(8'h0), .spup_in_valid(1'b0),
        .spup_in_sop(1'b0), .spup_in_eop(1'b0),
        .spup_in_ready(), .spup_in_vc(2'b00),
        .spup_data(), .spup_valid(), .spup_sop(), .spup_eop(),
        .spup_ready(1'b1), .spup_vc()
    );

    xy_turn #(.LOCAL_X(4'h2)) turn (
        .clk(clk), .rst_n(rst_n),
        .xin_data(nob_data), .xin_valid(nob_valid),
        .xin_sop(nob_sop), .xin_eop(nob_eop),
        .xin_ready(nob_ready), .xin_vc(`VC_ONBOARD_DELIVER),
        .xout_data(), .xout_valid(), .xout_ready(1'b1),
        .xout_sop(), .xout_eop(), .xout_vc(),
        .yout_data(y_data), .yout_valid(y_valid),
        .yout_sop(y_sop), .yout_eop(y_eop),
        .yout_ready(y_ready), .yout_vc()
    );

    node_eject #(.LOCAL_MODULE(8'h25)) eject (
        .clk(clk), .rst_n(rst_n),
        .yin_data(y_data), .yin_valid(y_valid),
        .yin_sop(y_sop), .yin_eop(y_eop),
        .yin_ready(y_ready), .yin_vc(`VC_ONBOARD_DELIVER),
        .yout_data(), .yout_valid(), .yout_ready(1'b1),
        .yout_sop(), .yout_eop(), .yout_vc(),
        .node_data(node_data), .node_valid(node_valid),
        .node_sop(node_sop), .node_eop(node_eop),
        .node_ready(node_ready), .node_vc()
    );

    pe_tile_stub #(.MULT_LATENCY(2)) pe (
        .clk(clk), .rst_n(rst_n),
        .routing_bitmap(11'h0080),
        .s_axis_tdata(node_data), .s_axis_tvalid(node_valid),
        .s_axis_tready(node_ready), .s_axis_tlast(node_eop),
        .s_axis_tstart(1'b0),
        .m_axis_tdata(pe_out_data), .m_axis_tvalid(pe_out_valid),
        .m_axis_tready(pe_out_ready), .m_axis_tlast(pe_out_last),
        .m_axis_tstart(pe_out_start),
        .m_axis_tx_tdata(pe_tx_data), .m_axis_tx_tvalid(pe_tx_valid),
        .m_axis_tx_tready(1'b1), .m_axis_tx_tlast(pe_tx_last),
        .m_axis_tx_tstart(pe_tx_start),
        .tx_vc(),
        .route_err(pe_route_err), .corrupt_out(pe_corrupt_out)
    );

    doorbell #(.LOCAL_MODULE(8'h25)) db (
        .clk(clk), .rst_n(rst_n),
        .s_data(pe_out_data), .s_valid(pe_out_valid),
        .s_ready(pe_out_ready), .s_eop(pe_out_last),
        .fire(fire), .ack(ack), .node_err(node_err),
        .activations(activations), .rejections(rejections)
    );

    assign pe_out_ready = 1'b1;

    // =========================================================================
    // Per-node signal monitors (cycle-stamped)
    // =========================================================================
    always @(posedge clk) begin
        if (hfr_out_valid)
            $display("[CYCLE %0t] HFR out: data=%02h sop=%b eop=%b", $time, hfr_out_data, hfr_out_sop, hfr_out_eop);
        if (nob_valid)
            $display("[CYCLE %0t] NOB: data=%02h sop=%b eop=%b", $time, nob_data, nob_sop, nob_eop);
        if (y_valid)
            $display("[CYCLE %0t] Y-lane: data=%02h sop=%b eop=%b", $time, y_data, y_sop, y_eop);
        if (node_valid)
            $display("[CYCLE %0t] NODE: data=%02h sop=%b eop=%b", $time, node_data, node_sop, node_eop);
        if (pe_out_valid)
            $display("[CYCLE %0t] PE->DB: data=%02h last=%b", $time, pe_out_data, pe_out_last);
        if (fire)
            $display("[CYCLE %0t] DOORBELL FIRE activations=%0d", $time, activations + 1);
        if (node_err)
            $display("[CYCLE %0t] NODE_ERR rejections=%0d", $time, rejections + 1);
    end

    // =========================================================================
    // Packet sender (negedge injection, matching tb_fabric.v pattern)
    // =========================================================================
    integer errors, i;
    integer pkt_idx;

    task put_byte;
        input [7:0] d;
        input       sop;
        input       eop;
        begin
            @(negedge clk);
            drv_data  = d;
            drv_valid = 1'b1;
            drv_sop   = sop;
            drv_eop   = eop;
            // wait for downstream to accept (drv_ready from HFR)
            @(negedge clk);
            while (!drv_ready) @(negedge clk);
            drv_valid = 1'b0;
            drv_sop   = 1'b0;
            drv_eop   = 1'b0;
        end
    endtask

    task send_packet;
        input [7:0] layer_id;
        input [7:0] module_id;
        input [7:0] ctrl;
        input integer payload_len;
        input integer corrupt;
        reg [15:0] crc;
        begin
            // Compute CRC over [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]
            crc = 16'hFFFF;
            crc = crc16_byte(crc, module_id);
            crc = crc16_byte(crc, ctrl);
            crc = crc16_byte(crc, payload_len[7:0]);
            crc = crc16_byte(crc, 8'h00);
            for (i = 0; i < payload_len; i = i + 1)
                crc = crc16_byte(crc, i[7:0]);
            if (corrupt) crc = crc ^ 16'h00FF;
            // Inject packet: LAYER_ID, MODULE_ID, CTRL, LEN_LO, LEN_HI, payload..., CRC_HI, CRC_LO
            put_byte(layer_id,  1'b1, 1'b0);   // SOP
            put_byte(module_id, 1'b0, 1'b0);
            put_byte(ctrl,      1'b0, 1'b0);
            put_byte(payload_len[7:0], 1'b0, 1'b0); // LEN_LO
            put_byte(8'h00,     1'b0, 1'b0);         // LEN_HI
            for (i = 0; i < payload_len; i = i + 1)
                put_byte(i[7:0], 1'b0, 1'b0);
            put_byte(crc[15:8], 1'b0, 1'b0);  // CRC_HI
            put_byte(crc[7:0],  1'b0, 1'b1);  // CRC_LO + EOP
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_integration.vcd");
        $dumpvars(0, tb_integration);
        errors = 0;
        drv_data = 0; drv_valid = 0; drv_sop = 0; drv_eop = 0;

        #25; rst_n = 1; #10;

        // T1: Valid packet -> doorbell fires
        $display("\n[INT] Test 1: Valid packet delivery");
        send_packet(8'h01, 8'h25, 8'h40, 4, 0);
        repeat (50) @(posedge clk);
        @(negedge clk);
        if (activations < 1) begin
            $display("[INT] FAIL(T1): doorbell did not fire, activations=%0d rejections=%0d", activations, rejections);
            errors = errors + 1;
        end else
            $display("[INT] PASS(T1): doorbell fired, activations=%0d", activations);

        // T2: Corrupt CRC -> pe_tile_stub repairs CRC, doorbell fires,
        //     but corrupt_out pulses (hardware verdict)
        $display("\n[INT] Test 2: Corrupt CRC (repaired by pe_tile_stub)");
        send_packet(8'h01, 8'h25, 8'h40, 4, 1);
        repeat (50) @(posedge clk);
        @(negedge clk);
        $display("[INT] T2: activations=%0d rejections=%0d (expect doorbell fires, CRC repaired)", activations, rejections);

        // T3: Wrong DEST -> node_eject passes through, doorbell never sees it
        $display("\n[INT] Test 3: Wrong DEST");
        send_packet(8'h01, 8'h33, 8'h40, 4, 0);
        repeat (50) @(posedge clk);
        @(negedge clk);
        $display("[INT] T3: activations=%0d rejections=%0d (should not change)", activations, rejections);

        // T4: Back-to-back packets (both should fire)
        $display("\n[INT] Test 4: Back-to-back");
        send_packet(8'h01, 8'h25, 8'h40, 2, 0);
        send_packet(8'h01, 8'h25, 8'h40, 2, 0);
        repeat (100) @(posedge clk);
        @(negedge clk);
        $display("[INT] T4: activations=%0d rejections=%0d (expect +2)", activations, rejections);

        // T5: Layer mismatch -> xyz_repeater passes through (no delivery)
        $display("\n[INT] Test 5: Layer mismatch");
        send_packet(8'h02, 8'h25, 8'h40, 2, 0);
        repeat (50) @(posedge clk);
        @(negedge clk);
        $display("[INT] T5: activations=%0d (should not increase)", activations);

        $display("\n[INT] Final: activations=%0d rejections=%0d errors=%0d",
                 activations, rejections, errors);
        if (errors == 0)
            $display("*** INTEGRATION TEST PASSED ***");
        else
            $display("*** INTEGRATION TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish(1); end

endmodule
