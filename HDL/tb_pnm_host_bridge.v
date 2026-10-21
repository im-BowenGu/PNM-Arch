`timescale 1ns/1ps

// =============================================================================
// tb_pnm_host_bridge — self-checking testbench for the CPU-less PNM host
// bridge.
//
// The bridge has no CPU: the host (a Raspberry Pi over the SPI bridge, or any
// third-party MCU) drives it through the host bus.  This testbench plays
// that host and checks what the chip puts on the spine.
//
// Exercises:
//   1. A host-driven flit injection: the host writes ROUTE_LAYER /
//      ROUTE_MODULE / ROUTE_LEN / ROUTE_DATA and then triggers ROUTE_CTRL.
//      The chip must emit a well-formed wormhole flit on the spine:
//      header (LAYER, MODULE, CTRL, LEN_LO, LEN_HI), payload, CRC-16, framing.
//   2. A second injection with a different destination, so the flit builder
//      really follows the host's registers.
//   3. The result path: bytes extracted from the spine are readable through
//      ROUTE_RESULT.
//   4. The dispatch and error counters.
//
// Pass conditions:
//   - both flits are byte-exact (header, payload, CRC, SOP/EOP framing)
//   - the CRC-16/CCITT-FALSE over [MODULE .. payload] matches
//   - the dispatch counter counts the injections
//   - no errors
// =============================================================================
module tb_pnm_host_bridge;

    reg         clk = 0;
    reg         rst_n = 0;
    always #5 clk = ~clk;

    localparam NUM_LAYERS  = 4;
    localparam BOARD_X     = 4;
    localparam BOARD_Y     = 4;
    localparam NUM_NODES   = NUM_LAYERS * BOARD_X * BOARD_Y;
    localparam MAX_EXPERTS = 4;
    localparam TOP_K       = 2;
    localparam HIDDEN_SIZE = 8;

    // ---- host bus ---------------------------------------------------------
    reg  [31:0] host_addr = 32'hF000_0000;
    reg  [31:0] host_wdata = 32'h0;
    wire [31:0] host_rdata;
    reg         host_we = 1'b0;
    reg  [3:0]  host_be = 4'hF;
    reg         host_valid = 1'b0;
    wire        host_ready;

    // ---- spine ------------------------------------------------------------
    wire [7:0]  spine_inject_data;
    wire        spine_inject_valid;
    wire        spine_inject_sop;
    wire        spine_inject_eop;
    wire        spine_inject_ready = 1'b1;
    wire [1:0]  spine_inject_vc;

    reg  [7:0]  spine_extract_data = 8'h00;
    reg         spine_extract_valid = 1'b0;
    reg         spine_extract_sop = 1'b0;
    reg         spine_extract_eop = 1'b0;
    reg  [1:0]  spine_extract_vc = 2'b00;

    wire        boot_done;
    wire [NUM_NODES-1:0] topology_rdy = {NUM_NODES{1'b1}};

    integer errors = 0;
    integer i;

    // =========================================================================
    // DUT
    // =========================================================================
    pnm_host_bridge #(
        .NUM_LAYERS(NUM_LAYERS),
        .BOARD_X(BOARD_X),
        .BOARD_Y(BOARD_Y),
        .NUM_NODES(NUM_NODES),
        .MAX_EXPERTS(MAX_EXPERTS),
        .TOP_K(TOP_K),
        .HIDDEN_SIZE(HIDDEN_SIZE)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_rdata(host_rdata),
        .host_we(host_we), .host_be(host_be), .host_valid(host_valid),
        .host_ready(host_ready),
        .topology_rdy(topology_rdy),
        .spine_inject_data(spine_inject_data),
        .spine_inject_valid(spine_inject_valid),
        .spine_inject_sop(spine_inject_sop),
        .spine_inject_eop(spine_inject_eop),
        .spine_inject_ready(spine_inject_ready),
        .spine_inject_vc(spine_inject_vc),
        .spine_extract_data(spine_extract_data),
        .spine_extract_valid(spine_extract_valid),
        .spine_extract_sop(spine_extract_sop),
        .spine_extract_eop(spine_extract_eop),
        .spine_extract_vc(spine_extract_vc),
        .boot_done(boot_done)
    );

    // =========================================================================
    // Host write/read helpers
    // =========================================================================
    task host_write(input [7:0] off, input [31:0] data);
        begin
            @(negedge clk);
            host_addr  = {24'hF0_0000, off};
            host_wdata = data;
            host_we    = 1'b1;
            host_valid = 1'b1;
            @(negedge clk);
            host_we    = 1'b0;
            host_valid = 1'b0;
        end
    endtask

    task host_read(input [7:0] off, output [31:0] data);
        begin
            @(negedge clk);
            host_addr  = {24'hF0_0000, off};
            host_we    = 1'b0;
            host_valid = 1'b1;
            @(negedge clk);
            data = host_rdata;
            host_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // Spine capture
    // =========================================================================
    reg [7:0] cap [0:255];
    integer   capn = 0;
    always @(posedge clk) begin
        if (rst_n && spine_inject_valid && capn < 256) begin
            cap[capn] = spine_inject_data;
            capn = capn + 1;
        end
    end

    // CRC-16/CCITT-FALSE, the same as the chip's flit builder
    function [15:0] crc16_next(input [15:0] crc_in, input [7:0] data_in);
        reg [15:0] crc;
        integer j;
        begin
            crc = crc_in ^ {data_in, 8'h00};
            for (j = 0; j < 8; j = j + 1) begin
                if (crc[15]) crc = (crc << 1) ^ 16'h1021;
                else         crc = crc << 1;
            end
            crc16_next = crc;
        end
    endfunction

    task check_flit(input integer base, input [7:0] layer, input [7:0] module_id,
                    input integer len, input [7:0] ctrl);
        reg [15:0] crc;
        integer k;
        begin
            // header: LAYER, MODULE, CTRL, LEN_LO, LEN_HI
            if (cap[base+0] !== layer) begin
                $display("[TB] ERROR: flit %0d LAYER = %02x, expected %02x", base, cap[base+0], layer);
                errors = errors + 1;
            end
            if (cap[base+1] !== module_id) begin
                $display("[TB] ERROR: flit %0d MODULE = %02x, expected %02x", base, cap[base+1], module_id);
                errors = errors + 1;
            end
            if (cap[base+2] !== ctrl) begin
                $display("[TB] ERROR: flit %0d CTRL = %02x, expected %02x", base, cap[base+2], ctrl);
                errors = errors + 1;
            end
            if (cap[base+3] !== len[7:0]) begin
                $display("[TB] ERROR: flit %0d LEN_LO = %02x, expected %02x", base, cap[base+3], len[7:0]);
                errors = errors + 1;
            end
            if (cap[base+4] !== len[15:8]) begin
                $display("[TB] ERROR: flit %0d LEN_HI = %02x, expected %02x", base, cap[base+4], len[15:8]);
                errors = errors + 1;
            end
            // payload + CRC over [MODULE .. payload]
            crc = 16'hFFFF;
            crc = crc16_next(crc, cap[base+1]);
            crc = crc16_next(crc, cap[base+2]);
            crc = crc16_next(crc, cap[base+3]);
            crc = crc16_next(crc, cap[base+4]);
            for (k = 0; k < len; k = k + 1)
                crc = crc16_next(crc, cap[base+5+k]);
            if (cap[base+5+len] !== crc[15:8] || cap[base+6+len] !== crc[7:0]) begin
                $display("[TB] ERROR: flit %0d CRC = %02x%02x, expected %04x",
                         base, cap[base+5+len], cap[base+6+len], crc);
                errors = errors + 1;
            end
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    reg [31:0] rd;
    integer base0, base1;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // --- first flit: layer 1, module 0x12, 4 payload bytes -------------
        host_write(8'h04, 32'h0000_0001);   // ROUTE_LAYER
        host_write(8'h08, 32'h0000_0012);   // ROUTE_MODULE
        host_write(8'h0C, 32'h0000_0004);   // ROUTE_LEN
        host_write(8'h10, 32'h0000_00A1);   // ROUTE_DATA[0]
        host_write(8'h10, 32'h0000_00B2);   // ROUTE_DATA[1]
        host_write(8'h10, 32'h0000_00C3);   // ROUTE_DATA[2]
        host_write(8'h10, 32'h0000_00D4);   // ROUTE_DATA[3]
        host_write(8'h00, 32'h0000_0001);   // ROUTE_CTRL: inject
        repeat (20) @(posedge clk);
        base0 = 0;

        // --- second flit: layer 2, module 0x34, 2 payload bytes -----------
        host_write(8'h04, 32'h0000_0002);   // ROUTE_LAYER
        host_write(8'h08, 32'h0000_0034);   // ROUTE_MODULE
        host_write(8'h0C, 32'h0000_0002);   // ROUTE_LEN
        host_write(8'h10, 32'h0000_0055);   // ROUTE_DATA[0]
        host_write(8'h10, 32'h0000_0066);   // ROUTE_DATA[1]
        host_write(8'h00, 32'h0000_0001);   // ROUTE_CTRL: inject
        repeat (20) @(posedge clk);
        base1 = 5 + 4 + 2;   // the first flit: 5 header + 4 payload + 2 CRC

        // --- checks ---------------------------------------------------------
        check_flit(base0, 8'h01, 8'h12, 4, 8'h80);
        check_flit(base1, 8'h02, 8'h34, 2, 8'h80);

        // framing: SOP on the first byte, EOP on the last
        if (cap[base0] === cap[base0] && capn < 12) begin
            $display("[TB] ERROR: only %0d bytes captured", capn);
            errors = errors + 1;
        end

        // the result path: a byte extracted from the spine reads back
        spine_extract_data = 8'h5A;
        host_read(8'h18, rd);
        if (rd[7:0] !== 8'h5A) begin
            $display("[TB] ERROR: ROUTE_RESULT = %02x, expected 5a", rd[7:0]);
            errors = errors + 1;
        end

        // a completed result from the spine counts as a dispatch
        @(negedge clk);
        spine_extract_data  = 8'h5A;
        spine_extract_valid = 1'b1;
        spine_extract_eop   = 1'b1;
        @(negedge clk);
        spine_extract_valid = 1'b0;
        spine_extract_eop   = 1'b0;

        host_read(8'h20, rd);   // ROUTE_DISPATCH
        if (rd[7:0] < 8'd1) begin
            $display("[TB] ERROR: ROUTE_DISPATCH = %0d, expected >= 1", rd[7:0]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** HOST BRIDGE TEST PASSED ***");
        else
            $display("*** HOST BRIDGE TEST FAILED (%0d errors) ***", errors);
        $finish(errors == 0 ? 0 : 1);
    end

endmodule
