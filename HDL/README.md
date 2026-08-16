# PNM Fabric HDL Sketch

Rough Verilog-2005 model of the **`xyz_repeater` layer gates** and **Hardware Flit Repeaters** from the paper *Bypassing the HBM Wall*.

## Modules

| File | Role |
|---|---|
| `pnm_defs.vh` | Packet format, VC constants, routing-bitmap layout |
| `hfr.v` | Hardware Flit Repeater (1-stage elastic pipe) + layer bit-mask comparator (monitor) |
| `flit_gate.v` | Combinational-match wormhole demux (shared core); match value/mask are runtime inputs (pre-loaded routing table) |
| `vc_merge.v` | 2-in/1-out round-robin packet-atomic merge for the reverse (egress) paths — node TX → Y-up → X-up → xyz_repeater → up-spine (paper §2.9/§4.3) |
| `xyz_repeater.v` | Z-axis repeater (layer ID compare + strip); compare driven by the routing bitmap's LAYER field; egress port wraps `vc_merge` |
| `xy_turn.v` | X→Y dimension-order turn gate |
| `node_eject.v` | Y-lane → node DMA eject gate (forwards `MODULE_ID` as DEST) |
| `crc16.v` | Byte-wise CRC-16/CCITT-FALSE (init `0xFFFF`, poly `0x1021`) |
| `doorbell.v` | Node DMA doorbell FSM — fires on byte count + CRC + DEST match, `NODE_ERR` on refusal |
| `pe_tile_stub.v` | Processing Element (PE) tile — AXI-Stream slave→master elastic pipe (1–2 cycle MAC latency) running a bias-add kernel (`KERNEL_CONST`) with in-silicon CRC-16 validate + recompute (`corrupt_out` doorbell verdict); carries the node's routing bitmap and mask-compares the DEST nibble against DIST (`route_err`) |
| `tb_fabric.v` | Functional smoke test |
| `tb_load.v` | 500-packet load test with backpressure + real CRC-16 injection |
| `tb_doorbell.v` | Doorbell FSM test: `pe_tile_stub` → `doorbell`, 6 activations + 2 rejections (truncated, wrong DEST), 2 `corrupt_out` pulses, 1 `route_err` |

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

## Routing bitmap (11 bits, `pnm_defs.vh`)

Every repeater and node carries a pre-loaded routing-table entry (paper §2.1/§2.8)
that drives its bit-mask comparator:

```
bit [10:7] LAYER : 4-bit layer ID, 1-based (matches LAYER_ID low nibble)
bit [6]    AXIS  : 0 = X, 1 = Y
bit [5]    SIGN  : 0 = +, 1 = -
bit [4:0]  DIST  : hop distance from the xyz_repeater
```

- `xyz_repeater` masks `in_data ^ {4'h0, LAYER}` with `0x0F` to gate flits onto the
  board (spine `LAYER_ID` bytes are 1..8, so the low nibble is the value).
- `hfr` repeats the same layer mask as a pure-combinational monitor (`layer_match`);
  the data path stays a stateless pipe.
- `pe_tile_stub` holds its node's entry and mask-selects the DEST nibble by AXIS
  (`route_err` when the nibble != DIST). `LAYER`/`SIGN` are not re-checkable at the
  node: `LAYER_ID` was stripped at the repeater and the DMA stream carries no direction.
- `pe_tile_stub` also runs the CRC half of the doorbell in silicon: it validates the
  incoming end-to-end CRC while streaming and pulses `corrupt_out` on failure — the
  hardware verdict the co-sim records as the node's refusal (Paper §2.9).
- `flit_gate` takes `match_value`/`match_mask` as runtime inputs rather than
  parameters, so a gate's decision can be reprogrammed at boot like the paper's
  immutable routing tables.

## PE tile stub (`pe_tile_stub.v`)

The fabric decouples transport from computation behind a standard AXI-Stream /
Ready-Valid Processing Element (PE) interface, so the underlying execution block
(systolic array, FP16 MAC array, or ALU) can be swapped independently of the
routing fabric. `pe_tile_stub.v` is the placeholder for the MAC unit: it consumes
a flit byte on `s_axis`, holds it in an elastic pipe for `MULT_LATENCY` clock
cycles (the modelled multiply-accumulate latency, 1–2), and re-presents it on
`m_axis`, owning the `s_axis_tready` / `m_axis_tvalid` handshake flags. Framing
rides along: `s_axis_tlast`/`m_axis_tlast` (EOP) and `s_axis_tstart`/
`m_axis_tstart` (SOP, the packet head) pass through the elastic pipe unchanged.

The stub **computes**: its resident kernel is an element-wise bias add — every
payload byte is emitted as `(payload[i] + KERNEL_CONST) mod 256` — and the trailing
CRC bytes are replaced by a CRC-16/CCITT-FALSE recomputed over the transformed body
(`crc16.v`, the hardware twin of `sim/internal/pnm/crc.go`). While streaming, the stub
also validates the *incoming* CRC (over the unmodified body): on failure it pulses
`corrupt_out`, the hardware doorbell verdict, which the co-sim harness (`cmd/pnm`)
records as the
node's refusal. With `KERNEL_CONST = 0` the recomputed CRC equals the incoming one
and the stub is byte-exact — a pure latency pipe — so existing testbenches are
unchanged by the compute. The node's 11-bit `routing_bitmap` (its routing-table
entry) rides alongside and the stub mask-checks every packet head: `route_err`
pulses when the AXIS-selected DEST nibble differs from DIST (`tb_doorbell.v` drives
layer 1, Y, +, dist 5 for node `0x25` and expects exactly one `route_err` — the
wrong-DEST packet).

## Build & run

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`).

```bash
# smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_fabric.v
vvp tb_fabric.out

# load test (500 packets, mixed destinations, 25–100% sink ready, real CRC-16)
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v
vvp tb_load.out

# doorbell DMA (pe_tile_stub → doorbell, CRC-16 end-to-end)
iverilog -g2005 -o tb_doorbell.out \
  tb_doorbell.v pe_tile_stub.v doorbell.v crc16.v
vvp tb_doorbell.out
```

On NixOS:

```bash
nix-shell -p iverilog --run \
  'iverilog -g2005 -o tb_load.out hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out'
```

## Scope / non-goals

- Single physical channel per link (paper VC classes → parallel instances)
- `doorbell.v` implements the three-condition fire (byte count + CRC + DEST) and the
  `NODE_ERR` refusal path; it does not model DMA burst scheduling into DRAM banks
- The MAC array is a placeholder (`pe_tile_stub.v`): it runs a bias-add kernel with
  in-silicon CRC-16 validation/recompute, exercised through the real `doorbell.v`
  fire logic in `tb_doorbell.v`; a full systolic array / FP16 MAC datapath is future work
- Byte-wide links for readability, not peak bandwidth modeling

See `../Paper.MD` §§2–4 for the architectural specification.
