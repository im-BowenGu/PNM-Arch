`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// fp32_alu_chip — FP32 ALU chip for PNM fabric integration
//
// Wraps fp32_alu.v with AXI-Stream interfaces for the PNM routing fabric.
// Receives a fabric flit, deserializes two FP32 operands from the payload,
// computes the selected operation, validates the incoming CRC (doorbell
// discipline, matching pe_tile_stub.v), and serializes the result back as a
// new flit with a recomputed CRC.
//
// Input flit body (the lxy_repeater has already stripped LAYER_ID):
//   byte 0        : MODULE_ID (DEST) — forwarded to the output frame
//   byte 1        : CTRL         — forwarded to the output frame
//   bytes 2-3     : LEN_LO/LEN_HI — payload length (LEN >= 8 required)
//   bytes 4..11   : payload = operand A (big-endian FP32) then
//                   operand B (big-endian FP32)
//   last 2 bytes  : CRC_HI/CRC_LO — CRC-16/CCITT-FALSE over
//                   [MODULE_ID .. last payload byte]
//   A mismatch between the trailer and the recomputed CRC pulses corrupt_out.
//
// Output flit body (result frame):
//   byte 0        : MODULE_ID (DEST) — echoed from the input
//   byte 1        : CTRL             — echoed from the input
//   bytes 2-3     : LEN_LO=04 LEN_HI=00
//   bytes 4..7    : result (big-endian FP32)
//   last 2 bytes  : CRC_HI/CRC_LO over [MODULE_ID .. result last byte]
//
// For unary operations (MIN/MAX/CMP with implicit zero) only operand A is
// consumed. DIV uses the 28-cycle restoring division pipeline.
//
// Parameters:
//   OP_CODE    : ALU operation (0=ADD, 1=SUB, 2=MUL, 3=DIV, 4=MIN, 5=MAX, 7=CMP)
//   ROUTE_BM   : 11-bit routing bitmap for this node
//   MODULE_ID  : this node's 8-bit coordinate {X[3:0], Y[3:0]}
// =============================================================================

module fp32_alu_chip #(
    parameter [2:0]  OP_CODE    = 3'd0,      // ALU operation select
    parameter [10:0] ROUTE_BM   = 11'h000,   // routing bitmap
    parameter [7:0]  MODULE_ID  = 8'h00      // node coordinate
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream slave — incoming flit from fabric
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tstart,

    // AXI-Stream master — computed result
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tstart,

    // Status
    output wire        route_err,
    output wire        corrupt_out
);

    // =========================================================================
    // State machine
    // =========================================================================
    localparam ST_IDLE     = 3'd0; // waiting for flit SOP
    localparam ST_COLLECT  = 3'd1; // collecting header + payload + CRC body
    localparam ST_COMPUTE  = 3'd2; // waiting for ALU result
    localparam ST_EMIT     = 3'd3; // emitting result flit

    reg [2:0] state;
    reg [15:0] pos;          // delivered body byte position (0 = MODULE_ID)
    reg [15:0] plen;         // payload length latched from LEN_LO/HI
    reg [31:0] op_a, op_b;   // assembled FP32 operands (payload bytes)
    reg [31:0] result_q;     // latched ALU result
    reg [31:0] alu_a, alu_b;
    reg        alu_valid;
    reg [2:0]  alu_op;
    reg [7:0]  dst_q;        // echoed MODULE_ID (DEST)
    reg [7:0]  ctrl_q;       // echoed CTRL
    reg [15:0] crc_in_acc;   // CRC over the incoming body (doorbell check)
    reg        crc_mismatch_q;
    reg        corrupt_q;    // registered verdict, cleared at the next flit SOP
    reg [15:0] crc_out_acc;  // CRC over the emitted result body
    reg [7:0]  res_b [0:3];  // result bytes (0 = MSB, big-endian)
    reg [3:0]  out_cnt;      // output frame byte count (0..10)
    reg        out_active;

    // Route bitmap comparator: check DEST nibble on SOP
    wire [3:0] dest_nibble =
        (ROUTE_BM[6]) ? s_axis_tdata[7:4] : s_axis_tdata[3:0];
    assign route_err = (state == ST_IDLE) && s_axis_tstart && s_axis_tvalid &&
                       (dest_nibble != ROUTE_BM[4:0]);

    // ALU interface
    wire [31:0] alu_result;
    wire        alu_valid_out;

    fp32_alu u_alu (
        .clk(clk), .rst_n(rst_n),
        .a(alu_a), .b(alu_b), .op(alu_op),
        .valid_in(alu_valid),
        .result(alu_result), .valid_out(alu_valid_out)
    );

    // CRC units
    wire [15:0] crc_in_upd, crc_out_upd;
    crc16 u_crc_in  (.crc_in(crc_in_acc),  .data_in(s_axis_tdata),
                     .crc_out(crc_in_upd));
    crc16 u_crc_out (.crc_in(crc_out_acc), .data_in(m_axis_tdata),
                     .crc_out(crc_out_upd));

    wire deliver      = s_axis_tvalid && s_axis_tready;
    wire in_payload   = (pos >= 16'd4 && pos < 4 + plen);
    wire crc_hi_byte  = (pos == 4 + plen);
    wire crc_lo_byte  = (pos == 4 + plen + 1);

    // =========================================================================
    // Slave-side state machine: capture header, collect operands, validate CRC
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            pos            <= 16'd0;
            plen           <= 16'd0;
            op_a           <= 32'd0;
            op_b           <= 32'd0;
            alu_a          <= 32'd0;
            alu_b          <= 32'd0;
            alu_valid      <= 1'b0;
            alu_op         <= 3'd0;
            dst_q          <= 8'h00;
            ctrl_q         <= 8'h00;
            crc_in_acc     <= 16'hFFFF;
            crc_mismatch_q <= 1'b0;
            corrupt_q      <= 1'b0;
            crc_out_acc    <= 16'hFFFF;
            out_cnt        <= 4'd0;
            out_active     <= 1'b0;
        end else begin
            alu_valid <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (deliver) begin
                        // new flit: reset the CRC verdict and counters.
                        // The first body byte (MODULE_ID/DEST) feeds the CRC:
                        // coverage is [MODULE_ID .. last payload byte], so the
                        // trailer is excluded but the header is included.
                        corrupt_q      <= corrupt_q;   // hold verdict until
                                                       // ST_COMPUTE pulses it
                        pos            <= 16'd1;
                        plen           <= 16'd0;
                        crc_in_acc     <= crc_in_upd;  // CRC over MODULE_ID
                        crc_mismatch_q <= 1'b0;
                        dst_q          <= s_axis_tdata;
                        state          <= ST_COLLECT;
                    end
                end

                ST_COLLECT: begin
                    if (deliver) begin
                        if (!crc_hi_byte && !crc_lo_byte)
                            crc_in_acc <= crc_in_upd;
                        if (pos == 16'd1) begin
                            ctrl_q <= s_axis_tdata;
                        end else if (pos == 16'd2) begin
                            plen[7:0] <= s_axis_tdata;
                        end else if (pos == 16'd3) begin
                            plen[15:8] <= s_axis_tdata;
                        end else if (pos >= 16'd4 && pos < 4 + plen) begin
                            if (pos < 16'd8)       // operand A: bytes 4..7
                                op_a <= {op_a[23:0], s_axis_tdata};
                            else if (pos < 16'd12) // operand B: bytes 8..11
                                op_b <= {op_b[23:0], s_axis_tdata};
                        end
                        if (crc_hi_byte)
                            crc_mismatch_q <= (s_axis_tdata != crc_in_acc[15:8]);
                        else if (crc_lo_byte) begin
                            crc_mismatch_q <= crc_mismatch_q
                                           || (s_axis_tdata != crc_in_acc[7:0]);
                            // fire the ALU at the end of the flit
                            if (plen >= 16'd8) begin
                                alu_a     <= op_a;
                                alu_b     <= op_b;
                                alu_op    <= OP_CODE;
                                alu_valid <= 1'b1;
                                state     <= ST_COMPUTE;
                            end else begin
                                state     <= ST_IDLE;
                            end
                        end
                        if (s_axis_tlast && !crc_hi_byte && !crc_lo_byte) begin
                            // malformed flit: ended before the CRC trailer
                            crc_mismatch_q <= 1'b1;
                            crc_in_acc     <= 16'hFFFF;
                            state          <= ST_IDLE;
                        end
                        pos <= pos + 16'd1;
                    end
                end

                ST_COMPUTE: begin
                    if (alu_valid_out) begin
                        result_q  <= alu_result;
                        res_b[0]  <= alu_result[31:24];
                        res_b[1]  <= alu_result[23:16];
                        res_b[2]  <= alu_result[15:8];
                        res_b[3]  <= alu_result[7:0];
                        corrupt_q  <= crc_mismatch_q;
                        crc_out_acc <= 16'hFFFF;
                        out_cnt     <= 4'd0;
                        out_active  <= 1'b1;
                        state       <= ST_EMIT;
                    end
                end

                ST_EMIT: begin
                    if (m_axis_tready) begin
                        if (out_cnt < 4'd8)   // header + result body bytes
                            crc_out_acc <= crc_out_upd;
                        out_cnt <= out_cnt + 4'd1;
                        if (out_cnt == 4'd9) begin
                            out_active <= 1'b0;
                            // clear the CRC verdict once the result frame
                            // has drained, so the next flit starts clean
                            // (corrupt_q holds until ST_IDLE re-arms it)
                            crc_in_acc <= 16'hFFFF;  // re-arm for the next flit
                            state      <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Master-side output frame mux
    // =========================================================================
    reg [7:0] m_axis_tdata_mux;
    always @(*) begin
        case (out_cnt)
            4'd0: m_axis_tdata_mux = dst_q;          // MODULE_ID (DEST)
            4'd1: m_axis_tdata_mux = ctrl_q;         // CTRL
            4'd2: m_axis_tdata_mux = 8'h04;          // LEN_LO (4 result bytes)
            4'd3: m_axis_tdata_mux = 8'h00;          // LEN_HI
            4'd4: m_axis_tdata_mux = res_b[0];
            4'd5: m_axis_tdata_mux = res_b[1];
            4'd6: m_axis_tdata_mux = res_b[2];
            4'd7: m_axis_tdata_mux = res_b[3];
            4'd8: m_axis_tdata_mux = crc_out_acc[15:8];
            4'd9: m_axis_tdata_mux = crc_out_acc[7:0];
            default: m_axis_tdata_mux = 8'h00;
        endcase
    end

    assign m_axis_tdata  = (state == ST_EMIT) ? m_axis_tdata_mux : 8'h00;
    assign m_axis_tvalid = (state == ST_EMIT);
    assign m_axis_tlast  = (state == ST_EMIT) && (out_cnt == 4'd9);
    assign m_axis_tstart = (state == ST_EMIT) && (out_cnt == 4'd0);
    assign corrupt_out   = corrupt_q;
    assign s_axis_tready = (state == ST_IDLE || state == ST_COLLECT);

endmodule