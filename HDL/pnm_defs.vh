// pnm_defs.vh — shared constants for the PNM fabric HDL sketch
// Paper: Bypassing the HBM Wall (§2.1–2.2 routing fabric, §2.9 doorbell,
// §4.3 virtual-channel classes)
//
// Byte-wide wormhole links. Packet layout on the wire:
//   byte 0 : LAYER_ID  [7:0]
//   byte 1 : MODULE_ID [7:0] = {X[3:0], Y[3:0]}  (the DEST field)
//   byte 2 : CTRL      [7:0] = {vc_class[7:6], op[5:4], rsvd[3:0]}
//   byte 3 : LEN_LO
//   byte 4 : LEN_HI
//   byte 5 .. 5+LEN-1 : payload
//   last 2 bytes      : CRC-16 (checked at the destination node doorbell)
//
// End-to-end CRC-16/CCITT-FALSE coverage (Paper §2.10):
//   [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]
// i.e. every byte of the DMA stream except the two trailing CRC bytes.  The
// DEST field is therefore CRC-protected, so the doorbell can reject a
// misdelivered message (Paper §2.4).
//
// Each hierarchical gate consumes its own header byte (source-routing style):
//   Z-axis ingress strips LAYER_ID  → NoB stream starts at MODULE_ID
//   X/Y turn gate does not strip     → Y-lane still carries MODULE_ID
//   Node eject forwards MODULE_ID    → DMA stream starts at DEST (=MODULE_ID)
//
// Node DMA stream (doorbell.v):  DEST | CTRL | LEN_LO | LEN_HI | payload |
//                                CRC_HI | CRC_LO

`ifndef PNM_DEFS_VH
`define PNM_DEFS_VH

`define DATA_W 8

// CTRL.op
`define OP_COMPUTE 2'b00
`define OP_FORWARD 2'b01

// CTRL.vc_class — the four virtual-channel classes of paper §4.3.  The CTRL
// field carries the class a flit was assembled with (its origin class: 2 for
// router-injected requests and pass-through, 0 for node-egress results); it
// is CRC-protected and fixed for the flit's whole journey.  Every fabric
// link additionally carries a 2-bit VC sideband (vc[1:0], alongside
// data/valid/sop/eop/ready) holding the class the flit occupies on that
// link, which transitions 2->3 (spine descent -> on-board delivery) and
// 0->1 (board egress -> spine ascent) at the xyz_repeater attachment.
`define VC_BOARD_EGRESS    2'b00
`define VC_SPINE_ASCENT    2'b01
`define VC_SPINE_DESCENT   2'b10
`define VC_ONBOARD_DELIVER 2'b11

// Routing bitmap (11 bits) — one pre-loaded routing-table entry carried by
// every repeater and node (paper §2.1, §2.8).  Describes a destination
// relative to the board's xyz_repeater:
//   [10:7] LAYER : 4-bit layer ID (1-based, matches LAYER_ID low nibble)
//   [6]    AXIS  : 0 = X, 1 = Y
//   [5]    SIGN  : 0 = +, 1 = -
//   [4:0]  DIST  : hop distance from the xyz_repeater (0..31)
`define RBM_LAYER_HI  10
`define RBM_LAYER_LO  7
`define RBM_AXIS      6
`define RBM_SIGN      5
`define RBM_DIST_HI   4
`define RBM_DIST_LO   0

`endif
