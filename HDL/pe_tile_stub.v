`include "pnm_defs.vh"

// =============================================================================
// pe_tile_stub — Processing Element (PE) tile: the node's MAC array, in Verilog
//
// The hardware fabric decouples transport from computation: the deterministic
// repeater network connects to a modular PE interface via standard AXI-Stream /
// Ready-Valid handshaking, so the underlying execution block (systolic array,
// FP16 MAC array, or ALU) can be swapped independently of the routing fabric.
// This stub *is* that interface contract, in Verilog.
//
// It consumes one flit byte per clock on its slave port (s_axis_*), holds it
// in an elastic pipe for MULT_LATENCY clock cycles — the modelled
// multiply-accumulate latency — then re-presents it on the master port
// (m_axis_*).  It owns exactly two handshake flags: s_axis_tready (the pipe
// can accept a byte) and m_axis_tvalid (a result byte is present).
//
// Computation (this revision): the stub performs the node's resident kernel —
// an element-wise bias add, KERNEL_CONST — on the payload of every message,
// and it runs the CRC half of the doorbell discipline in hardware (Paper §2.9):
//
//   * DEST, CTRL, LEN bytes pass through untouched
//   * payload byte i becomes (payload[i] + KERNEL_CONST) mod 256
//   * the trailing CRC bytes are replaced by CRC-16/CCITT-FALSE over
//     [DEST, CTRL, LEN_LO, LEN_HI, payload'] (computed in flight via crc16.v,
//     the hardware twin of sim/virtual_units.py crc16())
//   * the *incoming* CRC (over the unmodified body) is validated as it
//     streams; on failure, corrupt_out pulses for one cycle on the last CRC
//     byte — the hardware doorbell verdict, which the co-sim records as a
//     refusal (the bytes still stream out so accounting stays lossless)
//   * on completion of a message whose CTRL rsvd[0] return flag is set, the
//     transmit DMA (the reverse half of the doorbell engine, paper §2.9)
//     re-emits the transformed DMA bytes as a result flit on the m_axis_tx
//     master: DEST rewritten to the AOT-fixed requester REQ_MODULE, origin
//     class 0 (board egress, paper §4.3), return flag cleared, CRC recomputed
//     over the new body.  While the echo emits, the forward pipe is stalled:
//     a single DMA engine serializes egress.
//
// With KERNEL_CONST=0 the recomputed CRC equals the incoming CRC, so every
// byte is reproduced exactly and the default behaviour is a byte-exact pipe:
// existing testbenches observe no change.
//
// MULT_LATENCY: 1 or 2 clock cycles (the paper's approximate MAC latency,
// Section 2.9).  Default 2.
//
// Routing bitmap: each node is programmed with its routing-table entry at
// boot (paper §2.1/§2.8), exactly like its resident kernel and weights:
//   [10:7] LAYER : 4-bit layer ID, 1-based
//   [6]    AXIS  : 0 = X, 1 = Y
//   [5]    SIGN  : 0 = +, 1 = -
//   [4:0]  DIST  : hop distance from the xyz_repeater
// A bit-mask comparator checks every packet head: the DEST nibble selected by
// AXIS must equal DIST, so a flit whose coordinate is inconsistent with the
// node's routing entry is flagged (route_err) without disturbing the pipe.
// =============================================================================
module pe_tile_stub #(
    parameter integer MULT_LATENCY = 2,    // 1 or 2 cycles of multiply latency
    parameter [7:0]   KERNEL_CONST  = 8'h00, // resident bias-add constant
    parameter integer TX_BUF        = 2048,  // max payload captured for the TX echo
    parameter [7:0]   REQ_MODULE    = 8'hEE  // AOT-fixed requester (spine root)
)(
    input  wire        clk,
    input  wire        rst_n,

    // routing bitmap — the node's pre-loaded routing-table entry
    input  wire [10:0] routing_bitmap,

    // AXI-Stream slave — incoming flit from the node DMA port
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tstart,

    // AXI-Stream master — the computed result flit
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tstart,

    // AXI-Stream master — the TX echo (result egress, paper §2.9)
    output wire [7:0]  m_axis_tx_tdata,
    output wire        m_axis_tx_tvalid,
    input  wire        m_axis_tx_tready,
    output wire        m_axis_tx_tlast,
    output wire        m_axis_tx_tstart,
    output wire [1:0]  tx_vc,              // class 0: board egress
    // route-consistency flag (bit-mask comparator output): pulses on a
    // packet head byte whose DEST nibble, selected by AXIS, differs from
    // DIST.  LAYER and SIGN cannot be re-checked here: LAYER_ID was
    // stripped at the xyz_repeater and the DMA stream carries no direction.
    output wire        route_err,
    // hardware doorbell verdict: one-cycle pulse when the incoming
    // end-to-end CRC of the streamed message failed to validate
    output wire        corrupt_out
);

    // -- elastic MAC-latency pipe -----------------------------------------
    // stage 1 feeds the master port and is always present; stage 0 adds the
    // second cycle when MULT_LATENCY >= 2.  Each stage is a classic
    // depth-1 elastic buffer (c.f. hfr.v): it accepts its upstream byte
    // whenever its downstream is ready or its own slot is empty, so the pipe
    // fills with the input stream and stalls in place under backpressure.
    // The whole pipe freezes while the TX echo emits (one DMA engine).
    reg [7:0] s0_data, s1_data;
    reg       s0_valid, s1_valid;
    reg       s0_last,  s1_last;
    reg       s0_start, s1_start;

    // -- TX echo state (paper §2.9 result egress) -------------------------
    // On a message whose CTRL rsvd[0] return flag is set, capture the
    // transformed payload bytes as they pass the deliver point, then re-emit
    // [REQ_MODULE, ctrl', LEN, payload', CRC'] on m_axis_tx: DEST rewritten
    // to the AOT-fixed requester, origin class 0, return flag cleared, CRC
    // recomputed over the new body.
    reg [7:0]  tx_buf [0:TX_BUF-1];
    reg [15:0] tx_buf_wr;            // capture write index
    reg        tx_ret_q;             // return flag of the message in the pipe
    reg [7:0]  tx_ctrl_q;            // its CTRL op bits (class/rsvd cleared)
    reg        tx_emit_q;            // echo emitter active
    reg [15:0] tx_len_q;             // payload length of the echoed message
    reg [15:0] tx_pos_q;             // emitter byte index
    reg [15:0] tx_crc_q;             // emitter CRC accumulator
    wire [15:0] tx_crc_end = 16'd4 + tx_len_q;
    wire [15:0] tx_end     = tx_crc_end + 16'd1;
    wire [7:0]  tx_data =
        (tx_pos_q == 16'd0)          ? REQ_MODULE
      : (tx_pos_q == 16'd1)          ? tx_ctrl_q
      : (tx_pos_q == 16'd2)          ? tx_len_q[7:0]
      : (tx_pos_q == 16'd3)          ? tx_len_q[15:8]
      : (tx_pos_q < tx_crc_end)      ? tx_buf[tx_pos_q[10:0] - 11'd4]
      : (tx_pos_q == tx_crc_end)     ? tx_crc_q[15:8]
      :                                tx_crc_q[7:0];
    wire [15:0] tx_crc_upd;
    crc16 u_tx_crc (.crc_in(tx_crc_q), .data_in(tx_data), .crc_out(tx_crc_upd));
    wire tx_adv = tx_emit_q && m_axis_tx_tready;

    assign tx_vc = `VC_BOARD_EGRESS;
    assign m_axis_tx_tdata  = tx_data;
    assign m_axis_tx_tvalid = tx_emit_q;
    assign m_axis_tx_tlast  = tx_emit_q && (tx_pos_q == tx_end);
    assign m_axis_tx_tstart = tx_emit_q && (tx_pos_q == 16'd0);

    // the pipe freezes while the echo emits, so 'deliver' (the accounting
    // clock) includes the echo gate
    wire deliver = s1_valid && m_axis_tready && !tx_emit_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_emit_q <= 1'b0;
            tx_pos_q  <= 16'd0;
            tx_crc_q  <= 16'hFFFF;
        end else begin
            if (deliver && s1_last && tx_ret_q) begin
                tx_emit_q <= 1'b1;             // start the echo next cycle
                tx_pos_q  <= 16'd0;
                tx_crc_q  <= 16'hFFFF;
            end else if (tx_adv && (tx_pos_q == tx_end)) begin
                tx_emit_q <= 1'b0;
            end else if (tx_adv) begin
                tx_pos_q <= tx_pos_q + 16'd1;
                if (tx_pos_q < tx_crc_end) tx_crc_q <= tx_crc_upd;
            end
        end
    end

    wire s1_ready = (m_axis_tready || !s1_valid) && !tx_emit_q;
    wire s0_ready = (s1_ready || !s0_valid) && !tx_emit_q;

    assign s_axis_tready = (MULT_LATENCY >= 2) ? s0_ready : s1_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_data  <= 8'h00;  s1_valid <= 1'b0;  s1_last <= 1'b0;  s1_start <= 1'b0;
            s0_data  <= 8'h00;  s0_valid <= 1'b0;  s0_last <= 1'b0;  s0_start <= 1'b0;
        end else begin
            if (s1_ready) begin
                s1_data  <= (MULT_LATENCY >= 2) ? s0_data  : s_axis_tdata;
                s1_valid <= (MULT_LATENCY >= 2) ? s0_valid : s_axis_tvalid;
                s1_last  <= (MULT_LATENCY >= 2) ? s0_last  : s_axis_tlast;
                s1_start <= (MULT_LATENCY >= 2) ? s0_start : s_axis_tstart;
            end
            if (MULT_LATENCY >= 2 && s0_ready) begin
                s0_data  <= s_axis_tdata;
                s0_valid <= s_axis_tvalid;
                s0_last  <= s_axis_tlast;
                s0_start <= s_axis_tstart;
            end
        end
    end

    // -- compute + CRC tracking at the pipe output -------------------------
    // The DMA body is [DEST, CTRL, LEN_LO, LEN_HI, payload(len), CRC_HI,
    // CRC_LO]; 'pos' counts delivered body bytes, 'plen' is the payload
    // length latched from LEN_LO/LEN_HI as they pass.
    reg [15:0] pos;
    reg [15:0] plen;
    reg [15:0] crc_in_acc;     // CRC over the *unmodified* body (incoming check)
    reg [15:0] crc_out_acc;    // CRC over the *transformed* body (recomputed)
    reg        crc_mismatch_q; // incoming CRC_HI/LO comparison latch

    // the computed result byte: bias-add on payload, recomputed CRC on tail
    wire [7:0] out_byte =
        (pos >= 4 && pos < 4 + plen) ? (s1_data + KERNEL_CONST)
      : (pos == 4 + plen)            ? crc_out_acc[15:8]
      : (pos == 4 + plen + 1)        ? crc_out_acc[7:0]
      :                                s1_data;

    wire [15:0] crc_in_upd, crc_out_upd;
    crc16 u_crc_in  (.crc_in(crc_in_acc),  .data_in(s1_data),  .crc_out(crc_in_upd));
    crc16 u_crc_out (.crc_in(crc_out_acc), .data_in(out_byte), .crc_out(crc_out_upd));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos            <= 16'd0;
            plen           <= 16'd0;
            crc_in_acc     <= 16'hFFFF;
            crc_out_acc    <= 16'hFFFF;
            crc_mismatch_q <= 1'b0;
            tx_buf_wr      <= 16'd0;
            tx_ret_q       <= 1'b0;
            tx_ctrl_q      <= 8'h00;
        end else if (deliver) begin
            if (s1_last) begin                 // end of message: re-arm
                pos         <= 16'd0;
                crc_in_acc  <= 16'hFFFF;
                crc_out_acc <= 16'hFFFF;
            end else begin
                pos <= pos + 16'd1;
                if (pos == 16'd2)          plen[7:0]  <= s1_data;
                if (pos == 16'd3)          plen[15:8] <= s1_data;
                if (pos <= 4 + plen - 1) begin       // body bytes feed the CRCs
                    crc_in_acc  <= crc_in_upd;
                    crc_out_acc <= crc_out_upd;
                end
                if (pos == 4 + plen)       crc_mismatch_q <= (s1_data != crc_in_acc[15:8]);
                else if (pos == 4 + plen + 1)
                    crc_mismatch_q <= crc_mismatch_q
                                   || (s1_data != crc_in_acc[7:0]);
            end
            // TX echo capture: CTRL op/flag at pos 1, transformed payload
            // bytes as they pass, write pointer rewound at message head
            if (pos == 16'd1) begin
                tx_ret_q  <= s1_data[0];
                tx_ctrl_q <= s1_data & 8'h30;
            end
            if (pos == 16'd0) tx_buf_wr <= 16'd0;
            if (pos >= 16'd4 && pos < 4 + plen) begin
                tx_buf[tx_buf_wr[10:0]] <= out_byte;
                tx_buf_wr <= tx_buf_wr + 16'd1;
            end
            if (s1_last) tx_len_q <= plen;
        end
    end

    // one-cycle registered pulse after the incoming CRC_LO byte has passed
    reg corrupt_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) corrupt_q <= 1'b0;
        else         corrupt_q <= (deliver && pos == 4 + plen + 1)
                               && (crc_mismatch_q || (s1_data != crc_in_acc[7:0]));
    assign corrupt_out = corrupt_q;

    assign m_axis_tdata  = out_byte;
    assign m_axis_tvalid = s1_valid && !tx_emit_q;
    assign m_axis_tlast  = s1_last && !tx_emit_q;
    assign m_axis_tstart = s1_start && !tx_emit_q;

    // -- route-consistency comparator ------------------------------------
    // The DMA stream's first byte is DEST = {X[3:0], Y[3:0]}.  The routing
    // entry says this node sits DIST hops from the xyz_repeater along AXIS
    // (paper §2.2: dimension-order X-then-Y, distances measured from the
    // board ingress), so AXIS=Y (1) checks DEST[3:0], AXIS=X (0) checks
    // DEST[7:4] — the mask-select of the comparator.
    reg first_q;                       // high while the next byte is a head
    always @(posedge clk or negedge rst_n)
        if (!rst_n) first_q <= 1'b1;
        else if (s_axis_tvalid && s_axis_tready)
            first_q <= s_axis_tlast;   // re-arm on EOP

    wire nib_ok = routing_bitmap[`RBM_AXIS]
                ? ({1'b0, s_axis_tdata[3:0]} == routing_bitmap[`RBM_DIST_HI:`RBM_DIST_LO])
                : ({1'b0, s_axis_tdata[7:4]} == routing_bitmap[`RBM_DIST_HI:`RBM_DIST_LO]);
    assign route_err = first_q && s_axis_tvalid && !nib_ok;

endmodule
