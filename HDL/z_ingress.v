`include "pnm_defs.vh"

// =============================================================================
// z_ingress — Z-axis Ingress ASIC (one per motherboard layer)
// Paper §2.1
//
// Compares the LAYER_ID header byte against the local hardware ID bitmask
// and gates matching packets onto the local X/Y NoB. Non-matching packets
// proceed down the spine unchanged.
//
// The LAYER_ID byte is stripped on the match path so the NoB stream starts
// at MODULE_ID (ready for dimension-order X/Y gates).
//
// Up-spine traffic uses a mirrored instance (same module, reverse wiring).
// =============================================================================
module z_ingress #(
    parameter [7:0] LOCAL_LAYER = 8'h00,
    parameter [7:0] LAYER_MASK  = 8'hFF
)(
    input  wire       clk,
    input  wire       rst_n,

    // from up-spine
    input  wire [7:0] spin_data,
    input  wire       spin_valid,
    input  wire       spin_sop,
    input  wire       spin_eop,
    output wire       spin_ready,

    // to down-spine
    output wire [7:0] spout_data,
    output wire       spout_valid,
    output wire       spout_sop,
    output wire       spout_eop,
    input  wire       spout_ready,

    // to local X/Y NoB
    output wire [7:0] nob_data,
    output wire       nob_valid,
    output wire       nob_sop,
    output wire       nob_eop,
    input  wire       nob_ready
);

    flit_gate #(
        .MATCH_VALUE   (LOCAL_LAYER),
        .MATCH_MASK    (LAYER_MASK),
        .STRIP_ON_MATCH(1)
    ) gate (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_data    (spin_data),
        .in_valid   (spin_valid),
        .in_sop     (spin_sop),
        .in_eop     (spin_eop),
        .in_ready   (spin_ready),
        .match_data (nob_data),
        .match_valid(nob_valid),
        .match_sop  (nob_sop),
        .match_eop  (nob_eop),
        .match_ready(nob_ready),
        .pass_data  (spout_data),
        .pass_valid (spout_valid),
        .pass_sop   (spout_sop),
        .pass_eop   (spout_eop),
        .pass_ready (spout_ready)
    );

endmodule
