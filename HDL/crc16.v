`include "pnm_defs.vh"

// =============================================================================
// crc16 — CRC-16/CCITT-FALSE byte-wise engine (Paper §2.9, §2.10)
//
// The reference implementation is sim/virtual_units.py crc16(): init 0xFFFF,
// polynomial 0x1021, no final XOR, bytes fed MSB-first.  This Verilog module
// is its hardware twin, used by the doorbell (doorbell.v) to validate the
// end-to-end CRC over [DEST, CTRL, LEN_LO, LEN_HI, payload].
//
// crc16 is purely combinational: feed crc_in and the next data byte, get the
// updated CRC on crc_out.  A streaming FSM keeps the running value in a
// register and re-circulates it here.
// =============================================================================
module crc16 (
    input  wire [15:0] crc_in,
    input  wire [7:0]  data_in,
    output wire [15:0] crc_out
);
    function automatic [15:0] crc16_update;
        input [15:0] crc_val;
        input [7:0]  byte_val;
        integer i;
        reg [15:0] c;
        begin
            c = crc_val ^ (byte_val << 8);
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16_update = c;
        end
    endfunction

    assign crc_out = crc16_update(crc_in, data_in);
endmodule
