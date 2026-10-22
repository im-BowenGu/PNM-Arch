# Architecture

*Breaking the HBM wall*: a distributed spatial Processing-Near-Memory machine
built from commodity LPDDR6 CAMM2 modules, mature-node DUV MAC ASICs, and a
deterministic single-spine wormhole fabric. Reference chassis: 512 nodes
(8 layers × 8×8), 64 TB, ~262 TB/s aggregate node-local bandwidth, ~197 TFLOPS
FP64, 8–10 kW, ~$16/GB.

## The four kinds of hardware

1. **DRAM modules** — two 64 GB 192-bit LPCAMM2/LPDDR6 modules per node
   (384-bit bus, ~512 GB/s node-local). The capacity play: ~24× cheaper per
   byte than HBM.
2. **MAC ASICs** — `HDL/core/node.v`, one per node. A CU_TYPE-selected engine
   (BF16 fused-FMA expert pass being the validated default; FP16/32/64,
   INT8/INT4/FP4/MXFP4, ternary available) over the same FMA datapath family
   (`arith_unit.v`). Weight-stationary: expert weights stay resident; only
   tokens move.
3. **Stateless flit repeaters** — `hfr.v`/`flit_gate.v`/`vc_merge.v`/
   `lxy_repeater.v`/`xy_turn.v`/`node_eject.v`. Every gate compares one header
   byte against a pre-loaded 11-bit routing bitmap. One legal route between
   any pair of nodes: routing is coordinate arithmetic, no search, no
   arbitration.
4. **One CPU-less router bridge** — `pnm_host_bridge.v`, driven by a host
   (Raspberry Pi over `pi_bridge.v` SPI, or any MCU over the same byte-level
   link) through `pnm_host_top.v`. The host runs boot (POST discovery,
   routing tables, weight upload, MoE gating load) and the dispatch loop.

## The wire format (everything depends on this)

```
LAYER_ID | MODULE_ID={X[3:0],Y[3:0]} | CTRL={vc[7:6],op[5:4],rsvd[3:0]} |
LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
```

- CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, no final XOR) over
  `[MODULE_ID..payload]`; LAYER_ID is peeled at the repeater, DEST stays in
  coverage.
- `lxy_repeater` strips LAYER_ID on match; `node_eject` deliberately does not
  strip, so the doorbell sees DEST inside the CRC.

## The doorbell

Three-condition fire, implemented twice and kept in sync (`HDL/doorbell.v`
and `sim/internal/pnm/virtual_units.go` `Consume`): byte count == LEN+6,
end-to-end CRC validates, DEST == LOCAL_MODULE. No software interrupt —
sub-microsecond activation.

## Execution model: static dataflow, plan as data

The paper's thesis: no runtime scheduling, no cache coherency, no OS on the
data path. The compiler maps the model onto physical coordinates; the
doorbell is the program counter. The dispatch plan is compiled **once on the
host** (`sim/internal/pnm/firmware.go` `PlanInference`) and shipped to the
firmware as data (`sim/internal/pnm/plan.go` ↔ `fw/plan.h`/`plan.c`); the
device contains no planner. `TestIntegration_CPlanWire` proves the two sides
share one wire format byte-for-byte.

## The gating ASIC

`HDL/core/gating_asic.v` is a per-node device holding one layer's router
weights; it produces the expert decision for every token on its node. Two
managers on the same die, selected by a strapping pin:

- **Mode A** — the node's embedded management node (`fw/pnm_mgmt.c` +
  `HDL/core/mgmt_bridge.v`) programs it and reads the decision locally; the
  per-token decision never leaves the board.
- **Mode B** — the host programs it over the fabric (`prog_*` receiver) and
  reads the decision back over the fabric read channel.

Both modes move the same ~0.7 MB of weights at setup; they differ only in
per-token traffic — which is why mode A exists (per-token management traffic
on the fabric would be a bottleneck on the capacity-critical resource).

## Software

- **Co-sim harness** (`sim/`, Go stdlib only): generates the topology
  (`pnm_top.v`) and the stimulus, runs the Verilog fabric cycle-exactly under
  vvp (sliced per layer group for parallelism), and verifies delivery against
  five oracles. The `FlitMessage` envelope (`pipe.go`) is the one remaining
  IPC wire format.
- **Model compiler** (`pnmc compile-model`): safetensors → AOT placement →
  `.pnm` program + chassis schema.
- **Source front ends** (`pnmsrc`): R, Haskell and HLSL compile to typed IR
  and lower to `.pnm` kernels for the FP64/FP32 ALU units.
- **C firmware** (`fw/`): the host-side boot + dispatch execution, the plan
  codec, and the embedded management node.

## What is machine-checked

1. The fabric: byte conservation, zero misroutes, doorbell accounting vs an
   independent twin, kernel results vs golden, exact closed-form latency,
   bit-exact replay (`go run ./cmd/pnm`).
2. The compute node and the gating ASIC: bit-exact vs the BF16 oracle
   (`node_reference_test.py`, `gating_reference_test.py`; `--real` uses real
   layer-0 slices when a checkpoint is present).
3. The composition chain: gating ASIC → fabric → node.v, chained over model
   layers 0/7/14, every layer bit-exact vs the software twin — always-on
   (`comp_model.go` supplies the synthetic fixture).
4. The firmware against the silicon: the mode-A firmware's own bus trace is
   replayed against the real gating ASIC (`TestIntegration_CMgmtGating`).
5. The integrated decoder block: `real_decoder_block.py` vs
   `tb_gemma_decoder_block.v`, bit-exact on real layer-0 slices (opt-in).

Everything else in the paper — bandwidth, power, thermal, cost, the 1 GHz /
128-bit-link projections — is explicitly labeled as a projection, not a
measurement.
