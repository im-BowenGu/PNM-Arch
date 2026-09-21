`timescale 1ns/1ps
// Regression: pe_tile_stub CU_TYPE=2 (INT4 MAC) result serializer.
// Feed payload [2,2,2,2] with INT8_WEIGHT=1. The running sum (8) must be
// emitted as 4 little-endian bytes on the master port after the message, and
// the serializer must drain fully (pending->0, no stale leak). This pins the
// round-32 C1 fix (the original serializer captured only the first MAC
// result, never drained after s1_last, and leaked stale SR bytes).
module tb;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg  [7:0]  s_data;
    reg         s_valid;
    reg         s_last;
    reg         s_start;
    wire        s_ready;
    wire [7:0]  m_data;
    wire        m_valid;
    wire        m_last;
    wire        m_start;
    reg         m_ready;

    wire [7:0]  tx_data;
    wire        tx_valid;
    wire [1:0]  tx_vc;
    wire        route_err, corrupt_out;

    pe_tile_stub #(
        .MULT_LATENCY(2),
        .KERNEL_CONST(8'h00),
        .CU_TYPE(2),
        .INT8_WEIGHT(8'sd1),
        .USE_FMA(0)
    ) u_pe (
        .clk(clk), .rst_n(rst_n),
        .routing_bitmap(11'h040),
        .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_last),
        .s_axis_tstart(s_start),
        .m_axis_tdata(m_data), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tlast(m_last),
        .m_axis_tstart(m_start),
        .m_axis_tx_tdata(tx_data), .m_axis_tx_tvalid(tx_valid),
        .m_axis_tx_tready(1'b1), .m_axis_tx_tlast(), .m_axis_tx_tstart(),
        .tx_vc(tx_vc), .route_err(route_err), .corrupt_out(corrupt_out)
    );

    integer errors = 0;
    integer i2;
    reg [7:0] cap [0:31];
    integer capn = 0;
    reg [7:0] body [0:9];
    reg [15:0] crc;
    reg [223:0] cov;
    integer s;
    integer found;

    function [15:0] crc16;
        input [223:0] bytes;
        input [7:0]   n;
        integer kb, b;
        reg [15:0] crc;
        begin
            crc = 16'hFFFF;
            for (kb = 0; kb < n; kb = kb + 1) begin
                crc = crc ^ (bytes[kb*8 +: 8] << 8);
                for (b = 0; b < 8; b = b + 1) begin
                    if (crc[15]) crc = (crc << 1) ^ 16'h1021;
                    else         crc = (crc << 1);
                end
            end
            crc16 = crc;
        end
    endfunction

    task send_byte;
        input [7:0] d;
        input       last;
        input       start;
        begin
            s_data  = d;
            s_last  = last;
            s_start = start;
            s_valid = 1;
            while (!s_ready) @(posedge clk);
            @(posedge clk);
            #1;
        end
    endtask

    // capture master stream
    always @(posedge clk) begin
        if (m_valid && m_ready && capn < 32) begin
            cap[capn] = m_data;
            capn = capn + 1;
        end
    end

    initial begin
        m_ready = 1;
        s_valid = 0; s_data = 0; s_last = 0; s_start = 0;
        @(posedge clk); #1;
        rst_n = 0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1;

        body[0] = 8'h00;  // DEST
        body[1] = 8'h80;  // CTRL
        body[2] = 8'h04;  // LEN_LO
        body[3] = 8'h00;  // LEN_HI
        body[4] = 8'h02;
        body[5] = 8'h02;
        body[6] = 8'h02;
        body[7] = 8'h02;
        cov = 0;
        for (i2 = 0; i2 < 8; i2 = i2 + 1)
            cov[i2*8 +: 8] = body[i2+1];
        crc = crc16(cov, 8);
        body[8] = crc[15:8];
        body[9] = crc[7:0];
        for (i2 = 0; i2 < 10; i2 = i2 + 1)
            send_byte(body[i2], (i2 == 9), (i2 == 0));
        s_valid = 0;
        // flush: let the result serializer drain (master port, m_ready high)
        repeat (20) @(posedge clk); #1;

        $display("capn=%0d", capn);
        $write("captured:");
        for (i2 = 0; i2 < capn; i2 = i2 + 1) $write(" %02x", cap[i2]);
        $display("");

        // The total 8 must appear (little-endian 08 00 00 00) somewhere in the
        // master stream after the message delivered bytes.
        begin
            found = 0;
            for (s = 0; s <= capn - 4; s = s + 1) begin
                if (cap[s] == 8'h08 && cap[s+1] == 8'h00
                    && cap[s+2] == 8'h00 && cap[s+3] == 8'h00) found = 1;
            end
            if (found) begin
                $display("PASS: running total 8 emitted little-endian (08 00 00 00)");
            end else begin
                $display("FAIL: no little-endian 08 00 00 00 in master stream");
                errors = errors + 1;
            end
        end

        if (u_pe.int4_out_pending === 1'b0) begin
            $display("PASS: serializer drained (pending=0)");
        end else begin
            $display("FAIL: int4_out_pending stuck at 1 (stale leak)");
            errors = errors + 1;
        end

        if (errors == 0) $display("*** C1 DETECTOR PASS ***");
        else            $display("*** C1 DETECTOR FAIL: %0d errors ***", errors);
        $finish;
    end
endmodule