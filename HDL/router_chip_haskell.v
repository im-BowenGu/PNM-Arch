`include "pnm_defs.vh"

// =============================================================================
// router_chip_haskell — Haskell-optimized Router Chip (FP64 workloads)
//
// Variant of router_chip for Haskell programs requiring FP64 precision.
// Functionally identical to router_chip but parameterized for:
//   - Wider hidden dimension (FP64 doubles the BF16 hidden size)
//   - FP64-weighted MoE gating (double the SRAM for FP64 gating weights)
//   - Dispatch targets nodes with fp64_fma silicon
//
// The dispatch mechanism is the same: tokens arrive via PCIe, are wrapped
// in wormhole flits, and injected into the spine. The MoE gating unit
// computes router.proj · hidden in FP64, selects top-k experts, and
// dispatches to the appropriate nodes.
//
// All internal state is SRAM-backed; the chip is programmed by the host
// driver at boot (firmware phase 2, see pnm_fw_haskell.c).
// =============================================================================
module router_chip_haskell #(
    parameter NUM_LAYERS   = 4,
    parameter BOARD_X      = 4,
    parameter BOARD_Y      = 4,
    parameter NUM_NODES    = NUM_LAYERS * BOARD_X * BOARD_Y,
    parameter MAX_EXPERTS  = 128,
    parameter TOP_K        = 8,
    parameter HIDDEN_SIZE  = 5632,    // FP64: 2x BF16 hidden (2816*2)
    parameter VENDOR_ID    = 16'h4D50 // "MP" for Memory-Processor
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- PCIe ingress (host -> router) ------------------------------------
    input  wire [7:0]  pcie_in_data,
    input  wire        pcie_in_valid,
    input  wire        pcie_in_sop,
    input  wire        pcie_in_eop,
    output wire        pcie_in_ready,

    // -- PCIe egress (router -> host) -------------------------------------
    output wire [7:0]  pcie_out_data,
    output wire        pcie_out_valid,
    output wire        pcie_out_sop,
    output wire        pcie_out_eop,
    input  wire        pcie_out_ready,

    // -- Spine injection port (connects to pnm_top inject_data) ----------
    output wire [7:0]  spine_inject_data,
    output wire        spine_inject_valid,
    output wire        spine_inject_sop,
    output wire        spine_inject_eop,
    input  wire        spine_inject_ready,
    output wire [1:0]  spine_inject_vc,

    // -- Spine extraction port (receives from pnm_top tail_up) -----------
    input  wire [7:0]  spine_extract_data,
    input  wire        spine_extract_valid,
    input  wire        spine_extract_sop,
    input  wire        spine_extract_eop,
    input  wire [1:0]  spine_extract_vc,

    // -- POST discovery sideband -----------------------------------------
    input  wire [NUM_NODES-1:0] topology_rdy,

    // -- Status ----------------------------------------------------------
    output wire        boot_done,
    output wire [31:0] dispatches,
    output wire [31:0] weight_flits,
    output wire [31:0] errors
);

    // Instantiate the base router chip with Haskell FP64 parameters.
    // The base module handles all dispatch logic; the only difference
    // is the larger HIDDEN_SIZE for FP64 gating weights.
    router_chip #(
        .NUM_LAYERS  (NUM_LAYERS),
        .BOARD_X     (BOARD_X),
        .BOARD_Y     (BOARD_Y),
        .NUM_NODES   (NUM_NODES),
        .MAX_EXPERTS (MAX_EXPERTS),
        .TOP_K       (TOP_K),
        .HIDDEN_SIZE (HIDDEN_SIZE),
        .VENDOR_ID   (VENDOR_ID)
    ) u_base (
        .clk              (clk),
        .rst_n            (rst_n),
        .pcie_in_data     (pcie_in_data),
        .pcie_in_valid    (pcie_in_valid),
        .pcie_in_sop      (pcie_in_sop),
        .pcie_in_eop      (pcie_in_eop),
        .pcie_in_ready    (pcie_in_ready),
        .pcie_out_data    (pcie_out_data),
        .pcie_out_valid   (pcie_out_valid),
        .pcie_out_sop     (pcie_out_sop),
        .pcie_out_eop     (pcie_out_eop),
        .pcie_out_ready   (pcie_out_ready),
        .spine_inject_data  (spine_inject_data),
        .spine_inject_valid (spine_inject_valid),
        .spine_inject_sop   (spine_inject_sop),
        .spine_inject_eop   (spine_inject_eop),
        .spine_inject_ready (spine_inject_ready),
        .spine_inject_vc    (spine_inject_vc),
        .spine_extract_data  (spine_extract_data),
        .spine_extract_valid (spine_extract_valid),
        .spine_extract_sop   (spine_extract_sop),
        .spine_extract_eop   (spine_extract_eop),
        .spine_extract_vc    (spine_extract_vc),
        .topology_rdy     (topology_rdy),
        .boot_done        (boot_done),
        .dispatches       (dispatches),
        .weight_flits     (weight_flits),
        .errors           (errors)
    );

endmodule
