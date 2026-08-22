`include "pnm_defs.vh"

// =============================================================================
// doorbell — node DMA engine + hardened doorbell (Paper §2.4, §2.9, §2.10)
//
// Consumes the DMA stream emitted by node_eject.v (or any AXI-Stream source:
// packet framing is the tvalid rising edge, exactly AXI-Stream semantics).
// Since eject forwards the MODULE_ID (no strip), the stream is:
//
//     DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
//
// DEST is the destination coordinate {X[3:0], Y[3:0]} and is *inside* the
// end-to-end CRC coverage: the CRC runs over [DEST, CTRL, LEN_LO, LEN_HI,
// payload], i.e. every byte except the two CRC bytes themselves.
//
// The doorbell fires (DOORBELL_TRIG) only when all three conditions of
// Paper §2.4 hold simultaneously:
//
//   (a) byte count == LEN field + 6 framing bytes,
//   (b) the end-to-end CRC validates,
//   (c) DEST == this node's own coordinate.
//
// DOORBELL_ACK is the single-wire completion: it asserts in the same cycle as
// DOORBELL_TRIG.  When the doorbell refuses — a truncated, corrupt, or
// misdelivered message — ACK is withheld and NODE_ERR asserts, so a loss is
// observable rather than silent (Paper §2.9, §4.1 ACK watchdog).
//
// Frame detection is edge-based on s_valid, not a SOP wire: back-to-back
// packets (valid held high, EOP directly followed by the next DEST byte) are
// handled correctly because in_msg is cleared on the EOP decision edge and
// re-armed on the very next byte.
// =============================================================================
module doorbell #(
    parameter [7:0] LOCAL_MODULE = 8'h00
)(
    input  wire       clk,
    input  wire       rst_n,

    // AXI-Stream slave — DMA stream from the node eject gate
    input  wire [7:0] s_data,
    input  wire       s_valid,
    output wire       s_ready,
    input  wire       s_eop,

    // doorbell status (single-cycle pulses)
    output reg        fire,        // DOORBELL_TRIG: kernel dispatched
    output reg        ack,         // DOORBELL_ACK: completion, same cycle
    output reg        node_err,    // NODE_ERR: refusal (observable loss)
    output reg [31:0] activations, // doorbell fires
    output reg [31:0] rejections   // doorbell refusals
);

    assign s_ready = 1'b1;         // DMA port is a sink; upstream credits gate

    reg [16:0] p;                  // byte index within the current message
    reg [15:0] len;                // latched LEN field (LEN_LO at p=2, LEN_HI at p=3)
    reg [15:0] crc;                // running CRC over [DEST, CTRL, LEN, payload]
    reg [7:0]  dest_l;             // latched DEST byte
    reg [7:0]  crc_hi_r;           // latched first trailing CRC byte
    reg        in_msg;

    wire [15:0] crc_nxt;
    crc16 u_crc (.crc_in(crc), .data_in(s_data), .crc_out(crc_nxt));

    // fresh-start CRC: every message restarts from 0xFFFF and folds DEST in
    wire [15:0] crc_fresh;
    crc16 u_crc_fresh (.crc_in(16'hFFFF), .data_in(s_data), .crc_out(crc_fresh));

    // p < 4                -> header bytes (DEST, CTRL, LEN_LO, LEN_HI): fold
    // 4 <= p < 4+LEN       -> payload: fold
    // 4+LEN <= p <= 5+LEN  -> CRC_HI, CRC_LO: capture, do not fold
    wire [16:0] body_end = 17'd4 + {1'b0, len};   // index of the first CRC byte
    wire [16:0] msg_end  = body_end + 17'd1;     // index of the last CRC byte

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p <= 0; len <= 0; crc <= 16'hFFFF; dest_l <= 8'h00;
            crc_hi_r <= 8'h00; in_msg <= 1'b0;
            fire <= 1'b0; ack <= 1'b0; node_err <= 1'b0;
            activations <= 32'd0; rejections <= 32'd0;
        end else begin
            fire <= 1'b0; ack <= 1'b0; node_err <= 1'b0;

            if (s_valid) begin
                if (!in_msg) begin
                    // ---- WATCH: frame starts on the valid edge ----
                    in_msg <= 1'b1;
                    p      <= 17'd1;      // DEST already consumed at p=0
                    dest_l <= s_data;
                    crc    <= crc_fresh;  // restart CRC from 0xFFFF, fold DEST
                end else if (p < body_end) begin
                    // ---- header (p<4) and payload bytes: fold into CRC ----
                    if (p == 17'd2) len[7:0]  <= s_data;   // LEN_LO
                    if (p == 17'd3) len[15:8] <= s_data;   // LEN_HI
                    crc <= crc_nxt;
                    if (s_eop) begin
                        // EOP in header or payload: truncated message
                        node_err   <= 1'b1;
                        rejections <= rejections + 32'd1;
                        in_msg     <= 1'b0;
                    end else
                        p <= p + 17'd1;
                end else if (p == body_end) begin
                    // ---- first trailing CRC byte (CRC_HI) ----
                    crc_hi_r <= s_data;
                    if (s_eop) begin
                        // only one CRC byte present: malformed
                        node_err   <= 1'b1;
                        rejections <= rejections + 32'd1;
                        in_msg     <= 1'b0;
                    end else
                        p <= p + 17'd1;
                end else begin
                    // ---- second trailing CRC byte (CRC_LO) — decision edge ----
                    in_msg <= 1'b0;
                    // (a) complete framing, (b) CRC validates,
                    // (c) DEST == this node's coordinate
                    if (s_eop && (p == msg_end)
                        && (crc == {crc_hi_r, s_data})
                        && (dest_l == LOCAL_MODULE)) begin
                        fire <= 1'b1;
                        ack  <= 1'b1;
                        activations <= activations + 32'd1;
                    end else begin
                        node_err   <= 1'b1;
                        rejections <= rejections + 32'd1;
                    end
                end
            end
        end
    end

endmodule
