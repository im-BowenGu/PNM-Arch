`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// orchestrator_sbc — Plain SBC Router Chip for Complex Data Workflows
//
// General-purpose single-board-computer-class orchestrator chip targeting
// Linux/Redox NOMMU + CPython userland. No integrated MAC array or MoE
// gating unit; those run as software on the CPU or are offloaded to the
// fabric's compute nodes.
//
// Use cases:
//   - Transpiler orchestration (R/Haskell/HLSL IR lowering, §2.17.1)
//   - Complex data pipelines (ETL, graph traversal, multi-stage reduction)
//   - Development / bring-up chassis (full Linux toolchain on-chip)
//   - Any workload where the control plane is more complex than a
//     dispatch loop but does not need local BF16 silicon
//
// Silicon budget:
//   - RV32IMA multi-cycle core (production: RV32IMAFC for NOMMU Linux)
//   - 64KB boot ROM (U-Boot SPL equivalent)
//   - LPDDR5 system DRAM controller stub (1GB address space)
//     -- Linux/Redox NOMMU + CPython + pip userland runs here --
//     -- 512MB minimum for kernel + CPython + site-packages --
//   - On-chip SRAM (configurable: 500KB..32MB, default 512KB)
//   - PCIe Gen5 x16 PHY (host DMA, BAR-style register window)
//   - NVMe storage controller (block I/O for OS userland)
//   - UART console, CLINT timer
//   - PNM router engine (same flit builder wire format)
//
// Memory map:
//   0x0000_0000 - 0x0000_FFFF  Boot ROM (64KB)
//   0x1000_0000 - 0x1000_001F  UART0
//   0x2000_0000 - 0x2000_BFFF  CLINT
//   0x4000_0000 - 0x4FFF_FFFF  On-chip SRAM (256MB window, 512KB default,
//                                 configurable 500KB..32MB by SRAM_WORDS param)
//   0x8000_0000 - 0xBFFF_FFFF  System DRAM (1GB address space, LPDDR5 stub)
//   0xC000_0000 - 0xC000_00FF  PCIe Gen5 x16 PHY registers
//   0xD000_0000 - 0xD000_003F  NVMe storage controller registers
//   0xF000_0000 - 0xF000_003F  PNM router registers
//
// The DRAM behavioral model provides programmable CAS latency to exercise
// firmware timing without a full LPDDR5 PHY. Production replaces this
// with a hard DDR controller.
// =============================================================================

module orchestrator_sbc #(
    parameter CLK_FREQ     = 100_000_000,
    parameter BAUD_RATE    = 115200,
    parameter NUM_LAYERS   = 8,
    parameter BOARD_X      = 8,
    parameter BOARD_Y      = 8,
    parameter NUM_NODES    = NUM_LAYERS * BOARD_X * BOARD_Y,
    parameter DRAM_WORDS   = 1048576,  // 4MB simulated (address space is 1GB)
    parameter DRAM_LATENCY = 4,         // simulated CAS latency in cycles
    parameter SRAM_WORDS   = 131072     // 512KB on-chip SRAM (default; range 500KB..32MB)
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART console
    input  wire        uart_rx,
    output wire        uart_tx,

    // POST discovery sideband
    input  wire [NUM_NODES-1:0] topology_rdy,

    // Spine injection
    output wire [7:0]  spine_inject_data,
    output wire        spine_inject_valid,
    output wire        spine_inject_sop,
    output wire        spine_inject_eop,
    input  wire        spine_inject_ready,
    output wire [1:0]  spine_inject_vc,

    // Spine extraction
    input  wire [7:0]  spine_extract_data,
    input  wire        spine_extract_valid,
    input  wire        spine_extract_sop,
    input  wire        spine_extract_eop,
    input  wire [1:0]  spine_extract_vc,

    // External interrupts
    input  wire [15:0] ext_irq,

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

    reg [31:0] rom_rdata;
    reg [31:0] dram_rdata;
    reg        dram_ready;
    wire [31:0] uart_rdata;
    wire [31:0] clint_rdata;
    reg  [31:0] pnm_rdata;
    reg  [31:0] sram_rdata;
    wire [31:0] pcie_rdata;
    wire        pcie_ready;
    wire [31:0] nvme_rdata;
    wire        nvme_ready;
    wire [31:0] cpu_fetch_addr;

    wire sel_rom   = (cpu_fetch_addr[31:16] == 16'h0000);
    wire sel_uart  = (cpu_addr[31:8]  == 24'h1000_00);
    wire sel_clint = (cpu_addr[31:16] == 16'h2000);
    wire sel_sram  = (cpu_addr[31:28] == 4'h4);             // 0x4000_0000..0x4FFF_FFFF
    wire sel_dram  = (cpu_addr[31:30] == 2'b10);            // 0x8000_0000..0xBFFF_FFFF
    wire sel_pcie  = (cpu_addr[31:28] == 4'hC);             // 0xC000_0000..0xCFFF_FFFF
    wire sel_nvme  = (cpu_addr[31:28] == 4'hD);             // 0xD000_0000..0xDFFF_FFFF
    wire sel_pnm   = (cpu_addr[31:8]  == 24'hF000_00);

    assign cpu_error = 1'b0;

    reg [31:0] mux_rdata;
    always @(*) begin
        mux_rdata = 32'h0;
        if (sel_rom)        mux_rdata = rom_rdata;
        else if (sel_uart)  mux_rdata = uart_rdata;
        else if (sel_clint) mux_rdata = clint_rdata;
        else if (sel_sram)  mux_rdata = sram_rdata;
        else if (sel_dram)  mux_rdata = dram_rdata;
        else if (sel_pcie)  mux_rdata = pcie_rdata;
        else if (sel_nvme)  mux_rdata = nvme_rdata;
        else if (sel_pnm)   mux_rdata = pnm_rdata;
    end

    assign cpu_rdata = mux_rdata;

    assign cpu_ready = (sel_dram && !dram_ready) ? 1'b0 :
                       (sel_pcie && !pcie_ready && cpu_we) ? 1'b0 :
                       (sel_nvme && !nvme_ready) ? 1'b0 :
                       (sel_rom | sel_uart | sel_clint | sel_sram |
                        sel_dram | sel_pcie | sel_nvme | sel_pnm);

    // =========================================================================
    // CPU Core
    // =========================================================================
    rv32_core #(
        .RESET_ADDR(32'h0000_0000),
        .NMINT(16)
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
        .irq       (ext_irq),
        .fetch_addr(cpu_fetch_addr)
    );

    // =========================================================================
    // Boot ROM (64KB)
    // =========================================================================
    reg [31:0] rom [0:16383];
    always @(*) rom_rdata = rom[cpu_fetch_addr[15:2]];

    // =========================================================================
    // On-chip SRAM (configurable: 500KB..32MB depending on board tier)
    //
    // Single-cycle combinational read, registered write. The von Neumann
    // constraint requires instructions to execute from fast local memory;
    // DRAM is too slow for per-cycle instruction fetch.
    //   - 500KB (128K words): MCU-class desk-side, bare-metal dispatch loop
    //   - 1-4MB: trimmed Linux tinyconfig or seL4 image
    //   - 16MB: full Linux + CPython userland
    //   - 32MB: headroom for complex data workflows
    //
    // The address window at 0x4000_0000 is 256MB; unused upper addresses
    // alias back via the (SRAM_WORDS-1) mask.
    // =========================================================================
    reg [31:0] sram_mem [0:SRAM_WORDS-1];

    always @(*) sram_rdata = sram_mem[cpu_addr[25:2] & (SRAM_WORDS-1)];

    always @(posedge clk) begin
        if (sel_sram && cpu_valid && cpu_we) begin
            if (cpu_be[0]) sram_mem[cpu_addr[25:2] & (SRAM_WORDS-1)][7:0]   <= cpu_wdata[7:0];
            if (cpu_be[1]) sram_mem[cpu_addr[25:2] & (SRAM_WORDS-1)][15:8]  <= cpu_wdata[15:8];
            if (cpu_be[2]) sram_mem[cpu_addr[25:2] & (SRAM_WORDS-1)][23:16] <= cpu_wdata[23:16];
            if (cpu_be[3]) sram_mem[cpu_addr[25:2] & (SRAM_WORDS-1)][31:24] <= cpu_wdata[31:24];
        end
    end

    // =========================================================================
    // System DRAM (LPDDR5 stub — behavioral array with CAS latency)
    //
    // Address space: 0x8000_0000 .. 0xBFFF_FFFF (1GB window).
    // Simulated array: DRAM_WORDS x 32 bits. This is where the Linux/Redox
    // kernel, CPython interpreter, and userland packages reside at runtime.
    // A 512MB minimum allocation is expected for kernel (~32MB) + CPython
    // runtime (~50MB) + pip-installed site-packages (~100-400MB depending
    // on workload) + heap headroom.
    //
    // The multi-cycle latency models row activate + column access delay.
    // All loads/stores to this window stall the CPU bus until ready.
    // =========================================================================
    reg [31:0] dram_mem [0:DRAM_WORDS-1];

    reg [7:0]  dram_wait_cnt;
    reg        dram_pending_rd;
    reg        dram_pending_wr;
    reg [3:0]  dram_wr_be;
    reg [31:0] dram_wr_data;
    reg [31:0] dram_wr_addr;
    reg [31:0] dram_rd_addr;

    wire [31:0] dram_offset = {4'b0000, cpu_addr[29:2]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_rdata      <= 32'h0;
            dram_ready      <= 1'b0;
            dram_wait_cnt   <= 8'h0;
            dram_pending_rd <= 1'b0;
            dram_pending_wr <= 1'b0;
            dram_wr_be      <= 4'h0;
            dram_wr_data    <= 32'h0;
            dram_wr_addr    <= 32'h0;
            dram_rd_addr    <= 32'h0;
        end else begin
            dram_ready <= 1'b0;

            if (dram_pending_rd) begin
                if (dram_wait_cnt >= DRAM_LATENCY - 1) begin
                    dram_rdata      <= (dram_rd_addr < DRAM_WORDS) ?
                                       dram_mem[dram_rd_addr] : 32'h0;
                    dram_ready      <= 1'b1;
                    dram_pending_rd <= 1'b0;
                end else
                    dram_wait_cnt <= dram_wait_cnt + 1;
            end else if (dram_pending_wr) begin
                if (dram_wait_cnt >= DRAM_LATENCY - 1) begin
                    if (dram_wr_addr < DRAM_WORDS) begin
                        if (dram_wr_be[0]) dram_mem[dram_wr_addr][7:0]   <= dram_wr_data[7:0];
                        if (dram_wr_be[1]) dram_mem[dram_wr_addr][15:8]  <= dram_wr_data[15:8];
                        if (dram_wr_be[2]) dram_mem[dram_wr_addr][23:16] <= dram_wr_data[23:16];
                        if (dram_wr_be[3]) dram_mem[dram_wr_addr][31:24] <= dram_wr_data[31:24];
                    end
                    dram_ready      <= 1'b1;
                    dram_pending_wr <= 1'b0;
                end else
                    dram_wait_cnt <= dram_wait_cnt + 1;
            end else if (sel_dram && cpu_valid && cpu_we && !dram_pending_rd && !dram_pending_wr) begin
                dram_wr_be      <= cpu_be;
                dram_wr_data    <= cpu_wdata;
                dram_wr_addr    <= dram_offset;
                dram_pending_wr <= 1'b1;
                dram_wait_cnt   <= 8'h0;
            end else if (sel_dram && cpu_valid && !cpu_we && !dram_pending_rd && !dram_pending_wr) begin
                dram_rd_addr    <= dram_offset;
                dram_pending_rd <= 1'b1;
                dram_wait_cnt   <= 8'h0;
            end
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
        .clk(clk), .rst_n(rst_n),
        .addr(cpu_addr), .wdata(cpu_wdata), .rdata(uart_rdata),
        .we(cpu_we), .valid(sel_uart && cpu_valid), .ready(uart_ready),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .irq(uart_irq)
    );

    // =========================================================================
    // CLINT
    // =========================================================================
    wire clint_mtip, clint_msip;
    clint #(
        .CLK_FREQ(CLK_FREQ),
        .TIMER_PERIOD(CLK_FREQ / 10)
    ) u_clint (
        .clk(clk), .rst_n(rst_n),
        .addr(cpu_addr), .wdata(cpu_wdata), .rdata(clint_rdata),
        .we(cpu_we), .be(cpu_be),
        .valid(sel_clint && cpu_valid), .ready(),
        .msip(clint_msip), .mtip(clint_mtip)
    );

    // =========================================================================
    // PCIe Gen5 x16 PHY (host DMA endpoint)
    // =========================================================================
    wire pcie_irq;
    wire pcie_link_up;
    wire [3:0] pcie_ltssm;

    pcie_phy #(
        .LANES(16),
        .GEN(5),
        .MAX_PAYLOAD_BYTES(512),
        .CPL_FIFO_WORDS(256),
        .STAGE_WORDS(128),
        .LB_WORDS(4096),
        .LOOPBACK(1)
    ) u_pcie (
        .clk       (clk),
        .rst_n     (rst_n),
        .ctl_addr  (cpu_addr[7:0]),
        .ctl_wdata (cpu_wdata),
        .ctl_we    (cpu_we),
        .ctl_valid (sel_pcie && cpu_valid),
        .ctl_ready (pcie_ready),
        .ctl_rdata (pcie_rdata),
        .irq       (pcie_irq),
        .link_up   (pcie_link_up),
        .ltssm_state(pcie_ltssm)
    );

    // =========================================================================
    // NVMe Storage Controller
    // =========================================================================
    wire nvme_irq;

    nvme_ctrl #(
        .MAX_QUEUE_DEPTH(64),
        .BLOCK_SIZE(512),
        .MAX_TRANSFER(65536),
        .PAGE_SIZE(4096)
    ) u_nvme (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axi_addr     (cpu_addr[7:2]),
        .s_axi_wdata    (cpu_wdata),
        .s_axi_rdata    (nvme_rdata),
        .s_axi_we       (cpu_we),
        .s_axi_valid    (sel_nvme && cpu_valid),
        .s_axi_ready    (nvme_ready),
        .m_axis_rd_data (),
        .m_axis_rd_valid(),
        .m_axis_rd_last (),
        .m_axis_rd_ready(1'b1),
        .s_axis_wr_data (32'h0),
        .s_axis_wr_valid(1'b0),
        .s_axis_wr_ready(),
        .s_axis_wr_last (1'b0),
        .irq            (nvme_irq)
    );

    // =========================================================================
    // Interrupt routing
    // =========================================================================
    wire [15:0] cpu_irq;
    assign cpu_irq[0]    = uart_irq;
    assign cpu_irq[1]    = clint_mtip;
    assign cpu_irq[2]    = clint_msip;
    assign cpu_irq[3]    = spine_extract_valid;
    assign cpu_irq[4]    = pcie_irq;
    assign cpu_irq[5]    = nvme_irq;
    assign cpu_irq[15:6] = ext_irq[15:6];

    // =========================================================================
    // PNM Router Engine (same flit builder wire format)
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
    reg [31:0] route_weight_flits;
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
            route_layer        <= 8'h0;
            route_module       <= 8'h0;
            route_len          <= 16'h0;
            route_wpos         <= 8'h0;
            route_errors       <= 32'h0;
            route_dispatches   <= 32'h0;
            route_weight_flits <= 32'h0;
            fb_state           <= FB_IDLE;
            fb_layer_r         <= 8'h0;
            fb_module_r        <= 8'h0;
            fb_ctrl            <= 8'h0;
            fb_len             <= 16'h0;
            fb_pos             <= 16'h0;
            fb_crc             <= 16'hFFFF;
            fb_active          <= 1'b0;
            fb_out_data_r      <= 8'h0;
            fb_out_valid_r     <= 1'b0;
            fb_out_sop_r       <= 1'b0;
            fb_out_eop_r       <= 1'b0;
            pnm_rdata          <= 32'h0;
            boot_done_r        <= 1'b0;
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
                        if (route_wpos != 8'hFF) begin  // prevent buffer overflow
                            route_payload[route_wpos] <= cpu_wdata[7:0];
                            route_wpos <= route_wpos + 1;
                        end
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
                            route_weight_flits <= route_weight_flits + 1;
                        end
                    end
                end

                default: fb_state <= FB_IDLE;
            endcase

            if (spine_extract_valid && spine_extract_eop)
                route_dispatches <= route_dispatches + 1;

            pnm_rdata <= 32'h0;
            if (sel_pnm && cpu_valid && !cpu_we) begin
                case (pnm_addr)
                    8'h14: pnm_rdata <= {30'h0, 1'b0, pnm_busy};
                    8'h18: pnm_rdata <= {24'h0, spine_extract_data};
                    8'h1C: pnm_rdata <= route_errors;
                    8'h20: pnm_rdata <= route_dispatches;
                    8'h24: pnm_rdata <= route_weight_flits;
                    default: ;
                endcase
            end
        end
    end

endmodule
