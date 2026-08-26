`include "pnm_defs.vh"

// =============================================================================
// pi_bridge — SPI-to-PNM bridge for Raspberry Pi Compute Module host
//
// Sits between a Raspberry Pi Compute Module (CM4 or CM5) and any orchestrator
// chip in the family. The Pi acts as SPI master; this module translates
// 48-bit register frames into PNM bus accesses.
//
// Frame (48 bits, MSB first, SPI mode 0):
//   Bits 47-40: header {rw(1b), sel[6:0]}   rw=1 read, rw=0 write
//   Bits 39-8 : 32-bit data field
//                 write: value shifted in from MOSI
//                 read : PNM register value shifted out on MISO
//   Bits 7-0  : status byte returned on MISO (0x01 write-ack, 0x00 read)
//
// Register map (sel -> PNM offset), matches orchestrator-chip PNM window:
//   0=CTRL 0x00, 1=LAYER 0x04, 2=MODULE 0x08, 3=LEN 0x0C, 4=DATA 0x10,
//   5=STATUS 0x14, 6=RESULT 0x18, 7=ERRORS 0x1C, 8=DISPATCHES 0x20,
//   9=WEIGHT_FLITS 0x24; sel>=10 passes through as {sel[5:0],2'b00}.
//
// Bus contract: masters hold pnm_valid until pnm_ready pulses (full valid/
// ready handshake on both writes and reads). Read data is captured on the
// pnm_ready edge, so downstream slaves may be combinational or registered
// (e.g. behind pnm_arb). System clock must run fast enough to settle
// between SCLK edges (>= ~10x SPI rate).
// =============================================================================

module pi_bridge (
    input  wire        clk,
    input  wire        rst_n,

    // -- SPI slave pins --
    input  wire        sclk,
    input  wire        mosi,
    input  wire        cs_n,
    output reg         miso,
    output reg         irq_out,

    // -- PNM bus master --
    output reg  [7:0]  pnm_addr,
    output reg  [31:0] pnm_wdata,
    input  wire [31:0] pnm_rdata,
    output reg         pnm_we,
    output reg         pnm_valid,
    input  wire        pnm_ready,

    // -- Status --
    output wire        frame_done
);

    reg sclk_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sclk_d <= 1'b0;
        else        sclk_d <= sclk;
    end

    wire sclk_rise = sclk && !sclk_d;
    wire cs_active = !cs_n;

    function [7:0] addr_map(input [6:0] sel);
        case (sel)
            7'h00: addr_map = 8'h00;
            7'h01: addr_map = 8'h04;
            7'h02: addr_map = 8'h08;
            7'h03: addr_map = 8'h0C;
            7'h04: addr_map = 8'h10;
            7'h05: addr_map = 8'h14;
            7'h06: addr_map = 8'h18;
            7'h07: addr_map = 8'h1C;
            7'h08: addr_map = 8'h20;
            7'h09: addr_map = 8'h24;
            default: addr_map = {sel[5:0], 2'b00};
        endcase
    endfunction

    localparam F_IDLE   = 4'd0;
    localparam F_HDR    = 4'd1;
    localparam F_DATA   = 4'd2;
    localparam F_COMMIT = 4'd3;
    localparam F_TRAIL  = 4'd4;
    localparam F_DONE   = 4'd5;
    localparam F_RD1    = 4'd6;
    localparam F_RDWAIT = 4'd7;
    localparam F_WRWAIT = 4'd8;

    reg [3:0]  f_state;
    reg [39:0] rx_shift;
    reg [39:0] tx_shift;
    reg [5:0]  bit_cnt;
    reg        is_read;
    reg [6:0]  cmd_sel;
    reg [31:0] cmd_wdata;

    assign frame_done = (f_state == F_DONE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_state   <= F_IDLE;
            rx_shift  <= 40'h0;
            tx_shift  <= 40'h0;
            bit_cnt   <= 6'd0;
            is_read   <= 1'b0;
            miso      <= 1'b0;
            irq_out   <= 1'b0;
            pnm_we    <= 1'b0;
            pnm_valid <= 1'b0;
            pnm_wdata <= 32'h0;
            pnm_addr  <= 8'h0;
            cmd_sel   <= 7'h0;
            cmd_wdata <= 32'h0;
        end else begin
            pnm_we    <= 1'b0;
            pnm_valid <= 1'b0;

            case (f_state)
                F_IDLE: begin
                    miso    <= 1'b0;
                    irq_out <= 1'b0;
                    bit_cnt <= 6'd0;
                    if (cs_active && sclk_rise) begin
                        f_state  <= F_HDR;
                        rx_shift <= {rx_shift[38:0], mosi};
                        bit_cnt  <= 6'd1;
                    end
                end

                F_HDR: begin
                    if (!cs_active) begin
                        f_state <= F_IDLE;
                    end else if (sclk_rise && bit_cnt < 6'd8) begin
                        rx_shift <= {rx_shift[38:0], mosi};
                        bit_cnt  <= bit_cnt + 1;
                    end else if (!sclk_rise && bit_cnt == 6'd8) begin
                        is_read  <= rx_shift[7];
                        cmd_sel  <= rx_shift[6:0];
                        pnm_addr <= addr_map(rx_shift[6:0]);
                        bit_cnt  <= 6'd0;
                        if (rx_shift[7]) begin
                            f_state <= F_RD1;
                        end else begin
                            tx_shift <= {32'h0, 8'h01};
                            f_state  <= F_DATA;
                        end
                    end
                end

                F_RD1: begin
                    pnm_valid <= 1'b1;
                    f_state   <= F_RDWAIT;
                end

                F_RDWAIT: begin
                    if (!cs_active) begin
                        pnm_valid <= 1'b0;
                        f_state   <= F_IDLE;
                    end else begin
                        pnm_valid <= 1'b1;
                        if (pnm_ready) begin
                            pnm_valid <= 1'b0;
                            tx_shift  <= {pnm_rdata, 8'h00};
                            f_state   <= F_DATA;
                        end
                    end
                end

                F_DATA: begin
                    if (!cs_active) begin
                        f_state <= F_IDLE;
                    end else if (sclk_rise) begin
                        rx_shift <= {rx_shift[38:0], mosi};
                        miso     <= tx_shift[39];
                        tx_shift <= {tx_shift[38:0], 1'b0};

                        if (bit_cnt == 6'd31) begin
                            if (!is_read) begin
                                cmd_wdata <= {rx_shift[30:0], mosi};
                                f_state   <= F_COMMIT;
                            end else
                                f_state <= F_TRAIL;
                            bit_cnt <= 6'd0;
                        end else
                            bit_cnt <= bit_cnt + 1;
                    end
                end

                F_COMMIT: begin
                    pnm_valid <= 1'b1;
                    pnm_we    <= 1'b1;
                    pnm_wdata <= cmd_wdata;
                    f_state   <= F_WRWAIT;
                end

                F_WRWAIT: begin
                    if (!cs_active) begin
                        pnm_valid <= 1'b0;
                        pnm_we    <= 1'b0;
                        f_state   <= F_IDLE;
                    end else begin
                        pnm_valid <= 1'b1;
                        pnm_we    <= 1'b1;
                        pnm_wdata <= cmd_wdata;
                        if (pnm_ready) begin
                            pnm_valid <= 1'b0;
                            pnm_we    <= 1'b0;
                            cmd_wdata <= 32'h0;
                            bit_cnt   <= 6'd0;
                            f_state   <= F_TRAIL;
                        end
                    end
                end

                F_TRAIL: begin
                    if (!cs_active) begin
                        f_state <= F_IDLE;
                    end else if (sclk_rise) begin
                        miso     <= tx_shift[39];
                        tx_shift <= {tx_shift[38:0], 1'b0};
                        if (bit_cnt >= 6'd7)
                            f_state <= F_DONE;
                        else
                            bit_cnt <= bit_cnt + 1;
                    end
                end

                F_DONE: begin
                    if (!cs_active) begin
                        irq_out <= 1'b1;
                        f_state <= F_IDLE;
                    end
                end

                default: f_state <= F_IDLE;
            endcase
        end
    end

endmodule
