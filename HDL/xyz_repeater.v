`include "pnm_defs.vh"

// =============================================================================
// xyz_repeater — Z-axis repeater (one per motherboard layer)
// Paper §2.1 (routing) / §4.3 (virtual-channel classes)
//
// Downward: compares the LAYER_ID header byte against the LAYER field of the
// pre-loaded routing bitmap (paper §2.1: tables loaded into the repeaters at
// boot) and gates matching packets — those arriving on VC_SPINE_DESCENT —
// onto the local X/Y NoB. Non-matching packets proceed down the spine.
// The LAYER_ID byte is stripped on the match path so the NoB stream starts
// at MODULE_ID (ready for dimension-order X/Y gates).  The VC sideband
// transitions 2->3 at the attachment: the NoB wire carries VC_ONBOARD_DELIVER
// for the whole on-board journey.
//
// Upward: the board's egress merge tree (VC_BOARD_EGRESS, class 0) merges
// with the up-spine stream from the layer below (VC_SPINE_ASCENT, class 1)
// through a vc_merge; the merged stream exits the up-spine port at class 1.
// The 0->1 transition happens at this attachment.
// =============================================================================
module xyz_repeater (
    input  wire       clk,
    input  wire       rst_n,

    // routing bitmap (routing-table entry):
    //   [10:7] LAYER : 4-bit layer ID, 1-based (matches LAYER_ID low nibble;
    //                  wire layers are 1..8, so the low nibble is the value)
    //   [6]    AXIS  : 0 = X, 1 = Y
    //   [5]    SIGN  : 0 = +, 1 = -
    //   [4:0]  DIST  : hop distance from the xyz_repeater
    input  wire [10:0] route_bitmap,

    // from up-spine (class 2: spine descent)
    input  wire [7:0] spin_data,
    input  wire       spin_valid,
    input  wire       spin_sop,
    input  wire       spin_eop,
    output wire       spin_ready,
    input  wire [1:0] spin_vc,

    // to down-spine (class 2)
    output wire [7:0] spout_data,
    output wire       spout_valid,
    output wire       spout_sop,
    output wire       spout_eop,
    input  wire       spout_ready,
    output wire [1:0] spout_vc,

    // to local X/Y NoB (class 3: on-board delivery — the 2->3 transition)
    output wire [7:0] nob_data,
    output wire       nob_valid,
    output wire       nob_sop,
    output wire       nob_eop,
    input  wire       nob_ready,
    output wire [1:0] nob_vc,

    // from board egress merge tree (class 0: on-board egress)
    input  wire [7:0] nob_up_data,
    input  wire       nob_up_valid,
    input  wire       nob_up_sop,
    input  wire       nob_up_eop,
    output wire       nob_up_ready,
    input  wire [1:0] nob_up_vc,

    // from up-spine, next layer below (class 1: spine ascent)
    input  wire [7:0] spup_in_data,
    input  wire       spup_in_valid,
    input  wire       spup_in_sop,
    input  wire       spup_in_eop,
    output wire       spup_in_ready,
    input  wire [1:0] spup_in_vc,

    // to up-spine, next layer above (class 1 — the 0->1 transition)
    output wire [7:0] spup_data,
    output wire       spup_valid,
    output wire       spup_sop,
    output wire       spup_eop,
    input  wire       spup_ready,
    output wire [1:0] spup_vc
);

    flit_gate #(
        .STRIP_ON_MATCH(1)
    ) gate (
        .clk        (clk),
        .rst_n      (rst_n),
        .match_value({4'h0, route_bitmap[`RBM_LAYER_HI:`RBM_LAYER_LO]}),
        .match_mask (8'h0F),
        .vc_accept  (`VC_SPINE_DESCENT),
        .in_vc      (spin_vc),
        .match_vc   (),
        .pass_vc    (spout_vc),
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

    assign nob_vc = `VC_ONBOARD_DELIVER;   // class transition 2->3

    vc_merge up (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_data     (nob_up_data),
        .a_valid    (nob_up_valid),
        .a_sop      (nob_up_sop),
        .a_eop      (nob_up_eop),
        .a_ready    (nob_up_ready),
        .a_vc       (nob_up_vc),
        .b_data     (spup_in_data),
        .b_valid    (spup_in_valid),
        .b_sop      (spup_in_sop),
        .b_eop      (spup_in_eop),
        .b_ready    (spup_in_ready),
        .b_vc       (spup_in_vc),
        .out_data   (spup_data),
        .out_valid  (spup_valid),
        .out_sop    (spup_sop),
        .out_eop    (spup_eop),
        .out_ready  (spup_ready),
        .out_vc     ()
    );

    assign spup_vc = `VC_SPINE_ASCENT;     // class transition 0->1

endmodule
