`timescale 1ns/1ps

// =============================================================================
// nvme_ctrl — NVMe Storage Controller for PNM SBC-Class Router Chips
//
// A lightweight NVMe endpoint controller targeting the PNM orchestrator_sbc and
// orchestrator_sbc_moe chips.  Provides block storage to the SoC firmware for:
//   - Model weight persistence (load/store across power cycles)
//   - KV cache overflow to NVMe-backed swap
//   - Lustre FS backing store for distributed filesystem nodes
//   - General-purpose block I/O for the NOMMU Linux/Redox userland
//
// Interface:
//   - AXI-Lite slave for register access (CPU control plane)
//   - AXI-Stream master for DMA data (memory-to/device transfers)
//   - AXI-Stream slave for DMA data (device-to-memory transfers)
//   - Interrupt output (completion doorbell)
//
// Memory map (32-byte register window at base_addr):
//   0x00 : CAP      ( capabilities: queue depth, max transfer size )
//   0x04 : VS       ( version: major.minor.patch )
//   0x08 : CSTS     ( controller status: ready, error, queue depth )
//   0x0C : AQA      ( admin queue attributes: entry count )
//   0x10 : ASQ_LO   ( admin submission queue base addr low )
//   0x14 : ASQ_HI   ( admin submission queue base addr high )
//   0x18 : ACQ_LO   ( admin completion queue base addr low )
//   0x1C : ACQ_HI   ( admin completion queue base addr high )
//   0x20 : CMD_OP   ( command opcode: 0x01=READ, 0x02=WRITE, 0x03=FLUSH )
//   0x24 : CMD_SLBA_LO ( starting LBA low )
//   0x28 : CMD_SLBA_HI ( starting LBA high )
//   0x2C : CMD_NLB  ( number of logical blocks - 1 )
//   0x30 : CMD_BUF_LO  ( DMA buffer base addr low )
//   0x34 : CMD_BUF_HI  ( DMA buffer base addr high )
//   0x38 : STATUS   ( command status: done, error, error code )
//   0x3C : INT_EN   ( interrupt enable mask )
//
// Parameters:
//   MAX_QUEUE_DEPTH : max entries in admin queue (default 64)
//   BLOCK_SIZE      : bytes per logical block (default 512)
//   MAX_TRANSFER    : max bytes per command (default 65536)
//   PAGE_SIZE       : host memory page size in bytes (default 4096)
//
// The controller is behavioral — it models the register protocol and DMA
// handshake but does not implement a real NVMe PHY or PCIe transport.
// Production silicon replaces this with a hard NVMe controller IP block
// connected to the SoC's PCIe endpoint.
// =============================================================================

module nvme_ctrl #(
    parameter MAX_QUEUE_DEPTH = 64,
    parameter BLOCK_SIZE      = 512,
    parameter MAX_TRANSFER    = 65536,
    parameter PAGE_SIZE       = 4096
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Lite slave (CPU register access)
    input  wire [5:0]  s_axi_addr,
    input  wire [31:0] s_axi_wdata,
    output reg  [31:0] s_axi_rdata,
    input  wire        s_axi_we,
    input  wire        s_axi_valid,
    output wire        s_axi_ready,

    // AXI-Stream master (DMA read: device -> memory)
    output reg  [31:0] m_axis_rd_data,
    output reg         m_axis_rd_valid,
    output reg         m_axis_rd_last,
    input  wire        m_axis_rd_ready,

    // AXI-Stream slave (DMA write: memory -> device)
    input  wire [31:0] s_axis_wr_data,
    input  wire        s_axis_wr_valid,
    output wire        s_axis_wr_ready,
    input  wire        s_axis_wr_last,

    // Interrupt
    output reg         irq
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CAP_VAL       = {8'd0, MAX_QUEUE_DEPTH[7:0], 8'd0, 8'h02}; // version 2.0
    localparam VS_VAL        = 32'h0002_0000;  // version 2.0
    localparam CSTS_READY    = 32'h0000_0001;
    localparam CSTS_ERROR    = 32'h0000_0002;

    localparam CMD_READ      = 8'h01;
    localparam CMD_WRITE     = 8'h02;
    localparam CMD_FLUSH     = 8'h03;

    localparam ST_IDLE       = 3'd0;
    localparam ST_CMD        = 3'd1;
    localparam ST_DMA_RD     = 3'd2;
    localparam ST_DMA_WR     = 3'd3;
    localparam ST_COMPLETE   = 3'd4;
    localparam ST_ERROR      = 3'd5;

    // =========================================================================
    // Registers
    // =========================================================================
    reg [2:0]   ctrl_state;
    reg         ctrl_ready;
    reg         ctrl_error;
    reg [7:0]   error_code;
    reg [7:0]   cmd_op;
    reg [31:0]  cmd_slba_lo;
    reg [31:0]  cmd_slba_hi;
    reg [15:0]  cmd_nlb;
    reg [31:0]  cmd_buf_lo;
    reg [31:0]  cmd_buf_hi;
    reg [31:0]  status;
    reg [31:0]  int_en;
    reg [31:0]  aqa;
    reg [31:0]  asq_lo, asq_hi;
    reg [31:0]  acq_lo, acq_hi;
    reg [31:0]  xfer_pos;       // bytes transferred so far
    reg [31:0]  xfer_limit;     // total bytes to transfer
    reg [15:0]  blk_cnt;        // blocks remaining
    reg         s_axis_wr_ready_q;

    // =========================================================================
    // Bus ready (always ready for single-cycle register access)
    // =========================================================================
    assign s_axi_ready = 1'b1;
    assign s_axis_wr_ready = (ctrl_state == ST_DMA_WR);

    // =========================================================================
    // Register read (combinational — data available same cycle as valid+addr)
    // =========================================================================
    always @(*) begin
        s_axi_rdata = 32'h0;
        if (s_axi_valid && !s_axi_we) begin
            case (s_axi_addr)
                6'h00: s_axi_rdata = CAP_VAL;
                6'h04: s_axi_rdata = VS_VAL;
                6'h08: s_axi_rdata = ctrl_error ? CSTS_ERROR : (ctrl_ready ? CSTS_READY : 32'h0);
                6'h0C: s_axi_rdata = aqa;
                6'h10: s_axi_rdata = asq_lo;
                6'h14: s_axi_rdata = asq_hi;
                6'h18: s_axi_rdata = acq_lo;
                6'h1C: s_axi_rdata = acq_hi;
                6'h20: s_axi_rdata = {24'h0, cmd_op};
                6'h24: s_axi_rdata = cmd_slba_lo;
                6'h28: s_axi_rdata = cmd_slba_hi;
                6'h2C: s_axi_rdata = {16'h0, cmd_nlb};
                6'h30: s_axi_rdata = cmd_buf_lo;
                6'h34: s_axi_rdata = cmd_buf_hi;
                6'h38: s_axi_rdata = status;
                6'h3C: s_axi_rdata = int_en;
                default: s_axi_rdata = 32'h0;
            endcase
        end
    end

    // =========================================================================
    // Register write + command state machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_state  <= ST_IDLE;
            ctrl_ready  <= 1'b0;
            ctrl_error  <= 1'b0;
            error_code  <= 8'h0;
            cmd_op      <= 8'h0;
            cmd_slba_lo <= 32'h0;
            cmd_slba_hi <= 32'h0;
            cmd_nlb     <= 16'h0;
            cmd_buf_lo  <= 32'h0;
            cmd_buf_hi  <= 32'h0;
            status      <= 32'h0;
            int_en      <= 32'h0;
            aqa         <= 32'h003F_003F;  // 64 entries default
            asq_lo      <= 32'h0;
            asq_hi      <= 32'h0;
            acq_lo      <= 32'h0;
            acq_hi      <= 32'h0;
            xfer_pos    <= 32'h0;
            xfer_limit  <= 32'h0;
            blk_cnt     <= 16'h0;
            irq         <= 1'b0;
            m_axis_rd_data  <= 32'h0;
            m_axis_rd_valid <= 1'b0;
            m_axis_rd_last  <= 1'b0;
        end else begin
            // Default: deassert IRQ after one cycle
            irq <= 1'b0;

            // Register writes (AXI-Lite)
            if (s_axi_valid && s_axi_we) begin
                case (s_axi_addr)
                    6'h08: begin  // CSTS (write 1 to set ready)
                        if (s_axi_wdata[0]) ctrl_ready <= 1'b1;
                        if (s_axi_wdata[1]) ctrl_error <= 1'b0;
                    end
                    6'h0C: aqa      <= s_axi_wdata;
                    6'h10: asq_lo   <= s_axi_wdata;
                    6'h14: asq_hi   <= s_axi_wdata;
                    6'h18: acq_lo   <= s_axi_wdata;
                    6'h1C: acq_hi   <= s_axi_wdata;
                    6'h20: cmd_op   <= s_axi_wdata[7:0];
                    6'h24: cmd_slba_lo <= s_axi_wdata;
                    6'h28: cmd_slba_hi <= s_axi_wdata;
                    6'h2C: cmd_nlb  <= s_axi_wdata[15:0];
                    6'h30: cmd_buf_lo <= s_axi_wdata;
                    6'h34: cmd_buf_hi <= s_axi_wdata;
                    6'h38: status   <= status & ~s_axi_wdata;  // W1C
                    6'h3C: int_en   <= s_axi_wdata;
                    default: ;
                endcase
            end

            // Command state machine
            case (ctrl_state)
                ST_IDLE: begin
                    // Wait for valid command
                    if (s_axi_valid && s_axi_we && s_axi_addr == 6'h38) begin
                        // Writing to STATUS triggers command execution
                        if (ctrl_ready && !ctrl_error) begin
                            if (cmd_op == CMD_READ || cmd_op == CMD_WRITE ||
                                cmd_op == CMD_FLUSH) begin
                                ctrl_state  <= ST_CMD;
                                xfer_pos    <= 32'h0;
                                blk_cnt     <= cmd_nlb;
                                xfer_limit  <= ({16'd0, cmd_nlb} + 32'd1) * BLOCK_SIZE;
                                status      <= 32'h0;
                            end
                        end
                    end
                end

                ST_CMD: begin
                    if (cmd_op == CMD_FLUSH) begin
                        // FLUSH completes immediately regardless of NLB
                        ctrl_state  <= ST_COMPLETE;
                    end else if (cmd_nlb == 0 || cmd_nlb * BLOCK_SIZE > MAX_TRANSFER) begin
                        ctrl_error <= 1'b1;
                        error_code <= 8'h02;  // invalid field
                        ctrl_state <= ST_ERROR;
                    end else begin
                        // Transition to DMA phase
                        if (cmd_op == CMD_READ)
                            ctrl_state <= ST_DMA_RD;
                        else if (cmd_op == CMD_WRITE)
                            ctrl_state <= ST_DMA_WR;
                        else begin
                            ctrl_state <= ST_ERROR;
                            error_code <= 8'h01;  // invalid opcode
                        end
                    end
                end

                ST_DMA_RD: begin
                    // Device -> Memory: emit words on m_axis_rd
                    if (m_axis_rd_ready && !m_axis_rd_valid) begin
                        m_axis_rd_valid <= 1'b1;
                        m_axis_rd_data  <= xfer_pos + 32'h1;  // non-zero test pattern
                        m_axis_rd_last  <= (xfer_pos + 4 >= xfer_limit);
                        xfer_pos <= xfer_pos + 4;
                    end else if (m_axis_rd_valid && m_axis_rd_ready) begin
                        m_axis_rd_valid <= 1'b0;
                        if (xfer_pos >= xfer_limit)
                            ctrl_state <= ST_COMPLETE;
                    end
                end

                ST_DMA_WR: begin
                    // Memory -> Device: accept words from s_axis_wr
                    // (s_axis_wr_ready is combinational: high while in this state)
                    if (s_axis_wr_valid && s_axis_wr_ready) begin
                        xfer_pos <= xfer_pos + 4;
                        if (s_axis_wr_last || xfer_pos + 4 >= xfer_limit)
                            ctrl_state <= ST_COMPLETE;
                    end
                end

                ST_COMPLETE: begin
                    // Signal completion
                    status     <= status | 32'h0000_0001;  // done bit
                    ctrl_state <= ST_IDLE;
                    if (int_en[0])
                        irq <= 1'b1;
                end

                ST_ERROR: begin
                    status     <= 32'h0000_0002 | {24'h0, error_code};
                    ctrl_state <= ST_IDLE;
                    if (int_en[0])
                        irq <= 1'b1;
                end

                default: ctrl_state <= ST_IDLE;
            endcase
        end
    end

endmodule
