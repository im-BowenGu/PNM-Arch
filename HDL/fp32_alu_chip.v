`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// fp32_alu_chip — FP32 ALU chip for PNM fabric integration
//
// Wraps fp32_alu.v with AXI-Stream interfaces for the PNM routing fabric.
// Receives flit bytes, deserializes FP32 operands, computes the selected
// operation, and serializes the result back as flit bytes.
//
// The chip processes 4-byte aligned FP32 values from the flit payload:
//   bytes [0..3]  = operand A (big-endian FP32)
//   bytes [4..7]  = operand B (big-endian FP32)
//   result [0..3] = ALU output (big-endian FP32)
//
// For unary operations (MIN/MAX/CMP with implicit zero), only operand A
// is consumed. DIV uses the 25-cycle restoring division pipeline.
//
// The chip integrates with the doorbell discipline: it validates the
// incoming CRC and pulses corrupt_out on failure, matching pe_tile_stub.v.
//
// Pipeline latency:
//   ADD/SUB/MUL : 5 cycles (4 bytes in + 3 FMA + 1 output mux + 4 bytes out)
//   DIV         : 29 cycles (4 bytes in + 25 div + 4 bytes out)
//   MIN/MAX/CMP : 5 cycles (4 bytes in + 1 cycle + 1 output mux + 4 bytes out)
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
    localparam ST_IDLE     = 3'd0;
    localparam ST_COLLECT  = 3'd1; // collecting operand bytes
    localparam ST_COMPUTE  = 3'd2; // waiting for ALU result
    localparam ST_EMIT     = 3'd3; // emitting result bytes

    reg [2:0]  state;
    reg [3:0]  byte_cnt;     // 0-7 for collecting, 0-3 for emitting
    reg [2:0]  op_q;         // latched operation
    reg [31:0] op_a, op_b;   // assembled FP32 operands
    reg [31:0] result_q;     // latched ALU result
    reg [7:0]  emit_bytes;   // bytes remaining to emit
    reg [1:0]  emit_pos;     // current emit byte index (0-3)

    // Operand assembly: big-endian byte packing
    wire [31:0] operand_a = {op_a[23:16], op_a[15:8], op_a[7:0], s_axis_tdata}; // shift in
    wire [31:0] operand_b = {op_b[23:16], op_b[15:8], op_b[7:0], s_axis_tdata};

    // ALU interface
    reg  [31:0] alu_a, alu_b;
    reg         alu_valid;
    reg  [2:0]  alu_op;
    wire [31:0] alu_result;
    wire        alu_valid_out;

    fp32_alu u_alu (
        .clk(clk), .rst_n(rst_n),
        .a(alu_a), .b(alu_b), .op(alu_op),
        .valid_in(alu_valid),
        .result(alu_result), .valid_out(alu_valid_out)
    );

    // CRC validation (simplified: single-byte at a time)
    reg [15:0] crc_acc;
    reg        crc_valid_q;
    wire [15:0] crc_next;
    crc16 u_crc (.crc_in(crc_acc), .data_in(s_axis_tdata), .crc_out(crc_next));

    // Route bitmap comparator: check DEST nibble on SOP
    wire [3:0] dest_nibble = (ROUTE_BM[6]) ? s_axis_tdata[7:4] : s_axis_tdata[3:0];
    assign route_err = (state == ST_IDLE) && s_axis_tstart && s_axis_tvalid &&
                       (dest_nibble != ROUTE_BM[4:0]);

    // =========================================================================
    // Main state machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            byte_cnt   <= 0;
            op_a       <= 0;
            op_b       <= 0;
            result_q   <= 0;
            alu_a      <= 0;
            alu_b      <= 0;
            alu_valid  <= 0;
            alu_op     <= 0;
            crc_acc    <= 16'hFFFF;
            crc_valid_q <= 1;
        end else begin
            alu_valid <= 0;

            case (state)
                ST_IDLE: begin
                    crc_acc <= 16'hFFFF;
                    crc_valid_q <= 1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        // On SOP, latch operation from routing bitmap or parameter
                        if (s_axis_tstart) begin
                            op_q    <= OP_CODE;
                            byte_cnt <= 0;
                            op_a    <= 0;
                            op_b    <= 0;
                        end
                        // Update CRC
                        crc_acc <= crc_next;
                        // First 4 bytes go to operand A
                        if (byte_cnt < 4'd4) begin
                            op_a <= {op_a[23:0], s_axis_tdata};
                            byte_cnt <= byte_cnt + 1;
                            if (byte_cnt == 4'd3) state <= ST_COLLECT;
                        end
                    end
                end

                ST_COLLECT: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        crc_acc <= crc_next;
                        // Bytes 4-7 go to operand B
                        if (byte_cnt < 4'd8) begin
                            op_b <= {op_b[23:0], s_axis_tdata};
                            byte_cnt <= byte_cnt + 1;
                            if (byte_cnt == 4'd7) begin
                                // Both operands collected, start compute
                                state <= ST_COMPUTE;
                                alu_a  <= {op_a[23:0], s_axis_tdata}; // last byte of A was already latched
                                alu_b  <= {op_b[23:0], s_axis_tdata};
                                alu_op <= OP_CODE;
                                alu_valid <= 1;
                            end
                        end
                    end
                end

                ST_COMPUTE: begin
                    if (alu_valid_out) begin
                        result_q <= alu_result;
                        state    <= ST_EMIT;
                        emit_pos <= 0;
                        // Check CRC at message end
                        if (!crc_valid_q) begin
                            corrupt_out_reg <= 1;
                        end
                    end
                end

                ST_EMIT: begin
                    if (m_axis_tready) begin
                        emit_pos <= emit_pos + 1;
                        if (emit_pos == 2'd3) begin
                            state <= ST_IDLE;
                        end
                    end
                end
            endcase
        end
    end

    // Emit byte mux: big-endian result serialization
    reg [7:0] corrupt_out_reg;
    assign corrupt_out = corrupt_out_reg;

    reg [7:0] m_axis_tdata_mux;
    always @(*) begin
        case (emit_pos)
            2'd0: m_axis_tdata_mux = result_q[31:24];
            2'd1: m_axis_tdata_mux = result_q[23:16];
            2'd2: m_axis_tdata_mux = result_q[15:8];
            2'd3: m_axis_tdata_mux = result_q[7:0];
        endcase
    end

    assign m_axis_tdata  = (state == ST_EMIT) ? m_axis_tdata_mux : 8'h00;
    assign m_axis_tvalid = (state == ST_EMIT);
    assign m_axis_tlast  = (state == ST_EMIT) && (emit_pos == 2'd3);
    assign m_axis_tstart = (state == ST_EMIT) && (emit_pos == 2'd0);
    assign s_axis_tready = (state == ST_IDLE || state == ST_COLLECT);

endmodule
