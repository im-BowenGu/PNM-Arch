# PNM Fabric HDL Sketch

Rough Verilog-2005 model of the **`xyz_repeater` layer gates** and **Hardware Flit Repeaters** from the paper *Bypassing the HBM Wall*.

## Modules

| File | Role |
|---|---|
| `pnm_defs.vh` | Packet format and constants |
| `hfr.v` | Hardware Flit Repeater (1-stage elastic pipe) |
| `flit_gate.v` | Combinational-match wormhole demux (shared core) |
| `xyz_repeater.v` | Z-axis repeater (layer ID compare + strip) |
| `xy_turn.v` | X→Y dimension-order turn gate |
| `node_eject.v` | Y-lane → node DMA eject gate (forwards `MODULE_ID` as DEST) |
| `crc16.v` | Byte-wise CRC-16/CCITT-FALSE (init `0xFFFF`, poly `0x1021`) |
| `doorbell.v` | Node DMA doorbell FSM — fires on byte count + CRC + DEST match, `NODE_ERR` on refusal |
| `pe_tile_stub.v` | Processing Element (PE) tile stub — AXI-Stream slave→master elastic pipe, 1–2 cycle MAC latency placeholder |
| `tb_fabric.v` | Functional smoke test |
| `tb_load.v` | 500-packet load test with backpressure + real CRC-16 injection |
| `tb_doorbell.v` | Doorbell FSM test: `pe_tile_stub` → `doorbell`, 4 valid fires + 4 rejections |

## Packet format (byte-wide links, CRC-protected destination)

```
wire format:
byte 0 : LAYER_ID            (stripped by xyz_repeater)
byte 1 : MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
byte 2 : CTRL      = {vc_class[1:0], op[1:0], rsvd[3:0]}
byte 3 : LEN_LO
byte 4 : LEN_HI
byte 5.. : payload (LEN bytes)
last 2 : CRC-16, covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]

node DMA stream (= wire[1:]): DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
```

The `xyz_repeater` strips `LAYER_ID`; `node_eject` **forwards** `MODULE_ID` unchanged,
so the DMA stream's DEST byte and the two trailing CRC bytes are all inside CRC
coverage. The doorbell requires the landed byte count to equal `LEN+6` (DEST + CTRL +
2 length + payload + 2 CRC), the CRC to validate, and DEST to equal the node's own
coordinate `{X[3:0], Y[3:0]}`.

## PE tile stub (`pe_tile_stub.v`)

The fabric decouples transport from computation behind a standard AXI-Stream /
Ready-Valid Processing Element (PE) interface, so the underlying execution block
(systolic array, FP16 MAC array, or ALU) can be swapped independently of the
routing fabric. `pe_tile_stub.v` is the placeholder for the MAC unit: it consumes
a flit byte on `s_axis`, holds it in an elastic pipe for `MULT_LATENCY` clock
cycles (the modelled multiply-accumulate latency, 1–2), and re-presents it on
`m_axis`, owning the `s_axis_tready` / `m_axis_tvalid` handshake flags. Swap the
internals for a real MAC array without touching the fabric or the node DMA.

## Build & run

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`).

```bash
# smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v xyz_repeater.v xy_turn.v node_eject.v tb_fabric.v
vvp tb_fabric.out

# load test (500 packets, mixed destinations, 25–100% sink ready, real CRC-16)
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v
vvp tb_load.out

# doorbell DMA (pe_tile_stub → doorbell, CRC-16 end-to-end)
iverilog -g2005 -o tb_doorbell.out \
  tb_doorbell.v pe_tile_stub.v doorbell.v crc16.v
vvp tb_doorbell.out
```

On NixOS:

```bash
nix-shell -p iverilog --run \
  'iverilog -g2005 -o tb_load.out hfr.v flit_gate.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out'
```

## Scope / non-goals

- Single physical channel per link (paper VC classes → parallel instances)
- `doorbell.v` implements the three-condition fire (byte count + CRC + DEST) and the
  `NODE_ERR` refusal path; it does not model DMA burst scheduling into DRAM banks
- The MAC array is a placeholder stub (`pe_tile_stub.v`), exercised through the real
  `doorbell.v` fire logic in `tb_doorbell.v`
- Byte-wide links for readability, not peak bandwidth modeling

See `../Paper.MD` §§4, 6, 11 for the architectural specification.
