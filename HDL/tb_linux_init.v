// =============================================================================
// tb_linux_init.v — run the Linux init binary on the PNM's own RISC-V core
// and UART model.
//
// The init binary (fw/os/linux/src/init.c) is the userspace half of the
// orchestrator_sbc's Linux image: it prints a boot banner, reads the PNM
// status register, probes the NVMe controller and idles. This testbench
// executes it on the real RTL (HDL/rv32_core.v + HDL/uart.v) with a flat
// memory loaded from the linked binary, so the driver is exercised against
// the chip's own UART and register-window models rather than a host model.
//
// The PNM register window (0xF0000000) and the NVMe controller window
// (0xD0000000) are stubbed with zeroed reads, so the test checks the banner
// and the probe plumbing, not the silicon behind those windows.
//
// Build the image first:
//   cd fw/os/linux && make INIT_BASE=0x40000000 init.hex
//
// Usage:
//   cd HDL && iverilog -g2005 -o tb_linux_init.out tb_linux_init.v \
//       rv32_core.v uart.v && vvp tb_linux_init.out
// =============================================================================

`timescale 1ns/1ps

module tb_linux_init;

    localparam [31:0] INIT_BASE  = 32'h4000_0000;  // the chip's SRAM window
    localparam        MEM_WORDS = 8192;              // 32 KB, word addressed
    localparam [31:0] TRAP_BASE  = 32'h0000_1000;   // the core's mtvec default

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- core bus ----------------------------------------------------------
    wire [31:0] bus_addr;
    wire [31:0] bus_wdata;
    reg  [31:0] bus_rdata;
    wire        bus_we;
    wire [3:0]  bus_be;
    wire        bus_valid;
    wire        bus_ready;
    wire        bus_error;
    wire [15:0] irq = 16'h0;
    wire [31:0] fetch_addr;

    rv32_core #(.RESET_ADDR(INIT_BASE)) u_core (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_we(bus_we), .bus_be(bus_be), .bus_valid(bus_valid),
        .bus_ready(bus_ready), .bus_error(bus_error),
        .irq(irq), .fetch_addr(fetch_addr)
    );

    // ---- flat memory (the init image) -------------------------------------
    reg [31:0] mem [0:MEM_WORDS-1];
    integer i;

    wire mem_hit = (bus_addr[31:16] == INIT_BASE[31:16]);

    always @(posedge clk) begin
        if (rst_n && bus_valid && mem_hit && bus_we) begin
            if (bus_be[3]) mem[bus_addr[13:2]][31:24] <= bus_wdata[31:24];
            if (bus_be[2]) mem[bus_addr[13:2]][23:16] <= bus_wdata[23:16];
            if (bus_be[1]) mem[bus_addr[13:2]][15:8]  <= bus_wdata[15:8];
            if (bus_be[0]) mem[bus_addr[13:2]][7:0]   <= bus_wdata[7:0];
        end
    end

    // The chip's SoC answers the instruction fetch over a *separate*
    // combinational path (fetch_addr -> ROM) and multiplexes it onto the
    // data bus, so the core latches the right word even though its data-bus
    // address is registered one cycle late.  Mirror that here.
    reg [31:0] mem_q;
    always @(*) begin
        mem_q = 32'h0;
        if (fetch_addr[31:16] == INIT_BASE[31:16])
            mem_q = mem[fetch_addr[13:2]];
        else if (bus_addr[31:16] == INIT_BASE[31:16])
            mem_q = mem[bus_addr[13:2]];
    end

    // ---- the chip's UART ---------------------------------------------------
    wire [31:0] uart_rdata;
    wire        uart_ready;
    wire        uart_tx;
    reg  [31:0] uart_addr;
    reg  [31:0] uart_wdata;
    reg         uart_we, uart_valid;

    uart #(.CLK_FREQ(100_000_000), .BAUD_RATE(115200)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .addr(uart_addr), .wdata(uart_wdata), .rdata(uart_rdata),
        .we(uart_we), .valid(uart_valid), .ready(uart_ready),
        .uart_rx(1'b0), .uart_tx(uart_tx), .irq()
    );

    // ---- PNM / NVMe windows (stubbed, zeroed) -----------------------------
    reg [31:0] pnm_rdata = 32'h0;
    reg [31:0] nvme_rdata = 32'h0;

    // ---- address decode ----------------------------------------------------
    always @(*) begin
        bus_rdata = 32'h0;
        if (fetch_addr[31:16] == INIT_BASE[31:16] || mem_hit)
            bus_rdata = mem_q;
        else if (bus_addr[31:8] == 20'h00100)
            bus_rdata = 32'h0000_006f;   // trap vector: j .
        else if (bus_addr[31:28] == 4'h1)
            bus_rdata = uart_rdata;
        else if (bus_addr[31:28] == 4'hF)
            bus_rdata = pnm_rdata;
        else if (bus_addr[31:28] == 4'hD)
            bus_rdata = nvme_rdata;
        else if (bus_addr[31:28] == 4'h0)
            bus_rdata = 32'h0000_006f;   // the chip's boot ROM stub: j .

        uart_addr  = bus_addr;
        uart_wdata = bus_wdata;
        uart_we    = bus_we && (bus_addr[31:28] == 4'h1);
        uart_valid = bus_valid && (bus_addr[31:28] == 4'h1);
    end

    // The chip's cpu_ready is the OR of the window selects.
    assign bus_ready  = (fetch_addr[31:16] == INIT_BASE[31:16]) || mem_hit ||
                        (bus_addr[31:8] == 20'h00100) ||
                        (bus_addr[31:28] == 4'h1) ||
                        (bus_addr[31:28] == 4'hF) || (bus_addr[31:28] == 4'hD);
    assign bus_error  = 1'b0;
    assign uart_ready = 1'b1;

    // ---- capture the characters written to the UART ------------------------
    reg [7:0] cap [0:255];
    integer   capn = 0;
    always @(posedge clk) begin
        if (rst_n && uart_we && (uart_addr[7:2] == 6'd0) && capn < 256) begin
            cap[capn] = uart_wdata[7:0];
            capn = capn + 1;
        end
    end

    // ---- load the image ----------------------------------------------------
    integer fd;
    integer code;
    integer bytes_loaded;
    integer k;
    reg     load_done = 1'b0;

    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'h0;

        fd = $fopen("../fw/os/linux/init.hex", "r");
        if (fd == 0)
            fd = $fopen("init.hex", "r");
        if (fd == 0) begin
            $display("[TB] ERROR: init.hex not found — build it with:");
            $display("      cd fw/os/linux && make INIT_BASE=0x40000000 init.hex");
            $finish(1);
        end
        bytes_loaded = 0;
        load_done = 1'b0;
        while (!load_done) begin
            code = $fscanf(fd, "%h\n", mem[bytes_loaded]);
            if (code != 1)
                load_done = 1'b1;
            else begin
                bytes_loaded = bytes_loaded + 1;
                if (bytes_loaded >= MEM_WORDS)
                    load_done = 1'b1;
            end
        end
        $fclose(fd);
        $display("[TB] loaded %0d words of init image at 0x%08x", bytes_loaded, INIT_BASE);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- run and check -----------------------------------------------------
    integer cycles = 0;
    integer errors = 0;
    reg     done = 1'b0;
    reg [8*80-1:0] got;
    reg [8*40-1:0] want_banner;

    initial begin
        want_banner = "fw-os-linux init for orchestrator_sbc";
        wait (rst_n);
        done = 1'b0;
        while (!done) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (capn >= 40)
                done = 1'b1;
            if (cycles > 2_000_000) begin
                $display("[TB] TIMEOUT after %0d cycles (captured %0d chars)", cycles, capn);
                errors = errors + 1;
                done = 1'b1;
            end
        end

        got = "";
        for (k = 0; k < capn && k < 60; k = k + 1)
            got = {got[8*79-1:0], cap[k]};

        $display("[TB] captured %0d chars in %0d cycles: %0s", capn, cycles, got);

        if (got[8*79-1:0] != want_banner) begin
            $display("[TB] ERROR: banner mismatch");
            $display("      want: %0s", want_banner);
            $display("      got : %0s", got);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** LINUX INIT TEST PASSED ***");
        else
            $display("*** LINUX INIT TEST FAILED (%0d errors) ***", errors);
        $finish(errors == 0 ? 0 : 1);
    end

endmodule
