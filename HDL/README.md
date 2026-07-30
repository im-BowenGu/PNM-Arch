# PNM Fabric HDL Sketch

Rough Verilog-2005 model of the **Z-axis ingress ASIC** and **Hardware Flit Repeaters** from the paper *Bypassing the HBM Wall*.

## Modules

| File | Role |
|---|---|
| `pnm_defs.vh` | Packet format and constants |
| `hfr.v` | Hardware Flit Repeater (1-stage elastic pipe) |
| `flit_gate.v` | Combinational-match wormhole demux (shared core) |
| `z_ingress.v` | Z-axis ingress ASIC (layer ID compare + strip) |
| `xy_turn.v` | X→Y dimension-order turn gate |
| `node_eject.v` | Y-lane → node DMA eject gate |
| `tb_fabric.v` | Functional smoke test |
| `tb_load.v` | 500-packet load test with backpressure |

## Packet format (byte-wide links)

```
byte 0 : LAYER_ID
byte 1 : MODULE_ID = {X[3:0], Y[3:0]}
byte 2 : CTRL      = {vc_class[1:0], op[1:0], rsvd[3:0]}
byte 3 : LEN_LO
byte 4 : LEN_HI
byte 5.. : payload (LEN bytes)
last 2 : CRC-16 (checked at node DMA, not in fabric)
```

Header bytes are consumed hop-by-hop (source routing): ingress strips `LAYER_ID`; eject strips `MODULE_ID`.

## Build & run

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`).

```bash
# smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v z_ingress.v xy_turn.v node_eject.v tb_fabric.v
vvp tb_fabric.out

# load test (500 packets, mixed destinations, 25–100% sink ready)
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v z_ingress.v xy_turn.v node_eject.v tb_load.v
vvp tb_load.out
```

On NixOS:

```bash
nix-shell -p iverilog --run \
  'iverilog -g2005 -o tb_load.out hfr.v flit_gate.v z_ingress.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out'
```

## Scope / non-goals

- Single physical channel per link (paper VC classes → parallel instances)
- No CRC check, doorbell FSM, or MAC array in this sketch
- Byte-wide links for readability, not peak bandwidth modeling

See `../Paper.MD` §§4, 6, 11 for the architectural specification.
