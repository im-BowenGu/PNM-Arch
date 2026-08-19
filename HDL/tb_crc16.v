`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// tb_crc16 — standalone CRC-16/CCITT-FALSE testbench
//
// Verifies the hardware CRC engine against known test vectors.
// =============================================================================

module tb_crc16;
    reg  [15:0] crc_in;
    reg  [7:0]  data_in;
    wire [15:0] crc_out;

    crc16 uut (
        .crc_in  (crc_in),
        .data_in (data_in),
        .crc_out (crc_out)
    );

    integer errors;

    initial begin
        $dumpfile("tb_crc16.vcd");
        $dumpvars(0, tb_crc16);
        errors = 0;

        // Test 1: CRC of "123456789" = 0x29B1 (well-known CRC-16/CCITT-FALSE)
        $display("[TB] Test 1: CRC-123456789");
        crc_in = 16'hFFFF;
        data_in = 8'h31; #1; crc_in = crc_out; // '1'
        data_in = 8'h32; #1; crc_in = crc_out; // '2'
        data_in = 8'h33; #1; crc_in = crc_out; // '3'
        data_in = 8'h34; #1; crc_in = crc_out; // '4'
        data_in = 8'h35; #1; crc_in = crc_out; // '5'
        data_in = 8'h36; #1; crc_in = crc_out; // '6'
        data_in = 8'h37; #1; crc_in = crc_out; // '7'
        data_in = 8'h38; #1; crc_in = crc_out; // '8'
        data_in = 8'h39; #1;                   // '9'
        if (crc_out !== 16'h29B1) begin
            $display("[TB] FAIL: got %04h, expected 29B1", crc_out);
            errors = errors + 1;
        end else
            $display("[TB] PASS: CRC-123456789 = 29B1");

        // Test 2: Incremental CRC — CRC(init, A||B) == CRC(CRC(init, A), B)
        $display("[TB] Test 2: Incremental CRC");
        // Full: CRC(0xFFFF, "123456789A")
        crc_in = 16'hFFFF;
        data_in = 8'h31; #1; crc_in = crc_out;
        data_in = 8'h32; #1; crc_in = crc_out;
        data_in = 8'h33; #1; crc_in = crc_out;
        data_in = 8'h34; #1; crc_in = crc_out;
        data_in = 8'h35; #1; crc_in = crc_out;
        data_in = 8'h36; #1; crc_in = crc_out;
        data_in = 8'h37; #1; crc_in = crc_out;
        data_in = 8'h38; #1; crc_in = crc_out;
        data_in = 8'h39; #1; crc_in = crc_out;
        data_in = 8'h41; #1;                   // 'A'
        begin : t2
            reg [15:0] full_result;
            full_result = crc_out;
            // Incremental: CRC(0x29B1, "A")
            crc_in = 16'h29B1;
            data_in = 8'h41; #1;
            if (crc_out !== full_result) begin
                $display("[TB] FAIL: incremental mismatch: %04h vs %04h", crc_out, full_result);
                errors = errors + 1;
            end else
                $display("[TB] PASS: incremental CRC matches");
        end

        // Test 3: CRC of single 0x00 byte from 0x0000
        $display("[TB] Test 3: CRC(0x0000, 0x00)");
        crc_in = 16'h0000;
        data_in = 8'h00; #1;
        // Computed: 0x0000 ^ 0x0000 = 0x0000, all 8 shifts produce 0x0000
        if (crc_out !== 16'h0000) begin
            $display("[TB] FAIL: got %04h, expected 0000", crc_out);
            errors = errors + 1;
        end else
            $display("[TB] PASS: CRC(0x0000, 0x00) = 0000");

        // Test 4: Determinism — same input produces same output
        $display("[TB] Test 4: Determinism");
        crc_in = 16'hFFFF;
        data_in = 8'hAB; #1;
        begin : t4
            reg [15:0] first;
            first = crc_out;
            crc_in = 16'hFFFF;
            data_in = 8'hAB; #1;
            if (crc_out !== first) begin
                $display("[TB] FAIL: non-deterministic: %04h != %04h", crc_out, first);
                errors = errors + 1;
            end else
                $display("[TB] PASS: deterministic");
        end

        // Test 5: All 0xFF bytes (256 iterations)
        $display("[TB] Test 5: 256x 0xFF");
        crc_in = 16'hFFFF;
        begin : t5
            integer i;
            for (i = 0; i < 256; i = i + 1) begin
                data_in = 8'hFF; #1;
                crc_in = crc_out;
            end
            $display("[TB] INFO: CRC(256xFF) = %04h", crc_out);
        end

        // Test 6: PNM body CRC
        $display("[TB] Test 6: PNM body CRC");
        crc_in = 16'hFFFF;
        data_in = 8'h01; #1; crc_in = crc_out; // DEST
        data_in = 8'h40; #1; crc_in = crc_out; // CTRL
        data_in = 8'h02; #1; crc_in = crc_out; // LEN_LO
        data_in = 8'h00; #1; crc_in = crc_out; // LEN_HI
        data_in = 8'hAA; #1; crc_in = crc_out; // payload[0]
        data_in = 8'hBB; #1;                   // payload[1]
        begin : t6
            reg [15:0] pnm_crc;
            pnm_crc = crc_out;
            $display("[TB] INFO: PNM body CRC = %04h", pnm_crc);
            if (pnm_crc == 16'h0000 || pnm_crc == 16'hFFFF) begin
                $display("[TB] FAIL: trivial CRC %04h", pnm_crc);
                errors = errors + 1;
            end else
                $display("[TB] PASS: PNM body CRC non-trivial");
        end

        // Summary
        if (errors == 0)
            $display("*** CRC16 TEST PASSED ***");
        else
            $display("*** CRC16 TEST FAILED (%0d errors) ***", errors);
        #1;
        $finish;
    end

    initial begin #50000; $display("TIMEOUT"); $finish(1); end
endmodule
