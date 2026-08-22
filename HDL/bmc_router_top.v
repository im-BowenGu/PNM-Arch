// =============================================================================
// bmc_router_top — RISC-V BMC / Router Chip SoC
//
// Integrates:
//   - RV32IMA multi-cycle CPU core (rv32_core.v)
//   - 64KB boot ROM (instruction memory, initialized by testbench)
//   - 64KB SRAM (data memory)
//   - 16550-compatible UART (uart.v)
//   - Core Local Interruptor with timer (clint.v)
//   - PNM router engine (flit builder + spine injection/extraction)
//
// Memory map:
//   0x0000_0000 - 0x0000_FFFF  Boot ROM (64KB, read-only)
//   0x1000_0000 - 0x1000_001F  UART0
//   0x2000_0000 - 0x2000_BFFF  CLINT
//   0x8000_0000 - 0x8000_FFFF  SRAM (64KB, read-write)
//   0xF000_0000 - 0xF000_003F  PNM router registers
//       0x00: ROUTE_CTRL      (write 1 to trigger flit injection)
//       0x04: ROUTE_LAYER     (layer ID for next flit)
//       0x08: ROUTE_MODULE    (module ID for next flit)
//       0x0C: ROUTE_LEN       (payload length in bytes)
//       0x10: ROUTE_DATA      (write payload bytes, auto-increment)
//       0x14: ROUTE_STATUS    (bit 0=busy, bit 1=done)
//       0x18: ROUTE_RESULT    (read result bytes from spine)
//       0x1C: ROUTE_ERRORS    (CRC/framing error count)
//       0x20: ROUTE_DISPATCH  (dispatch counter, read)
//       0x24: ROUTE_WEIGHTS   (weight flit counter, read)
//
// The PNM router engine is a simplified version of router_chip.v,
// driven by CPU register writes instead of a host PCIe stream.
// The CPU firmware boot sequence:
//   1. POST discovery (poll topology_rdy)
//   2. Load routing tables
//   3. Upload weights
//   4. Load MoE gating weights
//   5. Signal boot_done
//   6. Begin inference dispatch loop
// =============================================================================

