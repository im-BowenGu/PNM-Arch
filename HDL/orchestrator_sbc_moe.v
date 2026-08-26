`include "pnm_defs.vh"

// =============================================================================
// orchestrator_sbc_moe — SBC Router Chip with BF16 MAC Array and MoE Gating SRAM
//
// Mid-tier orchestrator chip for MoE transformer inference and dense LLM dispatch.
// Integrates local gating evaluation so expert routing decisions never leave
// the die.
//
// Silicon budget:
//   - RV32IMA multi-cycle core (production: RV32IMAFC)
//   - 64KB boot ROM (firmware + dispatch schedule)
//   - 64KB dedicated MoE gating weight SRAM (32K BF16 entries)
//   - bf16_mac_array (16x16 systolic) for local projection compute
//   - moe_gating unit (top-K selection + coordinate map)
//   - LPDDR5 system DRAM controller stub (512MB address space)
//     -- Linux/Redox NOMMU + CPython userland runs here --
//   - PCIe Gen5 endpoint register stub
//   - UART console, CLINT timer, PNM router engine
//
// Target workloads: MoE transformer inference, dense LLM dispatch.
// Firmware: sim/toolchain/soc/ (NOMMU Linux daemon).
//
// Memory map:
//   0x0000_0000 - 0x0000_FFFF  Boot ROM (64KB, read-only)
//   0x1000_0000 - 0x1000_001F  UART0
//   0x2000_0000 - 0x2000_BFFF  CLINT
//   0x4000_0000 - 0x4000_FFFF  MoE gating weight SRAM (64KB)
//   0x8000_0000 - 0x9FFF_FFFF  System DRAM (512MB, LPDDR5 stub)
//   0xC000_0000 - 0xC000_00FF  PCIe Gen5 endpoint regs (stub)
//   0xF000_0000 - 0xF000_003F  PNM router registers
//
// The DRAM is modeled as a synchronous array with programmable CAS latency
// to approximate LPDDR5 timing without a full PHY. Production silicon
// replaces this block with a hard LPDDR5 controller.
// =============================================================================

module orchestrator_sbc_moe #(
    parameter CLK_FREQ        = 100_000_000,
    parameter BAUD_RATE       = 115200,
    parameter NUM_LAYERS      = 8,
    parameter BOARD_X         = 8,
    parameter BOARD_Y         = 8,
    parameter NUM_NODES       = NUM_LAYERS * BOARD_X * BOARD_Y,
    parameter MAX_EXPERTS     = 128,
    parameter TOP_K           = 8,
    parameter HIDDEN_SIZE     = 2816,
    parameter GATING_ENTRIES  = 32768,   // 64KB / 2 bytes per BF16 entry
    parameter DRAM_WORDS      = 262144,  // 1MB simulated (address space is 512MB)
    parameter DRAM_LATENCY    = 4,       // simulated CAS latency in cycles
    parameter ARRAY_SIZE      = 16       // systolic array dimension
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART console
    input  wire        uart_rx,
    output wire        uart_tx,

    // PCIe Gen5 endpoint (register-level stub)
    input  wire [7:0]  pcie_in_data,
    input  wire        pcie_in_valid,
    input  wire        pcie_in_sop,
    input  wire        pcie_in_eop,
    output wire        pcie_in_ready,
    output wire [7:0]  pcie_out_data,
    output wire        pcie_out_valid,
    output wire        pcie_out_sop,
    output wire        pcie_out_eop,
    input  wire        pcie_out_ready,

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

    reg  [31:0] rom_rdata;
    reg  [31:0] dram_rdata;
    reg         dram_ready;
    wire [31:0] uart_rdata;
    wire [31:0] clint_rdata;
    reg  [31:0] gating_rdata;
    reg  [31:0] pcie_rdata;
    reg  [31:0] pnm_rdata;
    wire [31:0] cpu_fetch_addr;

    wire sel_rom    = (cpu_fetch_addr[31:16] == 16'h0000);
    wire sel_uart   = (cpu_addr[31:8]  == 24'h1000_00);
    wire sel_clint  = (cpu_addr[31:16] == 16'h2000);
    wire sel_gating = (cpu_addr[31:16] == 16'h4000);       // 0x4000_0000
    wire sel_dram   = (cpu_addr[31:29] == 3'b100);          // 0x8000_0000..0x9FFF_FFFF
    wire sel_pcie   = (cpu_addr[31:8]  == 24'hC000_00);     // 0xC000_0000
    wire sel_pnm    = (cpu_addr[31:8]  == 24'hF000_00);

    assign cpu_error = 1'b0;

    reg [31:0] mux_rdata;
    always @(*) begin
        mux_rdata = 32'h0;
        if (sel_rom)       mux_rdata = rom_rdata;
        else if (sel_uart) mux_rdata = uart_rdata;
        else if (sel_clint) mux_rdata = clint_rdata;
        else if (sel_gating) mux_rdata = gating_rdata;
        else if (sel_dram)  mux_rdata = dram_rdata;
        else if (sel_pcie)  mux_rdata = pcie_rdata;
        else if (sel_pnm)   mux_rdata = pnm_rdata;
    end

    assign cpu_rdata = mux_rdata;

    // DRAM has multi-cycle latency; all other slaves are single-cycle
    assign cpu_ready = (sel_dram && !dram_ready) ? 1'b0 :
                       (sel_rom | sel_uart | sel_clint | sel_gating |
                        sel_dram | sel_pcie | sel_pnm);

    // =========================================================================
    // CPU Core (RV32IMA — production upgrades to RV32IMAFC)
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
    // System DRAM (LPDDR5 stub — behavioral array with CAS latency)
    //
    // Address space: 0x8000_0000 .. 0x9FFF_FFFF (512MB window).
    // Simulated array: DRAM_WORDS x 32 bits. Production replaces this
    // block with a hard LPDDR5 controller driving external DRAM chips.
    // The CAS latency models the row activate + column read delay.
    // =========================================================================
    reg [31:0] dram_mem [0:DRAM_WORDS-1];

    reg [7:0]  dram_wait_cnt;
    reg        dram_pending_rd;
    reg        dram_pending_wr;
    reg [3:0]  dram_wr_be;
    reg [31:0] dram_wr_data;
    reg [31:0] dram_wr_addr;
    reg [31:0] dram_rd_addr;

    wire [31:0] dram_offset = {2'b00, cpu_addr[28:2]};

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
                dram_wr_be   <= cpu_be;
                dram_wr_data <= cpu_wdata;
                dram_wr_addr <= dram_offset;
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
    // MoE Gating Weight SRAM (64KB = 32K BF16 entries)
    // =========================================================================
    reg [15:0] gating_sram [0:GATING_ENTRIES-1];

    always @(*) begin
        if (sel_gating)
            gating_rdata = {gating_sram[{cpu_addr[16:1], 1'b1}],
                            gating_sram[{cpu_addr[16:1], 1'b0}]};
        else
            gating_rdata = 32'h0;
    end

    always @(posedge clk) begin
        if (sel_gating && cpu_valid && cpu_we) begin
            if (cpu_be[0]) gating_sram[{cpu_addr[16:1], 1'b0}][7:0]  <= cpu_wdata[7:0];
            if (cpu_be[1]) gating_sram[{cpu_addr[16:1], 1'b0}][15:8] <= cpu_wdata[15:8];
            if (cpu_be[2]) gating_sram[{cpu_addr[16:1], 1'b1}][7:0]  <= cpu_wdata[23:16];
            if (cpu_be[3]) gating_sram[{cpu_addr[16:1], 1'b1}][15:8] <= cpu_wdata[31:24];
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

    // IRQ wiring
    wire [15:0] cpu_irq;
    assign cpu_irq[0]  = uart_irq;
    assign cpu_irq[1]  = clint_mtip;
    assign cpu_irq[2]  = clint_msip;
    assign cpu_irq[3]  = spine_extract_valid;
    assign cpu_irq[4]  = pcie_out_valid;
    assign cpu_irq[15:5] = ext_irq[15:5];

    // =========================================================================
    // MoE Gating Unit (computes top-K from hidden state)
    // =========================================================================
    wire        mg_start;
    wire        mg_done;
    wire [9:0]  mg_hidden_addr;
    wire [15:0] mg_hidden_data;
    wire        mg_weight_load;
    wire [9:0]  mg_weight_addr;
    wire [15:0] mg_weight_data;
    wire [7:0]  mg_current_layer;
    wire [TOP_K*8-1:0]  mg_expert_idx;
    wire [TOP_K*16-1:0] mg_expert_logit;
    wire [TOP_K*8-1:0]  mg_expert_layer;
    wire [TOP_K*8-1:0]  mg_expert_module;

    // Hidden state buffer: firmware writes token's hidden vector here
    reg [15:0] hidden_buf [0:HIDDEN_SIZE-1];

    assign mg_hidden_data = (mg_hidden_addr < HIDDEN_SIZE) ?
                            hidden_buf[mg_hidden_addr] : 16'h0;

    // Weight data comes from the gating SRAM
    assign mg_weight_data = (mg_weight_addr < GATING_ENTRIES) ?
                            gating_sram[mg_weight_addr] : 16'h0;

    // Control registers (CPU-programmed via PNM extension)
    reg        mg_trigger;      // CPU writes PNM_GATING_START
    reg        mg_active;
    reg [7:0]  mg_layer_reg;

    assign mg_start = mg_trigger && !mg_active;
    assign mg_current_layer = mg_layer_reg;

    moe_gating #(
        .NUM_EXPERTS(MAX_EXPERTS),
        .HIDDEN_DIM(64),          // gating projection dim (not full hidden)
        .TOP_K(TOP_K),
        .ADDR_BITS(10)
    ) u_moe_gating (
        .clk(clk), .rst_n(rst_n),
        .start(mg_start),
        .done(mg_done),
        .hidden_addr(mg_hidden_addr),
        .hidden_data(mg_hidden_data),
        .weight_load(1'b0),       // weights loaded via CPU writes to SRAM
        .weight_addr(mg_weight_addr),
        .weight_data(mg_weight_data),
        .current_layer(mg_current_layer),
        .moe_layer_in(8'h0),
        .moe_module_in(8'h0),
        .expert_idx_packed(mg_expert_idx),
        .expert_logit_packed(mg_expert_logit),
        .expert_layer_packed(mg_expert_layer),
        .expert_module_packed(mg_expert_module)
    );

    // When gating completes, latch results into CPU-readable registers
    reg [TOP_K*8-1:0]  gate_result_idx;
    reg [TOP_K*16-1:0] gate_result_logit;
    reg [TOP_K*8-1:0]  gate_result_layer;
    reg [TOP_K*8-1:0]  gate_result_module;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mg_trigger <= 1'b0;
            mg_active  <= 1'b0;
            mg_layer_reg <= 8'h0;
            gate_result_idx    <= {(TOP_K*8){1'b0}};
            gate_result_logit  <= {(TOP_K*16){1'b0}};
            gate_result_layer  <= {(TOP_K*8){1'b0}};
            gate_result_module <= {(TOP_K*8){1'b0}};
        end else begin
            if (mg_start) mg_active <= 1'b1;
            if (mg_done) begin
                mg_active           <= 1'b0;
                mg_trigger          <= 1'b0;
                gate_result_idx     <= mg_expert_idx;
                gate_result_logit   <= mg_expert_logit;
                gate_result_layer   <= mg_expert_layer;
                gate_result_module  <= mg_expert_module;
            end
        end
    end

    // =========================================================================
    // PCIe Gen5 Endpoint Register Stub
    //
    // Production silicon integrates a Gen5 PHY + DMA controller. This stub
    // provides the register interface so firmware can be developed before
    // the physical layer exists. Writes to PCIE_TX push bytes toward the
    // host; reads from PCIE_RX pull bytes from the host.
    // =========================================================================
    reg [7:0]  pcie_tx_fifo [0:63];
    reg [7:0]  pcie_rx_fifo [0:63];
    reg [5:0]  pcie_tx_wptr, pcie_tx_rptr;
    reg [5:0]  pcie_rx_wptr, pcie_rx_rptr;
    reg [31:0] pcie_status;

    wire [7:0] pcie_addr = cpu_addr[7:0];
    wire pcie_tx_full  = ({~pcie_tx_wptr[5], pcie_tx_wptr[4:0]} == {pcie_tx_rptr[5], pcie_tx_rptr[4:0]});
    wire pcie_rx_empty = (pcie_rx_wptr == pcie_rx_rptr);

    assign pcie_in_ready  = !pcie_rx_empty || pcie_in_valid;
    assign pcie_out_data  = pcie_tx_fifo[pcie_tx_rptr];
    assign pcie_out_valid = (pcie_tx_rptr != pcie_tx_wptr);
    assign pcie_out_sop   = (pcie_tx_rptr == 6'd0);
    assign pcie_out_eop   = (pcie_tx_rptr + 6'd1 == pcie_tx_wptr);

    always @(*) begin
        pcie_rdata = 32'h0;
        case (pcie_addr)
            8'h00: pcie_rdata = {24'h0, pcie_status};
            8'h04: pcie_rdata = {24'h0,
                                 pcie_tx_full, ~pcie_rx_empty,
                                 5'h0, pcie_rx_fifo[pcie_rx_rptr]};
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcie_tx_wptr <= 6'd0; pcie_tx_rptr <= 6'd0;
            pcie_rx_wptr <= 6'd0; pcie_rx_rptr <= 6'd0;
            pcie_status  <= 32'h0;
        end else begin
            if (sel_pcie && cpu_valid && cpu_we) begin
                case (pcie_addr)
                    8'h08: begin  // PCIE_TX: write byte to TX FIFO
                        if (!pcie_tx_full) begin
                            pcie_tx_fifo[pcie_tx_wptr] <= cpu_wdata[7:0];
                            pcie_tx_wptr <= pcie_tx_wptr + 1;
                        end
                    end
                    8'h0C: begin  // PCIE_RX_POP: advance RX read pointer
                        if (!pcie_rx_empty)
                            pcie_rx_rptr <= pcie_rx_rptr + 1;
                    end
                    8'h10: pcie_status <= cpu_wdata;
                    default: ;
                endcase
            end

            // Host pushes data into RX FIFO
            if (pcie_in_valid) begin
                pcie_rx_fifo[pcie_rx_wptr] <= pcie_in_data;
                pcie_rx_wptr <= pcie_rx_wptr + 1;
            end

            // TX consumed by host
            if (pcie_out_valid && pcie_out_ready)
                pcie_tx_rptr <= pcie_tx_rptr + 1;
        end
    end

    // =========================================================================
    // PNM Router Engine (same flit builder as bmc_orchestrator_top)
    // Extended with MoE gating trigger/result registers.
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

    // PNM extended register offsets (MoE gating)
    localparam PNMG_HIDDEN_BASE   = 8'h30;  // write hidden_buf[hpos]
    localparam PNMG_GATING_START  = 8'h34;  // write 1 to trigger
    localparam PNMG_RESULT_IDX0   = 8'h38;  // top-K expert indices (bytes 0-3)
    localparam PNMG_RESULT_IDX1   = 8'h3C;  // top-K expert indices (bytes 4-7)

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
                    PNMG_HIDDEN_BASE: begin
                        // Simplified: write one BF16 halfword per access
                        hidden_buf[route_wpos] <= cpu_wdata[15:0];
                        route_wpos <= route_wpos + 1;
                    end
                    PNMG_GATING_START: mg_trigger <= 1'b1;
                    default: ;
                endcase
            end

            // Flit builder FSM
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
                    PNMG_GATING_START: pnm_rdata <= {30'h0, mg_active, mg_done};
                    PNMG_RESULT_IDX0:  pnm_rdata <= gate_result_idx[TOP_K*8-1 -: 32];
                    PNMG_RESULT_IDX1:  pnm_rdata <= {{(32-TOP_K*8>0)?(32-TOP_K*8):1{1'b0}}, gate_result_idx};
                    default: ;
                endcase
            end
        end
    end

endmodule
