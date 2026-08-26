`include "pnm_defs.vh"

// =============================================================================
// orchestrator_mcu — Minimal MCU-class Router Chip
//
// Bare-metal router for embedded deployments running stencil/reduction/
// broadcast workloads on small chassis. Routes are compile-time constants
// burned into ROM; no host PCIe, no MoE gating, no FPU, no OS.
//
// Silicon budget:
//   - RV32I multi-cycle core (no M extension, no FPU)
//   - 8KB boot ROM (route tables + dispatch loop)
//   - 4KB SRAM (stack + doorbell scratch)
//   - GPIO/UART console (no PCIe PHY)
//   - PNM flit builder (same wire format as bmc_orchestrator_top)
//
// Target workloads: jacobi5, reduction, broadcast on <=64-node chassis.
// Firmware: sim/toolchain/mcu/ (bare-metal static allocation).
//
// Memory map:
//   0x0000_0000 - 0x0000_1FFF  Boot ROM (8KB, read-only)
//   0x1000_0000 - 0x1000_001F  UART0
//   0x8000_0000 - 0x8000_0FFF  SRAM (4KB, read-write)
//   0xF000_0000 - 0xF000_003F  PNM router registers
// =============================================================================

module orchestrator_mcu #(
    parameter CLK_FREQ    = 50_000_000,
    parameter BAUD_RATE   = 115200,
    parameter NUM_LAYERS  = 2,
    parameter BOARD_X     = 4,
    parameter BOARD_Y     = 4,
    parameter NUM_NODES   = NUM_LAYERS * BOARD_X * BOARD_Y
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART console only (no PCIe)
    input  wire        uart_rx,
    output wire        uart_tx,

    // POST discovery sideband
    input  wire [NUM_NODES-1:0] topology_rdy,

    // Spine injection (to PNM fabric)
    output wire [7:0]  spine_inject_data,
    output wire        spine_inject_valid,
    output wire        spine_inject_sop,
    output wire        spine_inject_eop,
    input  wire        spine_inject_ready,
    output wire [1:0]  spine_inject_vc,

    // Spine extraction (from PNM fabric)
    input  wire [7:0]  spine_extract_data,
    input  wire        spine_extract_valid,
    input  wire        spine_extract_sop,
    input  wire        spine_extract_eop,
    input  wire [1:0]  spine_extract_vc,

    // External interrupts
    input  wire [7:0]  ext_irq,

    // Status
    output wire        boot_done
);

    // =========================================================================
    // Bus interconnect
    // =========================================================================
    wire [31:0] cpu_addr;
    wire [31:0] cpu_wdata;
    wire [31:0] cpu_rdata;
    wire        cpu_we;
    wire [3:0]  cpu_be;
    wire        cpu_valid;
    wire        cpu_ready;
    wire        cpu_error;

    reg  [31:0] rom_rdata;
    reg  [31:0] sram_rdata;
    wire [31:0] uart_rdata;
    reg  [31:0] pnm_rdata;
    wire [31:0] cpu_fetch_addr;

    wire sel_rom  = (cpu_fetch_addr[31:13] == 19'h0000);   // 0x0000_0000, 8KB
    wire sel_uart = (cpu_addr[31:8]  == 24'h1000_00);      // 0x1000_0000
    wire sel_sram = (cpu_addr[31:12] == 20'h8000_0);       // 0x8000_0000, 4KB
    wire sel_pnm  = (cpu_addr[31:8]  == 24'hF000_00);      // 0xF000_0000

    assign cpu_error = 1'b0;

    reg [31:0] mux_rdata;
    always @(*) begin
        mux_rdata = 32'h0;
        if (sel_rom)       mux_rdata = rom_rdata;
        else if (sel_uart) mux_rdata = uart_rdata;
        else if (sel_sram) mux_rdata = sram_rdata;
        else if (sel_pnm)  mux_rdata = pnm_rdata;
    end

    assign cpu_rdata = mux_rdata;
    assign cpu_ready = sel_rom | sel_uart | sel_sram | sel_pnm;

    wire [7:0] cpu_irq;

    // =========================================================================
    // CPU core (RV32I subset — no M, no CSR beyond machine-mode minimums)
    // =========================================================================
    rv32_core #(
        .RESET_ADDR(32'h0000_0000),
        .NMINT(8)
    ) u_cpu (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_addr  (cpu_addr),
        .bus_wdata (cpu_wdata),
        .bus_rdata (cpu_rdata),
        .bus_we    (cpu_we),
        .bus_be    (cpu_be),
        .bus_valid (cpu_valid),
        .bus_ready (cpu_ready),
        .bus_error (cpu_error),
        .irq       (cpu_irq),
        .fetch_addr(cpu_fetch_addr)
    );

    // =========================================================================
    // Boot ROM (8KB — route tables + dispatch loop)
    // =========================================================================
    reg [31:0] rom [0:2047];
    always @(*) rom_rdata = rom[cpu_fetch_addr[12:2]];

    // =========================================================================
    // SRAM (4KB — stack + doorbell scratch)
    // =========================================================================
    reg [31:0] sram [0:1023];
    always @(*) begin
        if (sel_sram) sram_rdata = sram[cpu_addr[11:2]];
        else          sram_rdata = 32'h0;
    end

    always @(posedge clk) begin
        if (sel_sram && cpu_valid && cpu_we) begin
            if (cpu_be[0]) sram[cpu_addr[11:2]][7:0]   <= cpu_wdata[7:0];
            if (cpu_be[1]) sram[cpu_addr[11:2]][15:8]  <= cpu_wdata[15:8];
            if (cpu_be[2]) sram[cpu_addr[11:2]][23:16] <= cpu_wdata[23:16];
            if (cpu_be[3]) sram[cpu_addr[11:2]][31:24] <= cpu_wdata[31:24];
        end
    end

    // =========================================================================
    // UART
    // =========================================================================
    wire        uart_irq;
    wire        uart_ready;
    uart #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (cpu_addr),
        .wdata    (cpu_wdata),
        .rdata    (uart_rdata),
        .we       (cpu_we),
        .valid    (sel_uart && cpu_valid),
        .ready    (uart_ready),
        .uart_rx  (uart_rx),
        .uart_tx  (uart_tx),
        .irq      (uart_irq)
    );

    // IRQ wiring: irq[0]=UART, irq[1]=doorbell, rest external
    assign cpu_irq[0] = uart_irq;
    assign cpu_irq[1] = spine_extract_valid;
    assign cpu_irq[7:2] = ext_irq[7:2];

    // =========================================================================
    // PNM Router Engine (flit builder, same wire format)
    // =========================================================================
    localparam CTRL_COMPUTE = 8'h80;
    localparam VC_DESCENT   = 2'b10;

    reg [7:0]  route_layer;
    reg [7:0]  route_module;
    reg [15:0] route_len;
    reg [7:0]  route_payload [0:255];
    reg [7:0]  route_wpos;
    reg [31:0] route_errors;
    reg [31:0] route_dispatches;
    reg        boot_done_r;
    assign boot_done = boot_done_r;

    localparam FB_IDLE    = 3'd0;
    localparam FB_HDR     = 3'd1;
    localparam FB_PAYLOAD = 3'd2;
    localparam FB_CRC     = 3'd3;

    reg [2:0]  fb_state;
    reg [7:0]  fb_layer_r;
    reg [7:0]  fb_module_r;
    reg [7:0]  fb_ctrl;
    reg [15:0] fb_len;
    reg [15:0] fb_pos;
    reg [15:0] fb_crc;
    reg        fb_active;
    reg [7:0]  fb_out_data_r;
    reg        fb_out_valid_r;
    reg        fb_out_sop_r;
    reg        fb_out_eop_r;

    wire fb_out_ready = spine_inject_ready;
    wire pnm_busy = fb_active;

    assign spine_inject_data  = fb_out_data_r;
    assign spine_inject_valid = fb_out_valid_r;
    assign spine_inject_sop   = fb_out_sop_r;
    assign spine_inject_eop   = fb_out_eop_r;
    assign spine_inject_vc    = VC_DESCENT;

    function [15:0] crc16_next;
        input [15:0] crc_in;
        input [7:0]  data_in;
        reg [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {data_in, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[15]) crc = (crc << 1) ^ 16'h1021;
                else         crc = crc << 1;
            end
            crc16_next = crc;
        end
    endfunction

    wire [7:0] pnm_addr = cpu_addr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            route_layer      <= 8'h0;
            route_module     <= 8'h0;
            route_len        <= 16'h0;
            route_wpos       <= 8'h0;
            route_errors     <= 32'h0;
            route_dispatches <= 32'h0;
            fb_state         <= FB_IDLE;
            fb_layer_r       <= 8'h0;
            fb_module_r      <= 8'h0;
            fb_ctrl          <= 8'h0;
            fb_len           <= 16'h0;
            fb_pos           <= 16'h0;
            fb_crc           <= 16'hFFFF;
            fb_active        <= 1'b0;
            fb_out_data_r    <= 8'h0;
            fb_out_valid_r   <= 1'b0;
            fb_out_sop_r     <= 1'b0;
            fb_out_eop_r     <= 1'b0;
            pnm_rdata        <= 32'h0;
            boot_done_r      <= 1'b0;
        end else begin
            fb_out_valid_r <= 1'b0;
            fb_out_sop_r   <= 1'b0;
            fb_out_eop_r   <= 1'b0;

            if (sel_pnm && cpu_valid && cpu_we) begin
                case (pnm_addr)
                    8'h04: route_layer  <= cpu_wdata[7:0];
                    8'h08: route_module <= cpu_wdata[7:0];
                    8'h0C: route_len    <= cpu_wdata[15:0];
                    8'h10: begin
                        route_payload[route_wpos] <= cpu_wdata[7:0];
                        route_wpos <= route_wpos + 1;
                    end
                    8'h00: begin
                        if (cpu_wdata[2]) boot_done_r <= 1'b1;
                        if (!pnm_busy && cpu_wdata[0]) begin
                            fb_layer_r  <= route_layer;
                            fb_module_r <= route_module;
                            fb_ctrl     <= CTRL_COMPUTE;
                            fb_len      <= route_len;
                            fb_state    <= FB_HDR;
                            fb_pos      <= 16'h0;
                            fb_crc      <= 16'hFFFF;
                            fb_active   <= 1'b1;
                            route_wpos  <= 8'h0;
                        end
                    end
                    default: ;
                endcase
            end

            case (fb_state)
                FB_IDLE: ;

                FB_HDR: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        fb_out_valid_r <= 1;
                        case (fb_pos)
                            0: begin fb_out_data_r <= fb_layer_r;  fb_out_sop_r <= 1; end
                            1: begin fb_out_data_r <= fb_module_r; end
                            2: begin fb_out_data_r <= fb_ctrl;     end
                            3: begin fb_out_data_r <= fb_len[7:0]; end
                            4: begin fb_out_data_r <= fb_len[15:8];end
                        endcase
                        if (fb_pos >= 1 && fb_pos <= 4) begin
                            if (fb_pos == 1)      fb_crc <= crc16_next(16'hFFFF, fb_module_r);
                            else if (fb_pos == 2) fb_crc <= crc16_next(fb_crc, fb_ctrl);
                            else if (fb_pos == 3) fb_crc <= crc16_next(fb_crc, fb_len[7:0]);
                            else                  fb_crc <= crc16_next(fb_crc, fb_len[15:8]);
                        end
                        if (fb_pos == 4) begin
                            fb_state <= (fb_len == 0) ? FB_CRC : FB_PAYLOAD;
                            fb_pos   <= 0;
                        end else
                            fb_pos <= fb_pos + 1;
                    end
                end

                FB_PAYLOAD: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        fb_out_valid_r <= 1;
                        fb_out_data_r  <= route_payload[fb_pos[7:0]];
                        fb_crc         <= crc16_next(fb_crc, route_payload[fb_pos[7:0]]);
                        if (fb_pos == fb_len - 1) begin
                            fb_state <= FB_CRC;
                            fb_pos   <= 0;
                        end else
                            fb_pos <= fb_pos + 1;
                    end
                end

                FB_CRC: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        fb_out_valid_r <= 1;
                        if (fb_pos == 0) begin
                            fb_out_data_r <= fb_crc[15:8];
                            fb_pos        <= 1;
                        end else begin
                            fb_out_data_r <= fb_crc[7:0];
                            fb_out_eop_r  <= 1;
                            fb_state      <= FB_IDLE;
                            fb_active     <= 0;
                            route_dispatches <= route_dispatches + 1;
                        end
                    end
                end

                default: fb_state <= FB_IDLE;
            endcase

            if (spine_extract_valid && spine_extract_eop) begin
                route_dispatches <= route_dispatches + 1;
            end

            pnm_rdata <= 32'h0;
            if (sel_pnm && cpu_valid && !cpu_we) begin
                case (pnm_addr)
                    8'h14: pnm_rdata <= {30'h0, 1'b0, pnm_busy};
                    8'h18: pnm_rdata <= {24'h0, spine_extract_data};
                    8'h1C: pnm_rdata <= route_errors;
                    8'h20: pnm_rdata <= route_dispatches;
                    default: ;
                endcase
            end
        end
    end

endmodule
