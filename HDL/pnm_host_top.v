`include "pnm_defs.vh"

// =============================================================================
// pnm_host_top — the host bridge board's top level
//
// This is the module that composes the host path end to end:
//
//     host (Pi over SPI, or a 3rd-party MCU)
//       -> pi_bridge      (SPI slave -> PNM bus master)
//       -> pnm_arb        (round-robin arbiter onto the shared window)
//       -> pnm_host_bridge (the router engine + SRAM + register window)
//       -> spine_inject_*  (into the fabric)
//
// Until this module existed, each piece was checked against a *model* of the
// next: tb_host_bmc.v and tb_dma_lpddr6.v drove pi_bridge and pnm_arb into
// register files they defined in the testbench, and tb_pnm_host_bridge.v drove
// the bridge alone.  The composition (the actual host path) was never
// simulated, and it did not work: the arbiter presents an 8-bit byte offset
// while the bridge decodes a 32-bit address, so nothing was ever selected,
// and the bridge's registered read data was sampled by the arbiter one cycle
// before it was updated, so every register read returned zero.
//
// This wrapper owns the address map.  The SPI adapter and the arbiter both
// work in byte offsets within the PNM window; the bridge decodes a full
// 32-bit address, so the base is applied here, in one place.
//
// The 64 KB staging SRAM is at 0x8000_0000 and the PNM register window at
// 0xF000_0000.  A byte offset of 0x00..0x3F selects the PNM window; the
// SRAM window is reached through the arbiter's extended space (offsets
// 0x80 and above map to 0x8000_0000 + (offset - 0x80)).
// =============================================================================

module pnm_host_top #(
    // The window's base addresses.  The host's firmware uses these.
    parameter [31:0] PNM_BASE  = 32'hF000_0000,
    parameter [31:0] SRAM_BASE = 32'h8000_0000,
    // The first byte offset that selects the SRAM window instead of the PNM
    // register window.
    parameter [7:0]  SRAM_SEL  = 8'h80
)(
    input  wire        clk,
    input  wire        rst_n,

    // Host link: SPI slave (a Raspberry Pi over the SPI adapter)
    input  wire        sclk,
    input  wire        mosi,
    input  wire        cs_n,
    output wire        miso,
    output wire        irq_out,

    // Host link: the native host bus (a 3rd-party MCU or a workstation
    // that drives the register window directly)
    input  wire [31:0] native_addr,
    input  wire [31:0] native_wdata,
    output wire [31:0] native_rdata,
    input  wire [3:0]  native_be,
    input  wire        native_we,
    input  wire        native_valid,
    output wire        native_ready,

    // Fabric
    output wire [7:0]  spine_inject_data,
    output wire        spine_inject_valid,
    output wire        spine_inject_sop,
    output wire        spine_inject_eop,
    output wire [1:0]  spine_inject_vc,
    input  wire        spine_inject_ready,
    input  wire [7:0]  spine_extract_data,
    input  wire        spine_extract_valid,
    input  wire        spine_extract_sop,
    input  wire        spine_extract_eop,
    input  wire [1:0]  spine_extract_vc,

    // Status
    output wire        boot_done
);

    // =========================================================================
    // The SPI adapter and the native host bus are two masters onto the same
    // arbiter.  The SPI path wins when it is active; the native path is
    // served otherwise.  Both present the same valid/ready handshake.
    // =========================================================================
    wire [7:0]  spi_addr;
    wire [31:0] spi_wdata;
    wire [31:0] spi_rdata;
    wire        spi_we;
    wire        spi_valid;
    wire        spi_ready;

    wire [7:0]  nat_addr;
    wire [31:0] nat_wdata;
    wire [31:0] nat_rdata;
    wire        nat_we;
    wire        nat_valid;
    wire        nat_ready;

    wire [7:0]  slv_addr;
    wire [31:0] slv_wdata;
    wire [31:0] slv_rdata;
    wire        slv_we;
    wire        slv_valid;
    wire        slv_ready;

    // The arbiter's master-0 port is the SPI adapter, master-1 the native
    // host bus.  (The arbiter's original master 0 was the chip's own CPU,
    // which the CPU-less bridge removed; the port is reused here for the
    // native host bus so the arbiter still arbitrates two real masters.)
    pnm_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .cpu_addr(nat_addr), .cpu_wdata(nat_wdata), .cpu_rdata(nat_rdata),
        .cpu_we(nat_we), .cpu_valid(nat_valid), .cpu_ready(nat_ready),
        .brg_addr(spi_addr), .brg_wdata(spi_wdata), .brg_rdata(spi_rdata),
        .brg_we(spi_we), .brg_valid(spi_valid), .brg_ready(spi_ready),
        .slv_addr(slv_addr), .slv_wdata(slv_wdata), .slv_rdata(slv_rdata),
        .slv_we(slv_we), .slv_valid(slv_valid), .slv_ready(slv_ready)
    );

    // =========================================================================
    // The address map: the one place that knows how a host's byte offset
    // becomes a full address.
    // =========================================================================
    wire [31:0] host_addr = (slv_addr >= SRAM_SEL) ?
                            (SRAM_BASE + {16'h0, slv_addr} - {16'h0, SRAM_SEL}) :
                            (PNM_BASE + {16'h0, slv_addr});

    wire [31:0] host_rdata;

    pnm_host_bridge u_bridge (
        .clk(clk), .rst_n(rst_n),
        .host_addr(host_addr),
        .host_wdata(slv_wdata),
        .host_rdata(host_rdata),
        .host_we(slv_we),
        .host_be(4'hF),
        .host_valid(slv_valid),
        .host_ready(slv_ready),
        .topology_rdy(64'b0),
        .spine_inject_data(spine_inject_data),
        .spine_inject_valid(spine_inject_valid),
        .spine_inject_sop(spine_inject_sop),
        .spine_inject_eop(spine_inject_eop),
        .spine_inject_ready(spine_inject_ready),
        .spine_inject_vc(spine_inject_vc),
        .spine_extract_data(spine_extract_data),
        .spine_extract_valid(spine_extract_valid),
        .spine_extract_sop(spine_extract_sop),
        .spine_extract_eop(spine_extract_eop),
        .spine_extract_vc(spine_extract_vc),
        .boot_done(boot_done)
    );

    assign slv_rdata = host_rdata;

    // =========================================================================
    // The SPI adapter.  It is optional: a board that drives the native host
    // bus directly (a 3rd-party MCU, a workstation) can leave the SPI pins
    // idle and never assert CS.
    // =========================================================================
    pi_bridge u_spi (
        .clk(clk), .rst_n(rst_n),
        .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .miso(miso), .irq_out(irq_out),
        .pnm_addr(spi_addr), .pnm_wdata(spi_wdata), .pnm_rdata(spi_rdata),
        .pnm_we(spi_we), .pnm_valid(spi_valid), .pnm_ready(spi_ready)
    );

    // The native host bus presents a 32-bit address; the arbiter works in
    // byte offsets, so the window is folded back down here.  A native host
    // that addresses 0xF000_00xx or 0x8000_00xx sees the same window the
    // SPI path does.
    assign nat_addr = (native_addr[31:16] == 16'hF000) ? native_addr[7:0] :
                      (native_addr[31:16] == 16'h8000) ?
                      (SRAM_SEL + native_addr[7:0]) : native_addr[7:0];
    assign nat_wdata = native_wdata;
    assign nat_we    = native_we;
    assign nat_valid = native_valid;
    assign native_rdata = nat_rdata;
    assign native_ready = nat_ready;

endmodule
