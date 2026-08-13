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
//   2. refusals (ACK withheld, NODE_ERR) for corrupt CRC, truncated length,
//      and DEST mismatch — each is observable, none fires the kernel;
//   3. pe_tile_stub passes the stream through byte-exact (elastic pipe).
//
// Expected: 4 activations (p0, p1, p6, p7), 3 rejections (p2, p3, p4, p5).
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

    pe_tile_stub #(.MULT_LATENCY(2)) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tready(tsready),
        .s_axis_tlast(teop),
        .m_axis_tdata(d_data), .m_axis_tvalid(d_valid), .m_axis_tready(d_ready),
        .m_axis_tlast(d_eop)
    );

    assign d_ready = 1'b1;

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
        reg [15:0] crc;
        begin
            crc = 16'hFFFF;
            send_n = plen;
            if (mode == 3) send_n = plen - 2;   // truncated before CRC

            put(dest, 1'b0); crc = crc_ref(crc, dest);
            put(ctrl, 1'b0); crc = crc_ref(crc, ctrl);
            put(plen[7:0], 1'b0); crc = crc_ref(crc, plen[7:0]);
            put(plen[15:8], 1'b0); crc = crc_ref(crc, plen[15:8]);

            for (k = 0; k < send_n; k = k + 1) begin
                pb = (k * 7 + 3) & 8'hFF;
                // mode 1: corrupt a mid-payload byte *after* the CRC is
                // computed -- CRC covers the original, the wire carries the
                // flipped byte, so the doorbell must refuse (Paper §2.9)
                if (mode == 1 && k == send_n / 2)
                    put(pb ^ 8'hFF, 1'b0);
                else
                    put(pb, 1'b0);
                crc = crc_ref(crc, pb);
            end

            if (mode == 3) begin
                // truncated: EOP lands in the payload -> refusal (count mismatch)
                put(8'h00, 1'b1);
            end else if (mode == 2) begin
                put(crc[15:8] ^ 8'hFF, 1'b0);   // wrong CRC_HI
                put(crc[7:0] ^ 8'hFF, 1'b1);    // wrong CRC_LO
            end else begin
                put(crc[15:8], 1'b0);
                put(crc[7:0], 1'b1);
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
    always @(posedge clk) begin
        if (d_ack && !d_fire) ack_alone = 1;
        if (d_fire && d_node_err) fire_with_err = 1;
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

        send_packet(8'h25, 8'h40, 8,  0);   // p0 good
        send_packet(8'h25, 8'h50, 1,  0);   // p1 good, minimal payload
        send_packet(8'h25, 8'h41, 16, 1);   // p2 corrupt payload -> CRC fail
        send_packet(8'h25, 8'h42, 8,  2);   // p3 bad CRC bytes
        send_packet(8'h25, 8'h43, 8,  3);   // p4 truncated length
        send_packet(8'h53, 8'h44, 8,  0);   // p5 wrong DEST, valid CRC
        send_packet(8'h25, 8'h45, 0,  0);   // p6 empty payload
        send_packet(8'h25, 8'h46, 300, 0);  // p7 large payload

        // settle: drain the last packet through the 2-cycle pipe + decision
        repeat (100) @(negedge clk);

        $display("");
        $display("--- Doorbell accounting ---");
        check_eq("activations", d_act, 4);
        check_eq("rejections ", d_rej, 4);

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
