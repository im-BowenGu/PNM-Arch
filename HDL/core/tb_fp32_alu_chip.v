`timescale 1ns/1ps
// Detector for C2+S1: fp32_alu_chip.v CRC validation is dead code and the
// operand collector reads the flit HEADER bytes (DEST/CTRL/LEN) as operands
// instead of the 8-byte payload.  Feed a real fabric flit:
//   [DEST, CTRL, LEN_LO=08, LEN_HI=00, opA(4), opB(4), CRC_HI, CRC_LO]
// Expect: result = opA + opB (0x40600000 = 3.5 + 2.5 = 6.0), corrupt_out=0 on
// a good CRC, corrupt_out=1 on a flit whose trailer does not match its body.
module tb;
    reg clk = 0; reg rst_n = 0;
    always #5 clk = ~clk;

    reg  [7:0] s_data; reg s_valid, s_last, s_start;
    wire       s_ready;
    wire [7:0] m_data; wire m_valid, m_last, m_start;
    reg        m_ready;
    wire       route_err, corrupt_out;

    fp32_alu_chip #(
        .OP_CODE(3'd0),      // ADD
        .ROUTE_BM(11'h040),
        .MODULE_ID(8'h00)
    ) u_chip (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_last),
        .s_axis_tstart(s_start),
        .m_axis_tdata(m_data), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tlast(m_last),
        .m_axis_tstart(m_start),
        .route_err(route_err), .corrupt_out(corrupt_out)
    );

    integer errors = 0;
    integer i2;
    reg [7:0] cap [0:15];
    integer capn = 0;
    reg [7:0] body [0:11];
    reg [95:0] cov;
    reg [15:0] crc;
    reg [95:0] ocov;
    integer    ok2;
    reg [15:0] ocrc;

    function [15:0] crc16;
        input [95:0]  bytes;
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
        if (m_valid && m_ready && capn < 16) begin
            cap[capn] = m_data;
            capn = capn + 1;
        end
    end

    task send_flit;
        input corrupt_payload;  // 1 = flip body[5] but keep the good trailer
        integer k;
        reg [15:0] g;
        begin
            // build the body: header + 8-byte payload + CRC trailer
            body[0] = 8'h00;  // DEST
            body[1] = 8'h80;  // CTRL
            body[2] = 8'h08;  // LEN_LO (8 payload bytes)
            body[3] = 8'h00;  // LEN_HI
            body[4] = 8'h40;  // opA = 3.5  (0x40600000)
            body[5] = 8'h60;
            body[6] = 8'h00;
            body[7] = 8'h00;
            body[8] = 8'h40;  // opB = 2.5  (0x40200000)
            body[9] = 8'h20;
            body[10] = 8'h00;
            body[11] = 8'h00;
            // CRC over [DEST .. last payload byte] (body[0..11])
            cov = 0;
            for (k = 0; k < 12; k = k + 1) cov[k*8 +: 8] = body[k];
            g = crc16(cov, 12);
            body[0] = 8'h00; // re-init guard (cov indexes body[0..11])
            // place the trailer
            // trailer bytes go at body positions 12/13 conceptually, but our
            // body array is 12 wide; extend it via two extra send_byte calls.
            // The CRC covers bytes 0..11 (DEST..opB last byte).
            if (corrupt_payload) body[5] = 8'h61;  // corrupt opA byte
            // send header + payload
            for (k = 0; k < 12; k = k + 1)
                send_byte(body[k], 1'b0, (k == 0));
            // send the CRC trailer computed over the *uncorrupted* body
            send_byte(g[15:8], 1'b0, 1'b0);
            send_byte(g[7:0], 1'b1, 1'b0);
            s_valid = 0;
            // wait for the result
            repeat (40) @(posedge clk); #1;
        end
    endtask

    initial begin
        m_ready = 1;
        s_valid = 0; s_data = 0; s_last = 0; s_start = 0;
        @(posedge clk); #1;
        rst_n = 0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1;

        // ---- flit 1: good CRC, expect result 6.0 and no corrupt pulse ----
        capn = 0;
        send_flit(0);
        $display("--- flit 1 (good CRC) ---");
        $write("captured:");
        for (i2 = 0; i2 < capn; i2 = i2 + 1) $write(" %02x", cap[i2]);
        $display("");
        $display("corrupt_out = %0b (expect 0)", corrupt_out);
        if (capn >= 8 && cap[4] == 8'h40 && cap[5] == 8'hc0
            && cap[6] == 8'h00 && cap[7] == 8'h00) begin
            $display("PASS: result = 0x40C00000 (6.0) at frame bytes 4-7");
        end else begin
            $display("FAIL: result != 0x40C00000 (6.0) at frame bytes 4-7");
            errors = errors + 1;
        end
        if (corrupt_out === 1'b0) begin
            $display("PASS: corrupt_out stays 0 on good CRC");
        end else begin
            $display("FAIL: corrupt_out pulsed on good CRC");
            errors = errors + 1;
        end
        // output-frame CRC self-check: trailer (bytes 8-9) must equal the
        // CRC-16 over the emitted body (bytes 0-7)
        begin
            ocov = 0;
            for (ok2 = 0; ok2 < 8; ok2 = ok2 + 1) ocov[ok2*8 +: 8] = cap[ok2];
            ocrc = crc16(ocov, 8);
            if (capn >= 10 && cap[8] == ocrc[15:8] && cap[9] == ocrc[7:0]) begin
                $display("PASS: output trailer CRC %02x%02x is correct", cap[8], cap[9]);
            end else begin
                $display("FAIL: output trailer CRC wrong (got %02x%02x, want %02x%02x)",
                    cap[8], cap[9], ocrc[15:8], ocrc[7:0]);
                errors = errors + 1;
            end
        end

        // ---- flit 2: corrupted payload (trailer mismatches), expect corrupt ----
        capn = 0;
        send_flit(1);
        $display("--- flit 2 (bad CRC) ---");
        $write("captured:");
        for (i2 = 0; i2 < capn; i2 = i2 + 1) $write(" %02x", cap[i2]);
        $display("");
        $display("corrupt_out = %0b (expect 1)", corrupt_out);
        if (corrupt_out === 1'b1) begin
            $display("PASS: corrupt_out pulsed on bad CRC");
        end else begin
            $display("FAIL: corrupt_out never pulsed on bad CRC (C2 dead path)");
            errors = errors + 1;
        end

        if (errors == 0) $display("*** C2/S1 DETECTOR PASS ***");
        else            $display("*** C2/S1 DETECTOR FAIL: %0d errors ***", errors);
        $finish;
    end
endmodule