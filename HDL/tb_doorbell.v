`timescale 1ns/1ps
`include "pnm_defs.vh"

// =============================================================================
// tb_doorbell — doorbell FSM + pe_tile_stub integration test
//
// Chain under test:
//
//     stim (task) -> pe_tile_stub (MULT_LATENCY=2, the node's MAC pipe)
//                 -> doorbell (LOCAL_MODULE=0x25, the node DMA + hardened
//                              doorbell of Paper §2.4/§2.9)
//
// pe_tile_stub is the fabric's compute contract (Paper §2.9) and is exercised
// here so the module is no longer dead code: the doorbell validates the DMA
// stream *after* the MAC latency pipe, proving the elastic pipe preserves
// framing and the doorbell still fires.
//
// The TB computes an independent CRC-16/CCITT-FALSE reference (a second,
// self-contained implementation — not a reuse of crc16.v) and checks:
//
//   1. doorbell fires (TRIG + ACK same cycle) iff byte count == LEN+6,
//      CRC validates, and DEST == 0x25;
//   2. refusals (ACK withheld, NODE_ERR) for truncated length and DEST
//      mismatch — each is observable, none fires the kernel;
//   3. pe_tile_stub passes the stream through byte-exact (elastic pipe),
//      except that it *repairs* the CRC of corrupt packets: it validates
//      the incoming CRC and re-emits CRC-16/CCITT-FALSE over the transformed
//      body, so the stream it hands to the doorbell is always internally
//      consistent.  Its corrupt_out pulse — the hardware doorbell verdict
//      that the co-sim uses for refusal accounting — fires for every packet
//      whose incoming CRC failed (p2, p3), while the repaired bytes still
//      stream out so accounting stays lossless.
//
// Expected: 6 activations (p0, p1, p2, p3, p6, p7), 2 rejections
// (p4 truncated, p5 wrong DEST), 2 corrupt_out pulses (p2, p3).
// =============================================================================
module tb_doorbell;
    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz
    reg rst_n = 1'b0;

    integer errors = 0;

    // ---- stim -> pe_tile_stub slave ----
    reg  [7:0] tdata;
    reg        tvalid, teop;
    wire       tsready;

    // ---- pe_tile_stub master -> doorbell slave ----
    wire [7:0] d_data;
    wire       d_valid, d_eop;
    wire       d_ready;

    // ---- doorbell status ----
    wire       d_fire, d_ack, d_node_err;
    wire [31:0] d_act, d_rej;

    // ---- pe_tile_stub routing bitmap + route-consistency flag ----
    // node 0x25 = (X=2, Y=5): layer 1, Y axis, +, dist 5
    //   = 11'b0001_1_0_00101 = 11'h0C5
    reg  [10:0] rbm = 11'h0C5;   // {0001, 1, 0, 00101} = layer 1, Y, +, dist 5
    wire       route_err;
    wire       stub_corrupt;     // stub's hardware doorbell verdict (K=0: never)
    reg [31:0] route_err_cnt = 0;
    reg        route_err_d = 0;
    always @(posedge clk) begin
        route_err_d <= route_err;
        if (route_err && !route_err_d)   // edge-detect: count each head once
            route_err_cnt = route_err_cnt + 1;
    end

    // ---- pe_tile_stub TX echo (class 0 egress; quiescent in this TB) ----
    wire [7:0] tx_data;
    wire       tx_valid, tx_last, tx_start, tx_ready;
    wire [1:0] tx_vc;

    pe_tile_stub #(.MULT_LATENCY(2)) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .routing_bitmap(rbm),
        .route_err(route_err),
        .corrupt_out(stub_corrupt),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tready(tsready),
        .s_axis_tlast(teop), .s_axis_tstart(1'b0),
        .m_axis_tdata(d_data), .m_axis_tvalid(d_valid), .m_axis_tready(d_ready),
        .m_axis_tlast(d_eop), .m_axis_tstart(),
        .m_axis_tx_tdata(tx_data), .m_axis_tx_tvalid(tx_valid),
        .m_axis_tx_tready(tx_ready), .m_axis_tx_tlast(tx_last),
        .m_axis_tx_tstart(tx_start), .tx_vc(tx_vc)
    );

    assign d_ready = 1'b1;
    assign tx_ready = 1'b1;

    doorbell #(.LOCAL_MODULE(8'h25)) u_bell (
        .clk(clk), .rst_n(rst_n),
        .s_data(d_data), .s_valid(d_valid), .s_ready(), .s_eop(d_eop),
        .fire(d_fire), .ack(d_ack), .node_err(d_node_err),
        .activations(d_act), .rejections(d_rej)
    );

    // ---- independent CRC-16/CCITT-FALSE reference (init 0xFFFF, poly 0x1021) ----
    function [15:0] crc_ref;
        input [15:0] crc;
        input [7:0]  b;
        integer i;
        reg [15:0] c;
        begin
            c = crc ^ (b << 8);
            for (i = 0; i < 8; i = i + 1)
                c = (c & 16'h8000) ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_ref = c;
        end
    endfunction

    // ---- stimulus byte, handshake with the elastic pipe ----
    reg [7:0] expseq [0:65535];
    integer   expn;
    task put;
        input [7:0] b;
        input       eop;
        begin
            @(negedge clk);
            tdata  = b;
            tvalid = 1'b1;
            teop   = eop;
            while (!tsready) @(negedge clk);
            @(negedge clk);          // complete the posedge handshake
            tvalid = 1'b0;
            teop   = 1'b0;
            expseq[expn] = b;
            expn = expn + 1;
        end
    endtask

    // mode: 0 good, 1 corrupt payload, 2 bad CRC, 3 truncated, 4 wrong dest
    task send_packet;
        input [7:0] dest;
        input [7:0] ctrl;
        input integer plen;
        input integer mode;
        integer k, send_n;
        reg [7:0] pb;
        reg [15:0] crc;     // CRC over the intended body (appended by the sender)
        reg [15:0] wcrc;    // CRC over the *wire* body (what the stub re-emits)
        begin
            crc  = 16'hFFFF;
            wcrc = 16'hFFFF;
            send_n = plen;
            if (mode == 3) send_n = plen - 2;   // truncated before CRC

            put(dest, 1'b0);  crc = crc_ref(crc, dest);  wcrc = crc_ref(wcrc, dest);
            put(ctrl, 1'b0);  crc = crc_ref(crc, ctrl);  wcrc = crc_ref(wcrc, ctrl);
            put(plen[7:0], 1'b0);  crc = crc_ref(crc, plen[7:0]);  wcrc = crc_ref(wcrc, plen[7:0]);
            put(plen[15:8], 1'b0); crc = crc_ref(crc, plen[15:8]); wcrc = crc_ref(wcrc, plen[15:8]);

            for (k = 0; k < send_n; k = k + 1) begin
                pb = (k * 7 + 3) & 8'hFF;
                // mode 1: corrupt a mid-payload byte *after* the CRC is
                // computed -- CRC covers the original, the wire carries the
                // flipped byte, so the stub's incoming check must fail
                // (Paper §2.9) and its re-emitted CRC must cover the flip
                if (mode == 1 && k == send_n / 2) begin
                    put(pb ^ 8'hFF, 1'b0);
                    wcrc = crc_ref(wcrc, pb ^ 8'hFF);
                end else begin
                    put(pb, 1'b0);
                    wcrc = crc_ref(wcrc, pb);
                end
                crc = crc_ref(crc, pb);
            end

            if (mode == 3) begin
                // truncated: EOP lands in the payload -> refusal (count mismatch)
                put(8'h00, 1'b1);
            end else if (mode == 2) begin
                put(crc[15:8] ^ 8'hFF, 1'b0);   // wrong CRC_HI on the wire
                put(crc[7:0] ^ 8'hFF, 1'b1);    // wrong CRC_LO
                // the stub repairs the tail: expected output is the *correct*
                // CRC over the wire body, not the corrupted bytes driven above
                expseq[expn - 2] = wcrc[15:8];
                expseq[expn - 1] = wcrc[7:0];
            end else begin
                put(crc[15:8], 1'b0);
                put(crc[7:0], 1'b1);
                // mode 1: CRC was computed over the unflipped body, but the
                // stub re-emits CRC over the wire body (flip included); for
                // modes 0/4 wcrc == crc, so these fixups are no-ops
                expseq[expn - 2] = wcrc[15:8];
                expseq[expn - 1] = wcrc[7:0];
            end
        end
    endtask

    // ---- captured pe_tile_stub master output (the doorbell's actual input) ----
    reg [7:0] rxseq [0:65535];
    integer   rxn;
    always @(posedge clk)
        if (d_valid && d_ready) begin
            rxseq[rxn] = d_data;
            rxn = rxn + 1;
        end

    // ---- monitors: ACK must never appear without TRIG; no fire while err ----
    reg ack_alone = 0, fire_with_err = 0;
    reg [31:0] stub_corrupt_cnt = 0;
    always @(posedge clk) begin
        if (d_ack && !d_fire) ack_alone = 1;
        if (d_fire && d_node_err) fire_with_err = 1;
        if (stub_corrupt) stub_corrupt_cnt = stub_corrupt_cnt + 1;
    end

    task check_eq;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got %0d expected %0d", name, got, exp);
                errors = errors + 1;
            end else
                $display("PASS: %0s = %0d", name, got);
        end
    endtask

    integer i;

    initial begin
        tdata = 0; tvalid = 0; teop = 0;
        expn = 0; rxn = 0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        $display("=== DOORBELL TEST: good / corrupt-CRC / truncated / DEST ===");

        send_packet(8'h25, 8'h80, 8,  0);   // p0 good
        send_packet(8'h25, 8'h90, 1,  0);   // p1 good, minimal payload
        send_packet(8'h25, 8'h82, 16, 1);   // p2 corrupt payload -> CRC fail
        send_packet(8'h25, 8'h84, 8,  2);   // p3 bad CRC bytes
        send_packet(8'h25, 8'h86, 8,  3);   // p4 truncated length
        send_packet(8'h53, 8'h88, 8,  0);   // p5 wrong DEST, valid CRC
        send_packet(8'h25, 8'h8A, 0,  0);   // p6 empty payload
        send_packet(8'h25, 8'h8C, 300, 0);  // p7 large payload

        // settle: drain the last packet through the 2-cycle pipe + decision
        repeat (100) @(negedge clk);

        $display("");
        $display("--- Doorbell accounting ---");
        check_eq("activations", d_act, 6);
        check_eq("rejections ", d_rej, 2);

        $display("");
        $display("--- pe_tile_stub hardware doorbell verdict (corrupt_out) ---");
        check_eq("corrupt pulses (p2 payload-flip, p3 bad CRC)", stub_corrupt_cnt, 2);

        $display("");
        $display("--- pe_tile_stub route-consistency comparator ---");
        check_eq("route_err (DEST 0x53 vs dist 5)", route_err_cnt, 1);

        $display("");
        $display("--- Protocol invariants ---");
        check_eq("ACK never without TRIG", ack_alone, 0);
        check_eq("no fire while NODE_ERR", fire_with_err, 0);

        $display("");
        $display("--- pe_tile_stub passthrough (elastic pipe, byte-exact) ---");
        check_eq("pipe bytes out", rxn, expn);
        for (i = 0; i < expn && i < rxn; i = i + 1)
            if (rxseq[i] !== expseq[i]) begin
                $display("FAIL: pipe byte %0d = %02x expected %02x",
                         i, rxseq[i], expseq[i]);
                errors = errors + 1;
            end
        if (rxn == expn)
            $display("PASS: pipe carried all %0d bytes in order", expn);

        if (errors == 0)
            $display("\n*** DOORBELL TEST PASSED ***");
        else
            $display("\n*** DOORBELL TEST FAILED: %0d error(s) ***", errors);
        $finish;
    end

    initial begin
        #5_000_000;   // 5 ms watchdog
        $display("TIMEOUT in doorbell test");
        $finish;
    end

endmodule