module bmc_router_top #(
    parameter CLK_FREQ    = 100_000_000,
    parameter BAUD_RATE   = 115200,
    parameter NUM_LAYERS  = 4,
    parameter BOARD_X     = 4,
    parameter BOARD_Y     = 4,
    parameter NUM_NODES   = NUM_LAYERS * BOARD_X * BOARD_Y,
    parameter MAX_EXPERTS = 128,
    parameter TOP_K       = 8,
    parameter HIDDEN_SIZE = 2816
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART
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
    input  wire [15:0] ext_irq,

    // Status
    output wire        boot_done
);

    // =========================================================================
    // Bus interconnect signals
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
    reg [31:0] sram_rdata;
    wire [31:0] uart_rdata;
    wire [31:0] clint_rdata;
    reg [31:0] pnm_rdata;
    wire [31:0] cpu_fetch_addr;

    // Slave selects (active-high, combinational from fetch_addr or bus_addr)
    wire sel_rom  = (cpu_fetch_addr[31:16] == 16'h0000);  // ROM uses fetch_addr (pc)
    wire sel_uart = (cpu_addr[31:8]  == 24'h1000_00);     // 0x1000_0000
    wire sel_clint= (cpu_addr[31:16] == 16'h2000);        // 0x2000_0000
    wire sel_sram = (cpu_addr[31:16] == 16'h8000);        // 0x8000_0000
    wire sel_pnm  = (cpu_addr[31:8]  == 24'hF000_00);     // 0xF000_0000

    assign cpu_error = 1'b0;

    // Mux read data based on slave select
    reg [31:0] mux_rdata;
    always @(*) begin
        mux_rdata = 32'h0;
        if (sel_rom)   mux_rdata = rom_rdata;
        else if (sel_uart) mux_rdata = uart_rdata;
        else if (sel_clint) mux_rdata = clint_rdata;
        else if (sel_sram) mux_rdata = sram_rdata;
        else if (sel_pnm)  mux_rdata = pnm_rdata;
    end

    assign cpu_rdata = mux_rdata;

    // Ready: any selected slave is ready
    assign cpu_ready = sel_rom | sel_uart | sel_clint | sel_sram | sel_pnm;

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
    // Boot ROM (64KB, word-addressable)
    // =========================================================================
    reg [31:0] rom [0:16383];  // 64KB / 4 = 16K words
    // Combinational ROM read using fetch_addr (combinational PC)
    always @(*) begin
        rom_rdata = rom[cpu_fetch_addr[15:2]];
    end

    // =========================================================================
    // SRAM (64KB, word-addressable, byte-enable write)
    // =========================================================================
    reg [31:0] sram [0:16383];
    // Combinational SRAM read (for loads)
    always @(*) begin
        if (sel_sram)
            sram_rdata = sram[cpu_addr[15:2]];
        else
            sram_rdata = 32'h0;
    end

    // Synchronous SRAM write
    always @(posedge clk) begin
        if (sel_sram && cpu_valid && cpu_we) begin
            if (cpu_be[0]) sram[cpu_addr[15:2]][7:0]   <= cpu_wdata[7:0];
            if (cpu_be[1]) sram[cpu_addr[15:2]][15:8]  <= cpu_wdata[15:8];
            if (cpu_be[2]) sram[cpu_addr[15:2]][23:16] <= cpu_wdata[23:16];
            if (cpu_be[3]) sram[cpu_addr[15:2]][31:24] <= cpu_wdata[31:24];
        end
    end

    // =========================================================================
    // UART
    // =========================================================================
    wire        uart_irq;
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

    // =========================================================================
    // CLINT (timer + software interrupt)
    // =========================================================================
    wire        clint_mtip;
    wire        clint_msip;
    clint #(
        .CLK_FREQ(CLK_FREQ),
        .TIMER_PERIOD(CLK_FREQ / 10)  // 100ms tick
    ) u_clint (
        .clk    (clk),
        .rst_n  (rst_n),
        .addr   (cpu_addr),
        .wdata  (cpu_wdata),
        .rdata  (clint_rdata),
        .we     (cpu_we),
        .be     (cpu_be),
        .valid  (sel_clint && cpu_valid),
        .ready  (),
        .msip   (clint_msip),
        .mtip   (clint_mtip)
    );

    // Wire CLINT interrupts to CPU external IRQ lines
    // irq[0] = UART, irq[1] = CLINT timer, irq[2] = CLINT software
    wire [15:0] cpu_irq;
    assign cpu_irq[0]  = uart_irq;
    assign cpu_irq[1]  = clint_mtip;
    assign cpu_irq[2]  = clint_msip;
    assign cpu_irq[15:3] = ext_irq[15:3];

    // =========================================================================
    // PNM Router Engine (CPU-register-driven flit builder)
    // =========================================================================
    localparam CTRL_COMPUTE = 8'h80;  // VC_SPINE | OP_COMPUTE
    localparam CTRL_FORWARD = 8'h90;  // VC_SPINE | OP_FORWARD
    localparam REQ_MODULE   = 8'hEE;
    localparam VC_DESCENT   = 2'b10;

    // Router register file
    reg [7:0]  route_layer;
    reg [7:0]  route_module;
    reg [15:0] route_len;
    reg [15:0] route_pos;
    reg [31:0] route_errors;
    reg [31:0] route_dispatches;
    reg [31:0] route_weight_flits;
    reg        boot_done_r;
    assign boot_done = boot_done_r;

    // Flit builder state
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

    wire       fb_out_ready = spine_inject_ready;
    wire       pnm_busy = fb_active;

    assign spine_inject_data  = fb_out_data_r;
    assign spine_inject_valid = fb_out_valid_r;
    assign spine_inject_sop   = fb_out_sop_r;
    assign spine_inject_eop   = fb_out_eop_r;
    assign spine_inject_vc    = VC_DESCENT;

    // CRC-16 (matches pnm_crc16 in crc.go / crc16.v)
    function [15:0] crc16_next;
        input [15:0] crc_in;
        input [7:0]  data_in;
        reg [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {data_in, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            crc16_next = crc;
        end
    endfunction

    // PNM register access
    wire [7:0] pnm_addr = cpu_addr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            route_layer        <= 8'h0;
            route_module       <= 8'h0;
            route_len          <= 16'h0;
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

            // CPU register writes
            if (sel_pnm && cpu_valid && cpu_we) begin
                case (pnm_addr)
                    8'h04: route_layer  <= cpu_wdata[7:0];
                    8'h08: route_module <= cpu_wdata[7:0];
                    8'h0C: route_len    <= cpu_wdata[15:0];
                    8'h10: begin  // ROUTE_DATA: write payload byte, auto-increment
                        if (!pnm_busy) begin
                            // Store in a small payload buffer (up to 256 bytes)
                        end
                    end
                    8'h00: begin  // ROUTE_CTRL: trigger injection or boot_done
                        if (cpu_wdata[2])
                            boot_done_r <= 1'b1;
                        if (!pnm_busy && cpu_wdata[0]) begin
                            fb_layer_r  <= route_layer;
                            fb_module_r <= route_module;
                            fb_ctrl     <= CTRL_COMPUTE;
                            fb_len      <= route_len;
                            fb_state    <= FB_HDR;
                            fb_pos      <= 16'h0;
                            fb_crc      <= 16'hFFFF;
                            fb_active   <= 1'b1;
                        end
                    end
                    default: ;
                endcase
            end

            // Flit builder FSM
            case (fb_state)
                FB_IDLE: begin
                    fb_out_valid_r <= 1'b0;
                end

                FB_HDR: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        case (fb_pos)
                            0: begin fb_out_data_r <= fb_layer_r;  fb_out_sop_r <= 1; fb_out_valid_r <= 1; end
                            1: begin fb_out_data_r <= fb_module_r; fb_out_sop_r <= 0; end
                            2: begin fb_out_data_r <= fb_ctrl;    end
                            3: begin fb_out_data_r <= fb_len[7:0];  end
                            4: begin fb_out_data_r <= fb_len[15:8]; end
                        endcase
                        // CRC accumulation (MODULE_ID through LEN)
                        if (fb_pos >= 1 && fb_pos <= 4) begin
                            if (fb_pos == 1)
                                fb_crc <= crc16_next(16'hFFFF, fb_module_r);
                            else if (fb_pos == 2)
                                fb_crc <= crc16_next(fb_crc, fb_ctrl);
                            else if (fb_pos == 3)
                                fb_crc <= crc16_next(fb_crc, fb_len[7:0]);
                            else if (fb_pos == 4)
                                fb_crc <= crc16_next(fb_crc, fb_len[15:8]);
                        end
                        if (fb_pos == 4) begin
                            if (fb_len == 0) begin
                                fb_state <= FB_CRC;
                                fb_pos   <= 0;
                            end else begin
                                fb_state <= FB_PAYLOAD;
                                fb_pos   <= 0;
                            end
                        end else
                            fb_pos <= fb_pos + 1;
                    end
                end

                FB_PAYLOAD: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        // Payload bytes come from the ROUTE_DATA register
                        fb_out_valid_r <= 1;
                        fb_out_sop_r   <= 0;
                        fb_crc         <= crc16_next(fb_crc, route_layer);  // simplified: repeat layer as dummy payload
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
                        fb_out_sop_r   <= 0;
                        if (fb_pos == 0) begin
                            fb_out_data_r <= fb_crc[15:8];
                            fb_out_eop_r  <= 0;
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

            // Collect spine extraction results → to result buffer
            if (spine_extract_valid) begin
                route_dispatches <= route_dispatches + 1;
            end

            // CPU register reads
            pnm_rdata <= 32'h0;
            if (sel_pnm && cpu_valid && !cpu_we) begin
                case (pnm_addr)
                    8'h00: pnm_rdata <= {30'h0, 1'b0, pnm_busy};  // STATUS
                    8'h14: pnm_rdata <= {30'h0, 1'b0, pnm_busy};
                    8'h18: pnm_rdata <= spine_extract_data;
                    8'h1C: pnm_rdata <= route_errors;
                    8'h20: pnm_rdata <= route_dispatches;
                    8'h24: pnm_rdata <= route_weight_flits;
                    default: pnm_rdata <= 32'h0;
                endcase
            end
        end
    end

endmodule
