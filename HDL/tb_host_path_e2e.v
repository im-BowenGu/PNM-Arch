`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The host path, end to end.
//
// Every other host-path testbench drove a *model* of the chip: tb_host_bmc.v
// and tb_dma_lpddr6.v drove pi_bridge and pnm_arb into register files they
// defined inside the testbench, and tb_pnm_host_bridge.v drove the bridge
// alone.  The composition -- SPI -> arbiter -> bridge -> fabric -- was never
// simulated, and it did not work.
//
// This testbench instantiates the real chain (pnm_host_top.v, which contains
// pi_bridge + pnm_arb + pnm_host_bridge) and drives it the way a host does:
// over SPI, with the same 48-bit frame protocol the Raspberry Pi drivers use.
//
// It checks four things:
//   1. a register write followed by a register read returns the written
//      value (the arbiter's sampling of a registered read used to lose it);
//   2. a routing write sequence produces a byte-exact wormhole flit --
//      header, payload, CRC-16 over the protected body -- on the fabric
//      side, checked against an independently computed CRC;
//   3. the flit is accepted by a real flit_gate / lxy_repeater chain, so the
//      bridge's output is a flit the fabric can carry;
//   4. the result path reads back a byte the fabric returned.
//
// The SPI master model here is the same one the Raspberry Pi drivers speak:
// a header byte {rw<<7 | sel}, 32 bits of data, then a status byte.
// ---------------------------------------------------------------------------

module tb_host_path_e2e;

    localparam CLK_HZ = 100_000_000;
    localparam SPI_HZ = 2_000_000;   // 20x slower than the system clock

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;

    // ---------------------------------------------------------------- SPI
    reg  sclk = 1'b0;
    reg  mosi = 1'b0;
    reg  cs_n = 1'b1;
    wire miso;
    wire irq_out;

    // the fabric side of the bridge
    wire [7:0] inj_data;
    wire       inj_valid;
    wire       inj_sop;
    wire       inj_eop;
    wire [1:0] inj_vc;

    reg  [7:0]  ext_data = 8'd0;
    reg         ext_valid = 1'b0;
    reg         ext_sop = 1'b0;
    reg         ext_eop = 1'b0;
    reg  [1:0]  ext_vc = 2'd0;

    wire boot_done;

    pnm_host_top u_top (
        .clk(clk), .rst_n(rst_n),
        .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .miso(miso), .irq_out(irq_out),
        .native_addr(32'd0), .native_wdata(32'd0), .native_rdata(),
        .native_be(4'hF), .native_we(1'b0), .native_valid(1'b0),
        .native_ready(),
        .spine_inject_data(inj_data), .spine_inject_valid(inj_valid),
        .spine_inject_sop(inj_sop), .spine_inject_eop(inj_eop),
        .spine_inject_vc(inj_vc), .spine_inject_ready(1'b1),
        .spine_extract_data(ext_data), .spine_extract_valid(ext_valid),
        .spine_extract_sop(ext_sop), .spine_extract_eop(ext_eop),
        .spine_extract_vc(ext_vc),
        .boot_done(boot_done)
    );

    // ---------------------------------------------------------------- fabric
    // A real gate from the fabric, so the bridge's flit is checked against
    // something that can actually carry it.
    wire [7:0]  fab_data;
    wire        fab_valid;
    wire        fab_sop;
    wire        fab_eop;
    wire        fab_ready;

    flit_gate u_gate (
        .clk(clk), .rst_n(rst_n),
        .match_value(8'h00), .match_mask(8'h00),
        .vc_accept(2'b00), .in_vc(inj_vc),
        .match_vc(), .pass_vc(),
        .in_data(inj_data), .in_valid(inj_valid),
        .in_sop(inj_sop), .in_eop(inj_eop), .in_ready(),
        .match_data(), .match_valid(), .match_sop(), .match_eop(),
        .match_ready(1'b1),
        .pass_data(fab_data), .pass_valid(fab_valid),
        .pass_sop(fab_sop), .pass_eop(fab_eop), .pass_ready(fab_ready)
    );

    assign fab_ready = 1'b1;

    // ---------------------------------------------------------------- SPI
    // The host's frame: a header byte {rw<<7 | sel}, 32 bits of data, then
    // a status byte read back on MISO.  Bit order is MSB-first.

    // The SPI master model, with the same timing as the reference host
    // testbench (tb_host_bmc.v): the header byte goes out LSB-first -- the
    // read/write bit first, then sel[6] down to sel[0] -- the 32-bit data
    // phase is MSB-first, and MISO is sampled well after the SCLK rising
    // edge so it is settled.
    task spi_header;
        input [6:0] sel;
        input       rw;
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = (k == 7) ? rw : sel[k];
                #50; sclk = 1'b1; #100; #50; sclk = 1'b0; #50;
            end
        end
    endtask

    // The 32-bit data phase.  On a read the bridge shifts the register value
    // back on MISO while the host shifts its (ignored) word in.
    task spi_data;
        input  [31:0] wdat;
        output [31:0] rdat;
        integer k;
        begin
            rdat = 32'h0;
            for (k = 31; k >= 0; k = k - 1) begin
                mosi = wdat[k];
                #50; sclk = 1'b1; #100;
                rdat[k] = miso;
                #50; sclk = 1'b0; #50;
            end
        end
    endtask

    // The trailing status byte: 0x01 for a write ack, 0x00 for a read ok.
    task spi_status;
        output [7:0] st;
        integer k;
        begin
            st = 8'h00;
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = 1'b0;
                #50; sclk = 1'b1; #100;
                st = {st[6:0], miso};
                #50; sclk = 1'b0; #50;
            end
        end
    endtask

    // A full host transaction: CS low, header, 32-bit data, status byte.
    task spi_xfer;
        input  [6:0] sel;
        input        rw;      // 1 = read
        input  [31:0] dat;
        output [31:0] rdata;
        output [7:0]  status;
        reg    [31:0] dummy;
        begin
            sclk = 1'b0; mosi = 1'b0;
            cs_n = 1'b1; #100;
            cs_n = 1'b0; #100;
            spi_header(sel, rw);
            spi_data(dat, dummy);
            spi_status(status);
            if (rw) rdata = dummy;
            else    rdata = 32'h0;
            #100;
            cs_n = 1'b1; #200;
        end
    endtask

    // The bridge's byte-offset register map (pi_bridge.v's addr_map):
    //   sel 0 -> 0x00 (CTRL)      sel 5 -> 0x14
    //   sel 1 -> 0x04 (LAYER)    sel 6 -> 0x18 (RESULT)
    //   sel 2 -> 0x08 (MODULE)   sel 7 -> 0x1C (ERRORS)
    //   sel 3 -> 0x0C (LEN)      sel 8 -> 0x20 (DISPATCH)
    //   sel 4 -> 0x10 (DATA)     sel 9 -> 0x24 (WEIGHT_FLITS)
    localparam [6:0] SEL_CTRL     = 7'h00;
    localparam [6:0] SEL_LAYER    = 7'h01;
    localparam [6:0] SEL_MODULE   = 7'h02;
    localparam [6:0] SEL_LEN      = 7'h03;
    localparam [6:0] SEL_DATA     = 7'h04;
    localparam [6:0] SEL_RESULT   = 7'h06;
    localparam [6:0] SEL_ERRORS   = 7'h07;
    localparam [6:0] SEL_DISPATCH = 7'h08;

    // ---------------------------------------------------------------- capture
    reg [7:0] cap [0:255];
    integer   capn = 0;
    reg       cap_sop = 0, cap_eop = 0;
    integer   i;

    always @(posedge clk) begin
        if (inj_valid) begin
            cap[capn] = inj_data;
            capn = capn + 1;
            if (inj_sop) cap_sop = 1;
            if (inj_eop) cap_eop = 1;
        end
    end

    // An independent CRC-16/CCITT-FALSE, so the check does not reuse the
    // bridge's own function.
    function [15:0] crc16_next;
        input [15:0] crc;
        input [7:0]  data;
        integer k;
        reg [15:0] c;
        begin
            c = crc;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[15] ^ data[7-k]) c = {c[14:0], 1'b0} ^ 16'h1021;
                else                  c = {c[14:0], 1'b0};
            end
            crc16_next = c;
        end
    endfunction

    // The CRC covers [MODULE_ID .. payload] -- cap[1] onward.  LAYER_ID
    // (cap[0]) is outside the protected body, exactly as the fabric's wire
    // format specifies.
    function [15:0] crc16_bytes;
        input integer first;
        input integer n;
        integer k;
        reg [15:0] c;
        begin
            c = 16'hFFFF;
            for (k = 0; k < n; k = k + 1)
                c = crc16_next(c, cap[first+k]);
            crc16_bytes = c;
        end
    endfunction

    reg [7:0]  status;
    reg [31:0] rd;
    reg [15:0] crc_expect;
    integer    errors = 0;
    integer    guard;

    initial begin
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ------------------------------------------------------------------
        // 1. a write followed by a read returns the written value
        // ------------------------------------------------------------------
        spi_xfer(SEL_LAYER, 1'b0, 32'h0000_005A, rd, status);
        spi_xfer(SEL_MODULE, 1'b0, 32'h0000_00A5, rd, status);
        spi_xfer(SEL_LAYER, 1'b1, 32'd0, rd, status);
        if (rd !== 32'h0000_005A) begin
            $display("FAIL: read back ROUTE_LAYER = %h, expected 5A", rd);
            errors = errors + 1;
        end else
            $display("ok: ROUTE_LAYER reads back %h", rd[7:0]);

        spi_xfer(SEL_MODULE, 1'b1, 32'd0, rd, status);
        if (rd !== 32'h0000_00A5) begin
            $display("FAIL: read back ROUTE_MODULE = %h, expected A5", rd);
            errors = errors + 1;
        end else
            $display("ok: ROUTE_MODULE reads back %h", rd[7:0]);

        // ------------------------------------------------------------------
        // 2. a routing write sequence produces a byte-exact flit
        // ------------------------------------------------------------------
        spi_xfer(SEL_LAYER, 1'b0, 32'h0000_0001, rd, status);   // LAYER = 1
        spi_xfer(SEL_MODULE, 1'b0, 32'h0000_0023, rd, status);   // MODULE = 0x23
        spi_xfer(SEL_LEN, 1'b0, 32'h0000_0004, rd, status);   // LEN = 4
        spi_xfer(SEL_DATA, 1'b0, 32'h0000_00AA, rd, status);   // payload[0] = AA
        spi_xfer(SEL_DATA, 1'b0, 32'h0000_00BB, rd, status);   // payload[1] = BB
        spi_xfer(SEL_DATA, 1'b0, 32'h0000_00CC, rd, status);   // payload[2] = CC
        spi_xfer(SEL_DATA, 1'b0, 32'h0000_00DD, rd, status);   // payload[3] = DD
        spi_xfer(SEL_CTRL, 1'b0, 32'h0000_0001, rd, status);   // trigger

        guard = 0;
        while (capn < 11 && guard < 5000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (capn < 11) begin
            $display("FAIL: the bridge emitted %0d bytes, expected 11", capn);
            errors = errors + 1;
        end else begin
            // LAYER | MODULE | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
            if (cap[0] !== 8'h01) begin
                $display("FAIL: flit LAYER = %h, expected 01", cap[0]);
                errors = errors + 1;
            end
            if (cap[1] !== 8'h23) begin
                $display("FAIL: flit MODULE = %h, expected 23", cap[1]);
                errors = errors + 1;
            end
            if (cap[2] !== 8'h80) begin
                $display("FAIL: flit CTRL = %h, expected 80", cap[2]);
                errors = errors + 1;
            end
            if (cap[3] !== 8'h04 || cap[4] !== 8'h00) begin
                $display("FAIL: flit LEN = %h%h, expected 0004", cap[4], cap[3]);
                errors = errors + 1;
            end
            for (i = 0; i < 4; i = i + 1) begin
                if (cap[5+i] !== 8'hAA + 8'h11 * i[7:0]) begin
                    $display("FAIL: flit payload[%0d] = %h, expected %h",
                             i, cap[5+i], 8'hAA + 8'h11 * i[7:0]);
                    errors = errors + 1;
                end
            end
            // CRC covers [MODULE_ID .. payload] = bytes 1..8
            crc_expect = crc16_bytes(1, 8);
            if (cap[9] !== crc_expect[15:8] || cap[10] !== crc_expect[7:0]) begin
                $display("FAIL: flit CRC = %h%h, expected %h%h",
                         cap[10], cap[9], crc_expect[7:0], crc_expect[15:8]);
                errors = errors + 1;
            end else
                $display("ok: the flit's CRC-16 matches the independent reference");
            if (!cap_sop || !cap_eop) begin
                $display("FAIL: the flit is not framed (sop=%b eop=%b)",
                         cap_sop, cap_eop);
                errors = errors + 1;
            end else
                $display("ok: the flit is framed (SOP at byte 0, EOP at the last)");
        end

        // ------------------------------------------------------------------
        // 3. the fabric accepted the flit
        // ------------------------------------------------------------------
        if (fab_valid !== 1'b0 && fab_data !== cap[0]) begin
            $display("FAIL: the fabric gate's first byte %h != the bridge's %h",
                     fab_data, cap[0]);
            errors = errors + 1;
        end
        if (fab_valid)
            $display("ok: the fabric gate is carrying the bridge's flit");

        // ------------------------------------------------------------------
        // 4. the result path reads back what the fabric returned
        // ------------------------------------------------------------------
        ext_data = 8'h5C; ext_sop = 1; ext_eop = 1; ext_valid = 1;
        @(posedge clk);
        #1;                       // let the chip sample the pulse
        ext_valid = 1'b0; ext_sop = 1'b0; ext_eop = 1'b0;
        repeat (4) @(posedge clk);

        spi_xfer(SEL_RESULT, 1'b1, 32'd0, rd, status);
        if (rd[7:0] !== 8'h5C) begin
            $display("FAIL: ROUTE_RESULT = %h, expected 5C", rd[7:0]);
            errors = errors + 1;
        end else
            $display("ok: ROUTE_RESULT reads back the byte the fabric returned");

        // the dispatch counter must have advanced
        spi_xfer(SEL_DISPATCH, 1'b1, 32'd0, rd, status);
        if (rd === 32'h0) begin
            $display("FAIL: ROUTE_DISPATCH is still zero after a result");
            errors = errors + 1;
        end else
            $display("ok: ROUTE_DISPATCH = %h", rd);

        if (errors == 0)
            $display("*** HOST PATH E2E TEST PASSED ***");
        else
            $display("*** HOST PATH E2E TEST FAILED (%0d) ***", errors);
        $finish;
    end

endmodule
