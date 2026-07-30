// pnm_defs.vh — shared constants for the PNM fabric HDL sketch
// Paper: Bypassing the HBM Wall (Sections 4, 6, 11)
//
// Byte-wide wormhole links. Packet layout on the wire:
//   byte 0 : LAYER_ID  [7:0]
//   byte 1 : MODULE_ID [7:0] = {X[3:0], Y[3:0]}
//   byte 2 : CTRL      [7:0] = {vc_class[1:0], op[1:0], rsvd[3:0]}
//   byte 3 : LEN_LO
//   byte 4 : LEN_HI
//   byte 5 .. 5+LEN-1 : payload
//   last 2 bytes      : CRC-16 (checked only at the destination node DMA)
//
// Each hierarchical gate consumes its own header byte (source-routing style):
//   Z-axis ingress strips LAYER_ID  → NoB stream starts at MODULE_ID
//   X/Y turn gate does not strip     → Y-lane still carries MODULE_ID
//   Node eject strips MODULE_ID     → DMA stream starts at CTRL

`ifndef PNM_DEFS_VH
`define PNM_DEFS_VH

`define DATA_W 8

// CTRL.op
`define OP_COMPUTE 2'b00
`define OP_FORWARD 2'b01

// CTRL.vc_class — deadlock-freedom classes (paper Section 11)
// Parallel physical instances of each link carry one class each.
`define VC_BOARD_EGRESS  2'b00
`define VC_SPINE         2'b01
`define VC_BOARD_DELIVER 2'b10

`endif
