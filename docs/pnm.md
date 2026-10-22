# PNM — architecture and documentation

The complete documentation for *Breaking the HBM wall*: the architecture, the paper, the RTL, the co-simulation harness, the firmware, the boards, and every command. Start with the repository [README](../README.md) for the one-screen version.

## Contents

1. [The architecture in one screen](#1-the-architecture-in-one-screen)
2. [The architecture in brief](#2-the-architecture-in-brief)
3. [The paper](#3-the-paper)
4. [The hardware](#4-the-hardware)
5. [The co-simulation harness](#5-the-co-simulation-harness)
6. [Using the system](#6-using-the-system)
7. [Profiling and benchmarks](#7-profiling-and-benchmarks)
8. [Real weights](#8-real-weights)
9. [The boards](#9-the-boards)
10. [Board assembly](#10-board-assembly)
11. [Board assembly schema](#11-board-assembly-schema)
12. [Raspberry Pi host drivers](#12-raspberry-pi-host-drivers)
13. [Archived components](#13-archived-components)

---

## 1. The architecture in one screen

*Breaking the HBM wall*: a distributed spatial Processing-Near-Memory machine
built from commodity LPDDR6 CAMM2 modules, mature-node DUV MAC ASICs, and a
deterministic single-spine wormhole fabric. Reference chassis: 512 nodes
(8 layers × 8×8), 64 TB, ~262 TB/s aggregate node-local bandwidth, ~197 TFLOPS
FP64, 8–10 kW, ~$16/GB.

### The four kinds of hardware

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

### The wire format (everything depends on this)

```
LAYER_ID | MODULE_ID={X[3:0],Y[3:0]} | CTRL={vc[7:6],op[5:4],rsvd[3:0]} |
LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
```

- CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, no final XOR) over
  `[MODULE_ID..payload]`; LAYER_ID is peeled at the repeater, DEST stays in
  coverage.
- `lxy_repeater` strips LAYER_ID on match; `node_eject` deliberately does not
  strip, so the doorbell sees DEST inside the CRC.

### The doorbell

Three-condition fire, implemented twice and kept in sync (`HDL/doorbell.v`
and `sim/internal/pnm/virtual_units.go` `Consume`): byte count == LEN+6,
end-to-end CRC validates, DEST == LOCAL_MODULE. No software interrupt —
sub-microsecond activation.

### Execution model: static dataflow, plan as data

The paper's thesis: no runtime scheduling, no cache coherency, no OS on the
data path. The compiler maps the model onto physical coordinates; the
doorbell is the program counter. The dispatch plan is compiled **once on the
host** (`sim/internal/pnm/firmware.go` `PlanInference`) and shipped to the
firmware as data (`sim/internal/pnm/plan.go` ↔ `fw/plan.h`/`plan.c`); the
device contains no planner. `TestIntegration_CPlanWire` proves the two sides
share one wire format byte-for-byte.

### The gating ASIC

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

### Software

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

### What is machine-checked

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

---

## 2. The architecture in brief

A rough-sketch overview of what the machine *is* and *how it computes*, deliberately
kept free of wire formats, register maps, and interface minutiae. Those live in
[`Paper.MD`](../paper/Paper.MD) (the specification), [the harness reference](#5-the-co-simulation-harness) (the working
documentation), and [the README](../README.md) (the project quick-start).

### The problem

Large models no longer fail on compute; they fail on *capacity*. The memory that would
hold them (HBM) sits behind silicon interposers whose area — and therefore capacity per
package — is fixed by lithography optics, and its manufacturing curve (EUV-class
lithography, stacked-die yield) is the most expensive in the industry. The result:
accelerators that dissipate hundreds of watts in a thumbnail-sized package to serve a
few dozen gigabytes, while the workloads that matter most — sparse expert models,
simulation state, image volumes — simply do not fit.

### The core idea

Stop treating memory as a peripheral. Build the computer *out of* memory:

- Every byte of state lives in ordinary, socketed commodity DRAM modules — the same
  modules laptops use, from the same fabs, at commodity prices.
- A small, dumb, fixed-function arithmetic die sits beside each module. No instruction
  decoder, no branch predictor, no caches, no OS. It multiplies and adds.
- Wires with repeaters connect everything in a fixed pattern that never changes at
  runtime. Routing a message anywhere is grade-school coordinate arithmetic, so the
  time any message takes is known before the machine is turned on.
- Exactly one chip in the whole chassis can run software: a small RISC-V management
  computer at the root of the wiring tree. It boots the machine, discovers what is
  plugged in, loads the program, and dispatches work. It also terminates a PCIe Gen5
  x16 host uplink and an NVMe storage controller in silicon, so it can boot standalone
  from local flash instead of re-streaming its OS from the host every power cycle.
  Everything else is pure transport.

The physical motherboard becomes an immutable dataflow graph, and the compiler's job is
to lay the program out on it like a circuit board — once, ahead of time.

### Physical shape

Thin boards carrying a grid of paired DRAM-module-plus-arithmetic-die "nodes" are
stacked vertically. A single shared trunk — the spine — runs up through the stack, and
each board taps into it through one gateway component. All long-haul traffic goes up or
down this trunk; all local traffic moves across a board in two dimension-ordered hops.
At the bottom of the trunk sit the management computer and the host connection. Boards
are cooled by a vertical coolant manifold that injects identical-temperature fluid into
every layer simultaneously, with calibrated flow restrictions so balance is enforced by
hardware rather than hoped for.

### How a computation runs

1. **Compile.** A compiler ingests the program or model, discovers the physical layout
   of the chassis, and decides *which node holds which weight* and *in what order*
   messages move. Because placement and schedule are computed once, nothing at runtime
   arbitrates, evicts, or guesses.
2. **Load.** At boot, weights stream out to their nodes over the same wiring that later
   carries computation. The machine is now a static dataflow graph etched in DRAM.
3. **Stream.** To run one step, the router injects tokens; the fabric delivers each to
   the node whose resident weights need them; the arithmetic die consumes the bytes as
   they arrive.
4. **Fire.** Completion is a hardware event, not an interrupt: a message counts as done
   only when the byte count, integrity check, and destination all agree — checked in
   silicon on every message. Wrong or corrupted messages are refused loudly and never
   trigger computation.

For sparse expert models this is the natural shape: every expert stays resident in its
private pool of cheap DRAM, and only the tiny token travels to whichever few experts
are selected. For grid simulations the board grid *is* the simulation grid, and
neighbor exchanges are single local hops.

### Why trust it

The transport claims are not argued, they are executed: a co-simulation harness drives
the real gate-level model of the fabric against independent software oracles, checking
byte-exact delivery under backpressure, refusal accounting for corrupted messages,
kernel results against golden values, and — because nothing on the data path holds
hidden state — bit-identical reproduction of entire runs. Static analysis covers the
remaining gate-level hygiene. What remains unproven (cooling fluid dynamics, DRAM
availability curves) is labeled as engineering estimate, not claimed away.

### Power and heat

Because nothing spends energy speculating — no caches re-fetching, no cores fetching
instructions, no coherence traffic — a node idles in the watt range and works at
roughly fifteen watts: about nine for the arithmetic die, five for its DRAM module,
one for its share of the wiring. Sixty-four nodes make about a kilowatt per board; a
full chassis lands in the eight-to-ten-kilowatt band including fabric, conversion, and
cooling losses — two orders of magnitude below the GPU fleet needed to hold the same
bytes.

### Scaling

Remove the spine and the same recipe shrinks to a single-board desk-side unit in the
multi-terabyte class. Replicate the chassis and join replicas through a second routing
level and the same recipe grows to warehouse scale — each chassis keeping its own
deterministic timing, with no coherence protocol appearing anywhere in between.
Memory generations ride the same property: the node's memory controller contract is
the only thing consumers see, so LPDDR5, LPDDR5X, and LPDDR6 module classes (and DDR4/5
SODIMMs at the deskside tier) swap by synthesis-time parameter with the fabric,
compute units, and firmware untouched — each variant verified by its own testbench.

### Key numbers (reference chassis, first-order estimates)

| Metric | Value |
|--------|-------|
| Nodes | 512 (8 layers × 8×8 grid) |
| Attached memory | 64 TB |
| Aggregate node-local bandwidth | ~262 TB/s (2 × 64 GB 192-bit modules/node, 384-bit) |
| FP64 throughput | ~197 TFLOPS |
| Power | ~15 W per node; ~8–10 kW per chassis |
| Cost | ~$1M per chassis (~$16/GB), vs ~$24M+ of HBM-class hardware for the same bytes |

### Physical product readiness

The RTL is written as if tape-out mattered: latch-based clock-gating cells with scan
test override, two-flop reset synchronizers on every async crossing, JTAG + MBIST + PHY
loopback for bring-up, SDC timing constraints and a device tree shipped beside the
sources, and an assembly schema that composes verified modules into board netlists.
What remains between this repository and fabricated silicon is exactly the part no RTL
paper can claim: analog SerDes characterization, package bond maps, and floorplan
extraction — vendor work, labeled as such rather than papered over.

### Where to look next

- [`Paper.MD`](../paper/Paper.MD) — full specification with rationale and citations
- [`README.md`](#4-the-hardware) — repository tour and build instructions
- [The co-simulation harness](#5-the-co-simulation-harness) — module-by-module documentation of the RTL and harness
- [`HDL/`](../HDL/) — the gate-level fabric, compute units, controllers, and links
- [`sim/`](../sim/) — the Go co-simulation harness, compilers, and drivers

---

## 3. The paper

> *Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory
> Architecture using DUV ASICs and Deterministic Routing*

### Venue recommendation (2026-10-18)

**Primary: arXiv preprint (cs.AR), PDF or source upload.** The manuscript is a
~32-page two-column architecture specification with machine-checked transport
claims and an open-hardware artifact — it is not shaped as a 10–12 page
conference paper, and there is no silicon measurement behind the bandwidth /
power / cost projections (stated explicitly in §4.4). arXiv establishes priority,
makes the repository citable, and matches the validation-scope discipline of
the paper.

**Secondary (optional, after arXiv):** cut a conference version for DATE / DAC /
MICRO-class venues (drop §2.16–2.19 peripheral RTL, compress §3.6 taxonomy to
the BF16 + ternary nodes, keep §2.15/3.5 verification + §3.2 roofline + §4.5
capacity economics), or extend into a journal (IEEE TC / ACM TOMARCH) with a
formal deadlock proof replacing the §4.3 sketch.

#### arXiv upload package

```bash
python3 build.py            # regenerates submission/paper.tex + paper.pdf
                            # and stages submission/figures/fig_*.png
```

| Upload | Path |
|--------|------|
| PDF (simplest) | `submission/paper.pdf` |
| LaTeX source | `submission/paper.tex` + `submission/figures/fig_*.png` |

Suggested arXiv metadata:

| Field | Value |
|-------|-------|
| Title | Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing |
| Authors | Bowen Gu |
| Abstract | first three paragraphs of `Paper.MD` Abstract (from “The memory wall has hardened…” through “…not silicon measurements.”) |
| Categories | `cs.AR` (primary); optional `cs.PF`, `cs.LG` |
| License | CC BY-SA 4.0 |

### Manuscript

| File | Description |
|------|-------------|
| [`Paper.MD`](../paper/Paper.MD) | Source of truth (Markdown with LaTeX-escape conventions) |
| [The architecture in brief](#2-the-architecture-in-brief) | Architecture brief |
| `build.py` | Build pipeline → `submission/*.docx` |

### Building the paper

Requires [Nix](https://nixos.org) with flake support (`nix develop`).

```bash
cd paper
nix develop                      # enter environment (pdflatex, pandoc)
python3 build.py                 # → submission/paper.docx + .pdf + .tex
python3 build.py --review        # → submission/paper_review.pdf (11pt single-column)
```

`build.py` strips everything before the `Abstract` header, converts
`{c(n)}` → `\cite{n}`, converts `Table N.` pipe blocks to `tabularx` floats,
regenerates the figures (`figures/make_figures.py`, matplotlib), stages
`submission/figures/` and rewrites figure paths so `paper.tex` is portable,
runs pdflatex twice, then pandoc to DOCX.
The bibliography is hardcoded in `paper/build.py` (`REFS`, Chicago style) —
every `{c(n)}` in the manuscript must land in `1..len(REFS)`.

### What the paper proves

Five properties are machine-checked on every co-simulation run:

1. **Byte-exact delivery** — bytes delivered to each node equal bytes
   injected; no loss, no duplication, no reorder
2. **Zero drops and zero misroutes** — every injected flit reaches its
   declared destination; dimension-order routing leaves no residual
3. **Doorbell accounting** — hardware verdicts (activations, refusals,
   `corrupt_out` pulses) match the three-condition fire logic message
   by message
4. **Kernel correctness** — each resident kernel executes on what the
   hardware delivered and matches the golden model
5. **Latency bounds** — sweep checks every packet against the closed
   form (hop count × per-hop delay + serialization) exactly

### Verifying the fabric (paper proofs)

The paper-verification subset of HDL testbenches lives in `paper/HDL/`.
These are the exact tests cited in the paper:

```bash
cd paper/HDL

# 500-packet load test: byte-exact delivery, zero drops, zero misroutes
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out

# doorbell discipline: six activations, two refusals, two corrupt_out pulses
# (paper/HDL is regenerated in full from HDL/ by paper/build.py, so every
# compute-unit primitive is bundled here and the command runs in place)
iverilog -g2005 -o tb_doorbell.out core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v && vvp tb_doorbell.out

# full fabric smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
```

Expect `*** LOAD TEST PASSED (500 packets) ***` and 6 doorbell fires
(2 rejections, 2 `corrupt_out` pulses). The full test suite lives in
[`HDL/`](../HDL/) (30+ testbenches).

### License

The `paper/` directory (manuscript, build pipeline, submission artifacts)
is licensed under [CC BY-SA 4.0](../LICENSE). The HDL testbenches in
`paper/HDL/` are [CERN-OHL-S v2](../LICENSE).

---

## 4. The hardware

Verilog-2005 model of the **routing fabric**, **compute units**, and **co-simulation harness** from the paper *Breaking the HBM wall*.

### Modules

| File | Role |
|---|---|
| `pnm_defs.vh` | Packet format, VC constants, routing-bitmap layout |
| `hfr.v` | Hardware Flit Repeater (1-stage elastic pipe) + layer bit-mask comparator (monitor) |
| `flit_gate.v` | Combinational-match wormhole demux (shared core); match value/mask are runtime inputs (pre-loaded routing table) |
| `vc_merge.v` | 2-in/1-out round-robin packet-atomic merge for the reverse (egress) paths — node TX → Y-up → X-up → lxy_repeater → up-spine (paper §2.9/§4.3) |
| `lxy_repeater.v` | Z-axis repeater (layer ID compare + strip); compare driven by the routing bitmap's LAYER field; egress port wraps `vc_merge` |
| `xy_turn.v` | X→Y dimension-order turn gate |
| `node_eject.v` | Y-lane → node DMA eject gate (forwards `MODULE_ID` as DEST) |
| `crc16.v` | Byte-wise CRC-16/CCITT-FALSE (init `0xFFFF`, poly `0x1021`) |
| `doorbell.v` | Node DMA doorbell FSM — fires on byte count + CRC + DEST match, `NODE_ERR` on refusal |
| `pe_tile_stub.v` | Processing Element (PE) tile — AXI-Stream slave→master elastic pipe (1–2 cycle MAC latency) running a bias-add kernel (`KERNEL_CONST`) with in-silicon CRC-16 validate + recompute (`corrupt_out` doorbell verdict); carries the node's routing bitmap and mask-compares the DEST nibble against DIST (`route_err`) |
| `node.v` | **Compute node** — one MoE expert pass (gate/up → gelu-tanh·up → down) on a `CU_TYPE`-selectable numeric ASIC (BF16/FP16/FP32/FP64/INT8/INT4/FP4/MXFP4) behind a shared `c = a*b + c` accumulate interface and FSM; converges with the router's fused-FMA datapath. Supersedes the `pe_tile_stub` bias-add placeholder as the node's real MAC |
| **Compute units** | |
| `fp16_fma.v` | FP16 Fused Multiply-Add (3-cycle pipeline) |
| `bf16_fma.v` | BF16 Fused Multiply-Add (3-cycle pipeline) |
| `fp32_fma.v` | FP32 Fused Multiply-Add (3-cycle pipeline) |
| `fp64_fma.v` | FP64 Fused Multiply-Add (3-cycle pipeline) |
| `fp16_mac_array.v` | FP16 systolic MAC array |
| `bf16_mac_array.v` | BF16 systolic MAC array |
| `fp32_alu.v` | FP32 ALU: ADD, SUB, MUL, DIV, MIN, MAX, CMP (4-cycle FMA path, 28-cycle div) |
| `fp32_alu_chip.v` | FP32 ALU chip — wraps `fp32_alu.v` with AXI-Stream flit interface for PNM fabric integration |
| `int8_mac.v` | INT8 multiply-accumulate |
| **Fabric integration** | |
| `pnm_host_bridge.v` | The CPU-less router bridge — PNM router engine, SRAM, host register window (SPI on a Pi, or any third-party MCU) |
| `kv_cache_bank.v` | KV cache bank (on-node) |
| `kv_offload.v` | KV cache offload engine |
| `moe_gating.v` | MoE expert gating (top-K selection) |
| **Memory \& interconnect** | |
| `lpddr6_camm.v` | Behavioral LPCAMM2/LPDDR6 module (banked array, CAS-latency wait, refresh scheduler); parameterized across DDR4/DDR5 SODIMM timing generations |
| `sodimm_ctrl.v` | Banked DDR SODIMM memory controller — per-bank open-row tracker + ACT/PRE/CAS FSM (ST\_WAIT\_RAS → ST\_PRE → ST\_RCD → ST\_CAS), tRAS enforcement, byte-enable masking, refresh storms; same bus contract as `lpddr6_camm` |
| `pcb_link.v` | PCB trace model — shift-register delay line of ⌈DELAY\_NS/10⌉ cycles, SOP/EOP/data bit-exact; `pcb_triple_link` wraps three for X/Y/spine populations |
| `optical_link.v` | Optical inter-chassis link — dual-clock async elastic FIFO (gray-coded pointers, 2-FF syncs) + propagation pipe (E/O + fiber at 4.9 ns/m + O/E); SOP/EOP preserved end-to-end; write-side occupancy-threshold flow control; `optical_pair` composes two links into one bidirectional port |
| **Testbenches** | |
| `tb_fabric.v` | Functional smoke test |
| `tb_load.v` | 500-packet load test with backpressure + real CRC-16 injection |
| `tb_doorbell.v` | Doorbell FSM test: `pe_tile_stub` → `doorbell`, 6 activations + 2 rejections (truncated, wrong DEST), 2 `corrupt_out` pulses, 1 `route_err` |
| `tb_fp16_fma.v` | FP16 FMA testbench |
| `tb_bf16_fma.v` | BF16 FMA testbench |
| `tb_fp32_fma.v` | FP32 FMA testbench |
| `tb_fp64_fma.v` | FP64 FMA testbench |
| `tb_fp32_alu.v` | FP32 ALU testbench (ADD/SUB/MUL/DIV/MIN/MAX/CMP) |
| `tb_fp16_mac_array.v` | FP16 MAC array testbench |
| `tb_bf16_mac_array.v` | BF16 MAC array testbench |
| `tb_int8_mac.v` | INT8 MAC testbench |
| `tb_pnm_host_bridge.v` | Host bridge testbench — the TB plays the host and checks the emitted flit and the counters |
| `tb_host_path_e2e.v` | The whole host path — SPI adapter, arbiter, and bridge composed, over the real SPI frame protocol |
| `tb_gating_modes.v` | The two gating managers — the same weights and the same hidden state programmed through the embedded node's bus and through the fabric, requiring the same top-K decision |
| `tb_moe_gating.v` | MoE gating testbench |
| `tb_node.v` | Compute-node testbench — boots expert weights, streams the hidden vector, dumps gate/up/act/out (`node_reference_test.py` drives it; BF16 + INT8 bit-exact) |
| `tb_dma_lpddr6.v` | Host→BMC→DMA→LPDDR6 roundtrip with mid-transfer refresh stalls |
| `tb_sodimm_lpddr.v` | Same protocol stack across DDR4/DDR5/LPDDR6 timing generations |
| `tb_pcb_link.v` | PCB links: passthrough, exact latency, 200-packet stream, triple-link counter |
| `tb_sodimm_ctrl.v` | Banked DDR controller: cold/hit/conflict latencies in closed form, tRAS wait insertion, BE masking, refresh storm, DDR4 vs DDR5 sweep (`*** SODIMM CTRL TEST PASSED ***`) |
| `tb_optical_link.v` | Optical links: idle latency (PROP\_CYCLES+5), burst SOP/EOP alignment, flood zero-loss, gapped packets, async 100↔80 MHz CDC with ready deassertion, bidirectional pair (`*** OPTICAL LINK TEST PASSED ***`) |

### Compute units

Each node's PE tile (`pe_tile_stub.v`) instantiates one of several compute unit types selected by the model compiler:

| Module | Type | Precision | Latency | Use case |
|--------|------|-----------|---------|----------|
| `bf16_fma.v` | FMA | BF16 | 3 cycles | MoE experts, dense MLP |
| `fp16_fma.v` | FMA | FP16 | 3 cycles | FP16 models |
| `fp32_fma.v` | FMA | FP32 | 3 cycles | High-precision compute |
| `fp64_fma.v` | FMA | FP64 | 3 cycles | Double-precision scientific |
| `bf16_mac_array.v` | Systolic array | BF16 | variable | Attention QKV |
| `fp16_mac_array.v` | Systolic array | FP16 | variable | FP16 attention |
| `fp32_alu.v` | ALU | FP32 | 3 (MIN/MAX/CMP), 4 (FMA), 28 (DIV) | Layernorm (divider + multiplier) |
| `fp32_alu_chip.v` | ALU chip | FP32 | 5-29 cycles | AXI-Stream integrated ALU for fabric |
| `int8_mac.v` | MAC | INT8 | 2 cycles | Quantized inference |
| `int4_mac.v` | MAC | INT4 | 2 cycles | INT4 quantized (packed nibbles) |
| `int4_mac_array.v` | Systolic array | INT4/INT8 | variable | INT4 quantized inference (4x density) |
| `fp4_mac.v` | MAC | FP4 (E2M1) | 2 cycles | FP4 quantized (packed nibbles) |
| `fp4_mac_array.v` | Systolic array | FP4 | variable | FP4 quantized inference (4x density vs BF16) |
| `mxfp4_mac_array.v` | Systolic array | MXFP4 | variable | MXFP4 (block-scaled E2M1) inference |
| `weight_dequant.v` | Dequantizer | INT4/INT8/FP4/MXFP4 → BF16 | 1 cycle | Weight-only quantization |

All FMA modules share an identical interface: `clk, rst_n, a, b, c, valid_in → result, valid_out`
(3-cycle pipeline). The `pe_tile_stub.v` uses `USE_FMA` (0=bias-add, 1=BF16 FMA) and `CU_TYPE`
(0=bias-add, 1=BF16 FMA, 2=INT4 MAC, 3=FP4 MAC, 4=MXFP4 MAC) parameters to select the compute path.
`node.v` is the real expert MAC: its `CU_TYPE` (0..7) selects the embedded engine from the
table above behind one shared accumulate interface, and `WIDTH` (16/16/32/64/8/8/8/8) must
match. Bit-exact RTL validation for CU 0 (BF16) and CU 4 (INT8) lives in
`core/node_reference_test.py` (`--cu N`, plus `--real` for a real layer-0 expert).

### Packet format (byte-wide links, CRC-protected destination)

```
wire format:
byte 0 : LAYER_ID            (stripped by lxy_repeater)
byte 1 : MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
byte 2 : CTRL      = {vc_class[7:6], op[5:4], rsvd[3:0]}
byte 3 : LEN_LO
byte 4 : LEN_HI
byte 5.. : payload (LEN bytes)
last 2 : CRC-16, covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]

node DMA stream (= wire[1:]): DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
```

The `lxy_repeater` strips `LAYER_ID`; `node_eject` **forwards** `MODULE_ID` unchanged,
so the DMA stream's DEST byte and the two trailing CRC bytes are all inside CRC
coverage. The doorbell requires the landed byte count to equal `LEN+6` (DEST + CTRL +
2 length + payload + 2 CRC), the CRC to validate, and DEST to equal the node's own
coordinate `{X[3:0], Y[3:0]}`.

### Routing bitmap (11 bits, `pnm_defs.vh`)

Every repeater and node carries a pre-loaded routing-table entry (paper §2.1/§2.8)
that drives its bit-mask comparator:

```
bit [10:7] LAYER : 4-bit layer ID, 1-based (matches LAYER_ID low nibble)
bit [6]    AXIS  : 0 = X, 1 = Y
bit [5]    SIGN  : 0 = +, 1 = -
bit [4:0]  DIST  : hop distance from the lxy_repeater
```

- `lxy_repeater` masks `in_data ^ {4'h0, LAYER}` with `0x0F` to gate flits onto the
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

### PE tile stub (`pe_tile_stub.v`)

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

### Build & run

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`).

```bash
# smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v
vvp tb_fabric.out

# load test (500 packets, mixed destinations, 25–100% sink ready, real CRC-16)
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v
vvp tb_load.out

# doorbell DMA (pe_tile_stub → doorbell, CRC-16 end-to-end)
iverilog -g2005 -o tb_doorbell.out \
  core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v
vvp tb_doorbell.out

# banked DDR SODIMM controller (row hit/miss/conflict latencies, refresh)
iverilog -g2005 -o tb_sodimm_ctrl.out sodimm_ctrl.v tb_sodimm_ctrl.v
vvp tb_sodimm_ctrl.out

# optical inter-chassis links (async CDC FIFO + fiber propagation pipe)
iverilog -g2005 -o tb_optical_link.out optical_link.v tb_optical_link.v
vvp tb_optical_link.out
```

On NixOS:

```bash
nix-shell -p iverilog --run \
  'iverilog -g2005 -o tb_load.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out'
```

### Memory and interconnect models

#### SODIMM memory controller (`sodimm_ctrl.v`)

Unlike the behavioral `lpddr6_camm`, this is a real banked DDR controller. A
per-bank tracker holds each bank's open row and tRAS countdown and drives an
ACT/PRE/CAS micro-FSM (`ST_WAIT_RAS → ST_PRE → ST_RCD → ST_CAS`):

| Access type | Latency |
|-------------|---------|
| Row hit (bank open, row matches) | CL |
| Cold access (bank closed) | tRCD + CL |
| Row conflict (bank open, different row) | tRP + tRCD + CL |

tRAS is enforced between activate and precharge: a conflict arriving before
tRAS expires waits out the remainder first, so latencies stay deterministic
under any command order.

Byte-enable write masking, a refresh scheduler that closes all banks and drops
`bus_ready` for `REFRESH_BURST` cycles every `REFRESH_CYCLES` (accepted
commands are never dropped), and rd/wr/refresh activity counters complete the
model. The bus interface is pin-compatible with `lpddr6_camm` (valid/ready,
byte address, ready-down-until-complete), so it sits behind `pnm_arb`
unchanged. The testbench drives three profiles — DDR4-like (CL/tRCD/tRP 15,
tRAS 38), DDR5-like (36/36/36/44), and a short-interval refresh-storm stress
unit — and checks exact closed-form latencies, tRAS wait insertion under
immediate conflict, 64-word readback integrity, partial-byte-write masking
(expects `DE11BE11`), stall accounting through the storm, and the DDR4-vs-DDR5
cold-latency ordering.

#### Optical inter-chassis link (`optical_link.v`)

The physical realization of the paper's multi-chassis scale-out path
(§3.7/§4.4). Each unidirectional link is:

```
tx domain                          rx domain
-----------                        ----------
tx_data/valid/sop/eop ──▶ [async elastic FIFO] ──▶ [prop pipe ×PROP_CYCLES] ──▶ rx_data/valid/sop/eop
        ▲              gray ptrs, 2-FF syncs      E/O + fiber + O/E          registered output
        │
   tx_ready = (gray-synced occupancy < READY_LIMIT)
   READY_LIMIT = FIFO_DEPTH − PROP_CYCLES − 2
```

- **Framing**: every entry packs `{sop, eop, data}`, so packet delimiters
  survive the hop bit-exactly and the fabric wire format is unchanged on both
  sides.
- **Clocking**: write and read pointers cross domains as Gray codes through
  two-flop synchronizers; the read side pops unconditionally whenever
  non-empty, keeping the return path entirely out of the crossing domain.
- **Flow control**: all backpressure is write-side. `tx_ready` deasserts at
  the occupancy threshold, which guarantees no overflow for any
  ready-respecting producer; a protocol violation latches sticky
  `overflow_err`. Word and packet counters instrument both directions.
- **Latency**: `PROP_CYCLES = ceil((E_O_NS + FIBER_M×4.9 + O_E_NS)/10)` models
  conversion + transit at the physical speed of light in glass (≈4.9 ns/m) +
  recovery. Measured idle-link latency is `PROP_CYCLES + 5` cycles at 100 MHz
  (synchronizer visibility + pop + pipe + output register): 7 cycles for the
  default 2 m span.
- **`optical_pair`**: two links sharing one reset form a bidirectional
  chassis-to-chassis port with an aggregate packet counter.

`tb_optical_link.v` instantiates a same-clock unit, an asynchronous 100↔80 MHz
pair, and a bidirectional pair, and verifies: exact idle latency, a 200-word
burst byte-exact with SOP/EOP alignment, a 600-word back-to-back flood with
zero loss and no overflow flag, sparse packets across idle gaps held in order,
the async crossing under sustained overload (observing `tx_ready` deassert),
and simultaneous bidirectional traffic.

### Scope / non-goals

- Single physical channel per link (paper VC classes → parallel instances)
- `doorbell.v` implements the three-condition fire (byte count + CRC + DEST) and the
  `NODE_ERR` refusal path; it does not model DMA burst scheduling into DRAM banks
- Byte-wide links for readability, not peak bandwidth modeling

See `../Paper.MD` §§2–4 for the architectural specification.

### IR toolchains (in `sim/internal/pnm/`)

The co-simulation harness includes three source-language-to-IR compilers that target
the HDL compute units:

| Toolchain | Source language | Target | File |
|-----------|----------------|--------|------|
| `CompileR` | R (statistical computing) | FP64 (`fp64_fma.v`) | `r_ir.go` |
| `CompileHaskell` | Haskell (functional) | FP64 (`fp64_fma.v`) | `haskell_ir.go` |
| `CompileHLSL` | HLSL (GPU shading) | FP32 ALU (`fp32_alu.v`) | `hlsl_ir.go` |

#### FP64 IR format (R and Haskell)

```
f64.load  r0, [addr]          # load FP64 from memory
f64.store [addr], r0          # store FP64 to memory
f64.add   r0, r1, r2          # r0 = r1 + r2 (FP64)
f64.mul   r0, r1, r2          # r0 = r1 * r2
f64.fma   r0, r1, r2, r3      # r0 = r1*r2 + r3 (fp64_fma.v)
f64.div   r0, r1, r2          # r0 = r1 / r2
f64.min   r0, r1, r2          # r0 = min(r1, r2)
f64.max   r0, r1, r2          # r0 = max(r1, r2)
f64.cmp   r0, r1, r2, ==      # r0 = (r1 == r2) ? 1.0 : 0.0
f64.mov   r0, r1              # r0 = r1
f64.const r0, 3.14159         # r0 = literal
```

#### FP32 ALU IR format (HLSL)

```
alu.load  r0, [addr]          # load FP32 from memory
alu.store [addr], r0          # store FP32 to memory
alu.add   r0, r1, r2          # r0 = r1 + r2 (FP32)
alu.sub   r0, r1, r2          # r0 = r1 - r2
alu.mul   r0, r1, r2          # r0 = r1 * r2
alu.div   r0, r1, r2          # r0 = r1 / r2 (28-cycle restoring div)
alu.min   r0, r1, r2          # r0 = min(r1, r2)
alu.max   r0, r1, r2          # r0 = max(r1, r2)
alu.cmp   r0, r1, r2, >=      # r0 = (r1 >= r2) ? 1.0 : 0.0
alu.dot   r0, r1, r2          # dot product (expanded to mul+add chain)
alu.lerp  r0, r1, r2, r3      # lerp(a,b,t) = a + t*(b-a)
alu.clamp r0, r1, r2, r3      # clamp(x, lo, hi)
alu.rcp   r0, r1              # reciprocal (1/x)
```

#### HLSL intrinsics supported

`dot`, `lerp`/`mix`, `clamp`, `saturate`, `abs`, `min`, `max`, `rcp`, `sqrt`,
`step`, `smoothstep`, `mul`, vector constructors (`float4`/`float3`/`float2`).

#### Transpilation pipeline (source → hardware)

```
Source code (R / Haskell / HLSL)
  │
  ├─ Parse: language-specific front end (r_ir.go / haskell_ir.go / hlsl_ir.go)
  │   └─ Extract assignments, arithmetic, function calls, conditionals
  │
  ├─ IR emission: typed register-based instruction set
  │   ├─ FP64 IR  (11 opcodes) → fp64_fma.v  (R, Haskell)
  │   └─ FP32 ALU IR (14 opcodes) → fp32_alu.v (HLSL)
  │
  ├─ Compute unit selection (model compiler)
  │   ├─ BF16 FMA    → MoE experts, dense MLP
  │   ├─ BF16 array  → attention QKV
  │   ├─ FP32 ALU    → layernorm (div + mul)
  │   └─ FP64 FMA    → scientific/R/Haskell workloads
  │
  └─ Flit emission: wrap result in wormhole packet
      └─ LAYER_ID | MODULE_ID | CTRL | LEN | payload | CRC-16
```

The compilers are **ahead-of-time (AOT)**: they run on the host, produce a
sequence of register operations, and the firmware dispatches each operation to
the appropriate compute unit node. No JIT compilation or runtime linking
occurs on the router chip.

#### IR-to-compute-unit mapping

| IR opcode | HDL module | Latency | Notes |
|-----------|-----------|---------|-------|
| `f64.fma` | `fp64_fma.v` | 3 cycles | Double-precision FMA |
| `f64.div` | `fp64_fma.v` | 3 cycles | Uses FMA's add path for div |
| `f64.add/mul/min/max/cmp` | `fp64_fma.v` | 3 cycles | All via FMA pipeline |
| `alu.add/sub/mul` | `fp32_alu.v` | 4 cycles | Via internal `fp32_fma` |
| `alu.div` | `fp32_alu.v` | 28 cycles | Left-shifting restoring division |
| `alu.min/max/cmp` | `fp32_alu.v` | 3 cycles | Pipelined signed comparison |
| `alu.dot` | `fp32_alu.v` | N×4 cycles | Expanded to N multiply+add ops |
| `alu.lerp` | `fp32_alu.v` | 3×4 cycles | `a + t*(b-a)` via MUL+ADD |
| `alu.clamp` | `fp32_alu.v` | 2×4 cycles | Two MIN/MAX operations |
| `alu.rcp` | software-lowered | ~27 cycles | Not an ALU datapath; lowered via div/cmp-select in the IR compilers |
| `alu.sqrt` | software-lowered | ~24 cycles | Not an ALU datapath; binary compare-select ladder in the IR compilers |
| BF16 FMA | `bf16_fma.v` | 3 cycles | MoE expert compute |
| BF16 array | `bf16_mac_array.v` | variable | Systolic attention QKV |
| INT8 MAC | `int8_mac.v` | 2 cycles | Quantized inference |

#### Toolchain limitations

The IR compilers target a **minimal register-based instruction set** with no
loops, branches, or dynamic allocation. Supported constructs:

| Language | Supported | Not supported |
|----------|-----------|---------------|
| **R** | Assignments, `+` `-` `*` `/`, comparisons, `sum` `mean` `min` `max` `prod` `sqrt` `abs` | Loops, `for`/`while`, arrays, `list`, recursion, `apply`, `paste` (skipped), `c()` (skipped) |
| **Haskell** | Function defs, guards, `let`/`in`, `do` blocks, `if`/`then`/`else`, `+` `-` `*` `/`, comparisons, `sum` `product` `minimum` `maximum` `abs` `sqrt` | Recursion, pattern matching, `where` clauses, lists, monads, type classes, guards with complex expressions |
| **HLSL** | `float`/`int`/`half` vars, `return`, ternary `?:`, `dot` `lerp` `clamp` `saturate` `abs` `min` `max` `rcp` `sqrt` `step` `smoothstep`, vector constructors (`float4`/`float3`/`float2`/`half`×N) | Loops, `if`/`else` blocks (only ternary), textures, samplers, vertex/fragment stages, matrices |

All three compilers produce **straight-line code**: the IR is a linear sequence
of instructions with no control flow. This is sufficient for inference
workloads (forward pass only) but not for training or iterative algorithms.

#### The host path, end to end (`pnm_host_top.v`)

`pnm_host_top.v` is the host bridge board's top level: it composes
`pi_bridge` (the SPI adapter) -> `pnm_arb` (the round-robin arbiter) ->
`pnm_host_bridge` (the router engine) and owns the address map, so the
arbiter's 8-bit byte offset and the bridge's 32-bit window are reconciled in
one place.

This module existed because the host path was never simulated.  Every
host-path testbench drove a *model* of the chip: `tb_host_bmc.v` and
`tb_dma_lpddr6.v` drove the SPI adapter and the arbiter into register files
they defined inside the testbench, and `tb_pnm_host_bridge.v` drove the
bridge alone.  The composition was not checked, and it did not work: the
arbiter's byte offset never selected a slave in the bridge, and the
bridge's registered read data was sampled by the arbiter one cycle before it
was updated, so every register read returned zero.  `tb_host_path_e2e.v`
(now the regression for both) drives the real chain over SPI with the same
48-bit frame the Raspberry Pi drivers speak, and checks a register
read-back, a byte-exact wormhole flit with an independently computed CRC-16,
the fabric's acceptance of that flit, and the result path.

The bridge's PNM read path is combinational for the same reason the 16550
and the gating ASIC present theirs: a registered read would be sampled one
cycle early by the arbiter.

#### The host bridge (`pnm_host_bridge.v`)

The router bridge is the only stateful silicon in the fabric, and it has **no
processor**: no CPU, no boot ROM, no timer, no console. It is a bridge the
host drives. The host runs the boot sequence, the weight upload and the
dispatch loop; the bridge keeps the hardware that must be hardware:

| Block | What it does |
|-------|-------------|
| PNM router engine | Flit builder (LAYER_ID, MODULE_ID, CTRL, LEN, payload, CRC-16/CCITT-FALSE), POST discovery, coordinate mapping, spine injection |
| SRAM | 64 KB: the routing table, the MoE map, and the host's staging area |
| Host register window | The route/payload/status/counter registers the host writes through |
| Host bus | The port the host attaches to: SPI (via `pi_bridge.v`) or PCIe |

Because the sequencing lives in the host, the same silicon serves a Raspberry
Pi, a microcontroller, or a workstation. `tb_pnm_host_bridge.v` plays the host:
it writes the routing and payload registers and checks that the chip emits a
byte-exact wormhole flit (header, payload, CRC over the protected body,
SOP/EOP) and that the result path and counters read back. `tb_host_bmc.v`
drives the same bridge from a Raspberry Pi model over the SPI adapter, through
the two-port arbiter (`pnm_arb`).

#### The gating ASIC and its two managers (`core/gating_asic.v`)

The gating ASIC is a **per-node** device: it holds the router weights and
produces the expert decision for each token that lands on its node. It has two
management paths onto one register file, and a strapping pin (`mgmt_sel`)
selects which one is live:

| Mode | Manager | Interface |
|------|---------|-----------|
| **A** | The embedded management node on the node board (an MCU or a Raspberry Pi Compute Module) | The management bus `mgmt_addr/wdata/rdata/we/valid/ready` — a direct local bus |
| **B** | The host | The fabric-side programming port `prog_data/valid/sop/eop` — the host's bytes, decoded into the same register map |

Mode A is for the board that owns the node: the embedded node also masters the
node's NoB, so it reaches the memory behind the node and can read the token's
hidden state out of local DRAM. It programs the gating weights once at setup
and then takes each token's decision locally — the decision never crosses the
fabric.

Mode B is for the host that owns the machine: it can reprogram the router of
any node at any time, and the same host firmware drives a Pi, a microcontroller
or a workstation.

The two modes are the same silicon and the same register map, so the decision
is identical either way. `tb_gating_modes.v` programs the same weights and the
same hidden state through each path and requires the same top-K selection.

What differs is only what crosses the fabric: in mode A the gating weights
cross once (0.3–1 MB of BF16 per layer) and no per-token management traffic
crosses at all; in mode B every weight byte crosses and every token's decision
crosses back (256 bytes of logits, or 8 bytes for the top-K identifiers, per
token per layer) on the same fabric that is already the capacity bottleneck.

#### KV cache architecture

Two modules manage the key-value cache on each node:

##### `kv_cache_bank.v`

On-node SRAM bank that stores KV pairs for attention layers. It operates as a
**pass-through with injection**: normal flits pass through transparently, but
when a KV store/load command arrives, the bank intercepts the flit and either
writes payload bytes to SRAM (store) or reads them back (load).

The bank tracks:
- `write_ptr` / `read_ptr`: circular buffer pointers
- `ks_state`: KV store FSM (header capture → payload capture → done)
- `kl_state`: KV load FSM (header capture → SRAM read → flit injection)

Eviction is LRU: when the bank is full, the oldest entry is overwritten. The
`reclaim_*` interface allows the offload engine to read evicted entries.

##### `kv_offload.v`

Offload engine that transfers KV pairs between node SRAM and the host via the
spine. It monitors `kv_cache_bank` for eviction events and constructs
appropriate flits for host-side storage. The offload path uses VC class 3
(highest priority) to avoid stalling compute traffic.

---

## 5. The co-simulation harness

> Comprehensive documentation for the PNM Architecture paper repository.

### Overview

This repository contains the working artifacts behind the paper *Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing*. It includes the manuscript source, a Go-Verilog co-simulation harness, Verilog HDL for the routing fabric, the compute units, and a CPU-less router bridge, and a build pipeline that produces the DOCX submission.

### Co-Simulation Harness (sim/)

#### Architecture

The harness is a Go standard-library-only program that:
1. Generates stimulus (manifest: dest, kernel, weights, bias, payload, CRC, golden)
2. Generates Verilog topology (`pnm_top.v`) and testbench (`tb_pnm.v`)
3. Compiles Verilog slices in parallel `iverilog` processes
4. Runs them in parallel `vvp` processes
5. Verifies hardware results against the golden model

#### Key Components

##### Core Types (`run.go`)

- `NodeID` - Physical coordinate: `{L, X, Y}`
- `Dims` - Chassis dimensions: `{Layers, Bx, By}`
- `StreamByte` - Wire byte with SOP/EOP/VC sideband
- `Flit(layer, dest, ctrl, payload, echo)` - Constructs wire-format flits
- VC class constants: `VC_BOARD_EGRESS=0`, `VC_SPINE_ASCENT=1`, `VC_SPINE_DESCENT=2`, `VC_ONBOARD_DELIVER=3`

##### Topology Generator (`gen_topology.go`)

Generates `pnm_top.v` from chassis dimensions. Each node gets:
- An `lxy_repeater` with a route bitmap parameter
- A `pe_tile_stub` with compute unit type and bias constant
- DMA ports for injection and delivery

##### Testbench Generator (`gen_tb.go`)

Generates `tb_pnm.v` for parallel vvp slices. Features:
- Injector task from `stimulus.hex` via $readmemh
- Per-node backpressure (ready 1 cycle in N)
- Delivery.log via $fwrite (including C verdict lines for stubs)
- Adaptive $finish after 200 quiet cycles

##### Virtual Execution Units (`virtual_units.go`)

`VirtualUnit.Consume()` implements the Go-side doorbell twin:
- Three-condition fire: byte count == LEN+6, CRC validates, DEST == LOCAL_MODULE
- Resident kernels: `echo`, `sum`, `accum`, `dot`
- Results checked against golden manifest

##### Discrete Event Simulator (`des.go`)

Activity-driven DES of the egress merge tree:
- Pipeline registers (HFRs, PE MAC pipes) separated by combinational gate clouds
- Three merge kinds: `mkYm` (Y-up), `mkXm` (X-up), `mkUp` (repeater upmerge)
- Cross-checks against RTL via `CrossCheckDES()`
- Shares no code with Verilog; reproduces delivery stream byte-for-byte

##### Model Compiler (`model_compiler.go`)

Five-stage AOT pipeline that transpiles HuggingFace models onto PNM chassis:

1. **Ingest** - Parse safetensors index + config.json, infer tensor shapes from ~20 naming patterns
2. **Partition** - Layer-to-physical mapping, expert round-robin, dense assignment, embedding sharding, KV cache reservation (80% of the post-weight budget, max 16K entries)
3. **Map** - Assign operations to kernel names and compute unit types by tensor role
4. **Route** - Compute 11-bit routing bitmaps and MoE expert map
5. **Emit** - Write .pnm program file and chassis schema

Key structs: `ModelCompiler`, `NodeAssignment`, `ComputeUnitType` (15 types), `TensorRef`

##### Safetensors Parser (`safetensors.go`)

Parses HuggingFace model format:
- `LoadSafetensorsIndex(dir)` - Parse weight_map from index JSON
- `LoadModelConfig(dir)` - Parse nested TextConfig
- `TensorShapeFor(name, cfg)` - Infer shapes from ~20 tensor name patterns
- `CollectTensors(idx, cfg)` - Merge index + config into full catalog

##### Host Driver (`driver.go`)

Orchestrates model loading and inference:
- `BuildWeightCommands()` - Deterministic weight upload sequence sorted L-X-Y
- `computeRouteBitmaps()` - Generate 11-bit routing bitmaps per node
- `computeMoeMap()` - Build expert-to-coordinate mapping

##### Firmware (`firmware.go`)

Models the central orchestrator chip:
- 5-phase boot: RESET -> POST_DISCOVERY -> ROUTING_TABLE -> WEIGHT_UPLOAD -> MOE_LOAD -> READY
- `PlanInference(token)` - Per-token dispatch: dense attention -> KV cache check -> MoE gating -> expert dispatch
- `VerifyWeightUpload(cmds)` / `VerifyDispatch(records)` - Runtime verification

##### LLM Client (`llm_client.go`)

End-to-end autoregressive inference:
- Tokenization (real BPE via `tokenizer.json` when present, else synthetic)
- Prefill + autoregressive generation
- Temperature/nucleus (top-p) sampling with numerical stability
- Per-inference statistics (tokens, dispatches, KV ops, CU utilization)

##### KV Cache (`kv_cache.go`)

Distributed KV cache with per-direction banks:
- 4 directional banks (X+, X-, Y+, Y-) per physical layer
- FIFO eviction at 80% capacity threshold
- Configurable eviction target (`EvictionMode`):
  - `EvictNone` — discard evicted entries (default, lossy)
  - `EvictDmaBmc` — DMA evicted entries to host BMC over spine (~500ns RTT)
  - `EvictNvme` — write evicted entries to NVMe via PCIe (persistent, high BW)
- Circular NVMe overflow region with configurable LBA range
- `EvictionStats` tracking: discard/DMA/NVMe write counts, bytes, errors

##### Deterministic RNG (`rng.go`)

Byte-exact clone of CPython's `random.Random`:
- MT19937 Mersenne Twister implementation
- Verified against CPython known outputs (`rng_test.go`)
- Same `--seed` reproduces identical stimulus across runs

##### Source Language Toolchains

| Compiler | Input | Output | Target CU |
|----------|-------|--------|-----------|
| `r_ir.go` | R (assignments, arithmetic, aggregations) | FP64 register-based IR | `fp64_fma` |
| `haskell_ir.go` | Haskell (functions, guards, do blocks) | FP64 register-based IR | `fp64_fma` |
| `hlsl_ir.go` | HLSL (float declarations, intrinsics) | FP32 ALU IR | `fp32_alu` |

IR is deliberately minimal: no loops, no branches, no dynamic allocation. Complex control flow is lowered to straight-line IR with explicit data dependencies.

#### Scenarios

| Scenario | Description | What it checks |
|----------|-------------|----------------|
| `sweep` | One flit to every node | Exact closed-form latency |
| `vcsweep` | Sweep + pass-through on all 4 VC classes | Arbitrated egress tree adds no delay |
| `load` | 500 random flits with 100/50/25% backpressure | Lossless delivery with slow consumers |
| `hotspot` | MoE hot-expert traffic on corner node | No drops under concentrated load |
| `stress` | ~24 flits/node, ~3% corrupt CRC | Doorbell refuses all corrupt messages |
| `replay` | Stress twice, bit-identical logs | Deterministic replay (no hidden state) |

#### CLI Tools

##### `cmd/pnm` - Co-Simulation Harness

```bash
go run ./cmd/pnm                         # 3x4x4 = 48 nodes, all 6 scenarios
go run ./cmd/pnm -l 8 -x 8 -y 8          # 512-node reference chassis
go run ./cmd/pnm --scenarios sweep stress --seed 1
go run ./cmd/pnm --groups 8              # force 8 parallel vvp slices
go run ./cmd/pnm --cpuprofile /tmp/pnm.cpu --memprofile /tmp/pnm.mem
```

##### `cmd/pnmc` - Program Compiler + Model Compiler + Driver

```bash
go run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8   # compile + run a program
go run ./cmd/pnmc compile-model examples/gemma4_test_synthetic -l 4 -x 4 -y 4   # model compiler
go run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -l 4 -x 4 -y 4      # driver + firmware
go run ./cmd/pnmc workload jacobi5 -l 1 -x 4 -y 4 -run                # workload simulation
go run ./cmd/pnmc workload matvec -l 4 -x 4 -y 4 -frag 16 -run        # matvec (16-element vectors)
go run ./cmd/pnmc workload reduction -l 4 -x 4 -y 4 -frag 32          # emit only
go run ./cmd/pnmc workload broadcast -l 4 -x 4 -y 4 -frag 64 -run     # broadcast fan-out
go run ./cmd/pnmc workload nbody -l 4 -x 2 -y 2 -frag 8 -run          # all-pairs saturation
go test ./internal/pnm/                  # all tests
```

All three `pnmc` entry points accept `--cpuprofile <f>` / `--memprofile <f>`
(pprof format; inspect with `go tool pprof -top /tmp/pnmc /tmp/cpu.out`).

##### Compiler performance (512-node Gemma-4 reference chassis)

Profiling `run-driver` at 8×8×8 showed 98.7% of CPU in synthetic weight-payload
generation: a per-byte loop over ~55 GB of payloads. Two changes fixed it while
keeping every emitted byte identical:

1. **Periodic-pattern template**: the deterministic fill `(base + i*5) & 0xFF`
   has period 256 bytes, so each tensor now builds one 256-byte template and
   fills its payload with `copy` (memmove-rate).
2. **Payload deduplication**: payload bytes depend only on
   (model layer, expert index, size), so identical tensors share one backing
   array instead of re-materializing per node. All consumers only read.

Result: 23.1 s → 4.9 s wall (~4.7x), 17.7 s → 1.3 s user CPU (~13x); the
remaining time is the runtime memmove for first-time materialization plus
process/sys overhead. Regression gate: `gemma4.pnm`, `routing_table.json`,
`moe_map.json`, and `dispatch_plan.txt` are byte-identical to the golden
artifacts in `submission/chassis_64tb_moe/` (8045 weight commands, 3840 expert
mappings, 512 nodes), and the full `go test ./internal/pnm/` suite passes.

Workload simulations exercise canonical HPC routing patterns against the gate-level fabric:

| Workload | Algorithm | Routing pattern |
|----------|-----------|----------------|
| `jacobi5` | 5-point Jacobi stencil | Intra-layer X→Y dimension-order (no spine) |
| `matvec` | Matrix-vector product, row-per-node | Spine descent for cross-layer rows |
| `reduction` | Reverse-path merge tree | Egress → Y-up → X-up → spine ascent |
| `broadcast` | Weight distribution from root | Spine descent + per-layer X→Y fan-out |
| `nbody` | All-pairs O(N²) interaction | All paths saturated (upper bound, ≤64 nodes) |

Measured results (`pnmc workload <name> ... -run`, all PASS: byte-exact delivery, kernels correct, zero drops, zero misroutes):

| Workload | Chassis | Frag | Doorbell activations | DMA bytes | Latency min/mean/max (cyc) | Worst span (cyc) |
|----------|---------|------|---------------------|-----------|---------------------------|------------------|
| `jacobi5` | 1×4×4 | — | 4 | 44 | 14/14/15 | 51 |
| `matvec` | 4×4×4 | 16 | 64 | 1,408 | 24/25/27 | 372 |
| `reduction` | 4×4×4 | 32 | 16 | 608 | 40/40/40 | 625 |
| `broadcast` | 4×4×4 | 64 | 64 | 4,480 | 72/73/75 | 1,140 |
| `nbody` | 4×2×2 | 8 | 256 | 3,584 | 16/16/17 | 962 |

The latency columns confirm the closed-form model of the paper's §3.4 per pattern class: intra-layer stencil traffic pays no spine term (14 cycles), spine-descent patterns pay the layer-hop count exactly (matvec 25 ≈ sweep's closed form plus one descent leg), and the reverse-path merge adds a constant merge-arbitration term (reduction is deterministic at 40). Broadcast cost scales with fan-out degree, not node count; nbody sustains near-wire-rate injection (≈4 bytes/cycle) at full all-pairs saturation.

#### .pnm Program Format

The .pnm format is a plain-text directive language:

```
# kernel <name> <dest_l> <dest_x> <dest_y> [weight_bytes...]
kernel sum 2 2 5
bias   7 2 2 5

# kernel with resident weights (hex)
kernel dot 7 7 7 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10
bias   3 7 7 7

# token <dest_l> <dest_x> <dest_y> <payload_hex...>
token 2 2 5   10 20 30 40 50 60 70 80 90 a0 b0 c0 d0 e0 f0 00
token 7 7 7   de ad be ef
```

### Build Commands

#### Paper
```bash
python3 build.py            # submission/paper.docx + .pdf + .tex
python3 build.py --review   # submission/paper_review.pdf (11pt single-column)
```

#### HDL Testbenches
```bash
cd HDL
iverilog -g2005 -o tb_fabric.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
iverilog -g2005 -o tb_load.out   hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v   && vvp tb_load.out
iverilog -g2005 -o tb_doorbell.out core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v && vvp tb_doorbell.out
# ... (see AGENTS.md for complete list)
```

#### Static Lint
```bash
verilator --lint-only -Wno-MULTITOP hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v
```

#### C Firmware
```bash
cd fw && gcc -Wall -Wextra -std=c11 -c pnm_fw.c -o pnm_fw.o
```

#### Co-Simulation
```bash
cd sim && go test ./internal/pnm/
```

---

## 6. Using the system

### Overview

The PNM (Processing-Near-Memory) Architecture is a distributed compute
platform designed for large-scale LLM inference. It places BF16/FP16/FP32
FMA compute units directly next to LPDDR6 CAMM2 memory modules, connected
by a byte-wide source-routed wormhole routing fabric.

This manual covers how the design works and how to build it, from Verilog
RTL through PCB assembly to firmware and boot.

### Build system

The build pipeline has three stages: RTL assembly, PCB design, and
firmware compilation.

#### Stage 1: RTL assembly

JSON schemas compose verified Verilog modules into complete board
assemblies. The builder validates every connection against actual port
lists, then emits a simulable wrapper.

```bash
# elaborate, compile, and smoke-run a board
python3 implementations/build_asm.py implementations/boards/node_board.json

# static lint only (verilator --lint-only)
python3 implementations/build_asm.py implementations/boards/node_board.json --lint

# emit wrapper + testbench without running iverilog
python3 implementations/build_asm.py implementations/boards/node_board.json --no-sim
```

The schema format (`pnm-assembly/v1`) is documented in
[The board assembly schema](#11-board-assembly-schema). Key sections:

- **`components[]`** — silicon instances (modules from `HDL/` with parameter overrides)
- **`connections[]`** — point-to-point nets (validated for existence, direction, width)
- **`tieoffs[]`** — constant drivers for configuration inputs
- **`external[]`** — top-level ports of the generated wrapper

PCB traces are components too: `pcb_link` with `DELAY_NS=40` models a 40 mm
motherboard trace. Clock gating uses `clk_gate`, reset synchronization uses
`rst_sync`.

##### Node compute variants

`HDL/core/node.v` is the compute node of the node network — one MoE expert
pass. Its `CU_TYPE` parameter selects the embedded numeric ASIC behind a
shared accumulate interface (`c = a*b + c`) and one control FSM, so the same
node source builds as different products:

| Board | `CU_TYPE` / `WIDTH` | Engine |
|-------|---------------------|--------|
| `boards/node_bf16.json` | 0 / 16 | BF16 expert: gate/up → swiglu → down |
| `boards/node_fp32.json` | 2 / 32 | FP32 MAC (identity activation) |
| `boards/node_int8.json` | 4 / 8 | INT8 MAC, INT32 accumulate |
| `boards/node_ternary.json` | 8 / 8 | BitNet b1.58 ternary {-1,0,+1} x INT8, INT32 accumulate |
| `boards/node_fp4.json`  | 6 / 8 | FP4 (E2M1) MAC, INT32 accumulate |
| `boards/node_dual_mem.json` | 0 / 16 | Reference node: BF16 expert + dual-module memory (`node_mem.v`, CHANNELS=2 = 2 x 64 GB 192-bit LPCAMM2, 384-bit) |

Values 1/3/5/7 select fp16/fp64/int4/`fp4`+MXFP4-block-scale respectively.
Each board instantiates `rst_sync` + `clk_gate` + `node` and builds, lints,
and smoke-sims clean. The BF16 (`CU_TYPE 0`) and INT8 (`CU_TYPE 4`) expert
passes are bit-exact validated by `HDL/core/node_reference_test.py` (flag
`--cu N`); the other formats are covered by their unit testbenches.

Generated artifacts (in `implementations/build/<name>/`):

| File | Contents |
|------|----------|
| `<name>_top.v` | Wrapper: external ports, wires, tieoffs, instances |
| `tb_<name>.v` | Clock/reset generator, idle-run testbench |
| `filelist.f` | Source files for iverilog/verilator |

#### Stage 2: PCB design

All boards use LibrePCB (open-source EDA), 4-layer stackup (top copper,
GND, power, bottom copper).

##### Interconnect board (parameterized)

The interconnect board is generated by `gen_schematic.py` (single fixed
variant; regenerates `circuit/` and `schematics/` in place).
`gen_topology.py` explores parameterized layouts (its circuit output carries
nets only — component instances must be completed in LibrePCB):

```bash
# Regenerate the shipped interconnect board
python3 pcb/interconnect_board/gen_schematic.py

# Parameterized layout exploration (output only)
python3 pcb/interconnect_board/gen_topology.py \
  --variant x2_lxy --layers 8 --board-x 4 --board-y 4 --output /tmp/board
```

Variants:
- **`x2_lxy`** — LXY repeater at center, HFR pipe stage, dual NoB connectors
- **`xy`** — Pure XY repeater (no Z-axis, no HFR)

The generator emits LibrePCB schematic files (`.lp`) with components,
netsegments, junctions, and labels.

##### Host bridge board (manual)

Two host attaches selected by solder jumpers:

| Option | Interface | Connector |
|--------|-----------|-----------|
| Pi Bridge | SPI slave (CM0-CM4) | 2x6 header |
| PCIe | Gen5 x16 | PCIe x16 edge connector |

Open `pcb/host_bridge/host_bridge.lpp` in LibrePCB to place and route.

##### Gating ASIC board (manual)

MoE gating ASIC with DRAM options:

| Option | Package | Notes |
|--------|---------|-------|
| LPCAMM2 socket | 644-pin, 0.5mm pitch | Field-replaceable, up to 64 GB |
| Soldered LPDDR5 | 200-ball, 0.65mm pitch | Compact, lower cost |

Open `pcb/gating_asic/gating_asic.lpp` in LibrePCB.

##### Compute node board (manual)

MAC ASIC (LGA-830) + **two** LPCAMM2 sockets (64 GB 192-bit modules, 384-bit
dual-module bus). Open `pcb/pnm_node/pnm_node.lpp`.
The RTL node (`HDL/core/node.v`) is `CU_TYPE`-selectable (BF16/FP16/FP32/FP64/
INT8/INT4/FP4/MXFP4) — see the node compute variants above. The dual-module
memory is the assembly board `implementations/boards/node_dual_mem.json`
(`node_mem.v`, `CHANNELS=2`).

##### PCB workflow

1. Open LibrePCB, File -> Open Project -> `pcb/<board>/<board>.lpp`
2. Add components from the local library (`library/`) or standard passives
3. Place footprints on the board; route DDR escape and fabric links
4. Run DRC; export Gerber + drill + BOM via File -> Output -> Manufacturing

#### Stage 3: Firmware (host side)

The chip has no firmware of its own: the host runs it. The repository ships
the dispatch firmware in two forms --- a Go reference model (the co-simulation's
golden implementation) and a C port with static allocation only, no `malloc`
and no OS dependency --- plus a cross-build system for a third-party RISC-V
MCU that acts as the host.

##### Host MCU (bare-metal, RV32I)

For a microcontroller acting as the host. No OS, no libc, static allocation.

```bash
cd toolchain/mcu
make            # → firmware.bin + firmware.hex
```

##### The C port (portable C11)

The dispatch loop, checked against the Go reference model.

```bash
cd fw
gcc -Wall -Wextra -std=c11 -c pnm_fw.c -o /dev/null   # compile check
```

##### Go reference model

```bash
cd sim && go test ./internal/pnm/ -run Firmware -count=1
```

#### Boot sequence

```
host firmware
  → POST discovery: walk the spine, identify all nodes
    → routing table load: program the flit builder's coordinate map
      → weight upload: stream model weights to the node DRAM
        → MoE gating load: program the expert-to-node assignment
          → dispatch loop: route tokens to experts, collect results
```

### Pi host drivers

Drivers for bridging from a Raspberry Pi to the PNM register window:

```bash
# Python (CM0-CM4 via SPI)
python3 pi_host/pnm_pi.py

# Go (CM0-CM4 via raw ioctl)
go run pi_host/pnm_pi.go

# Rust (CM0-CM4, zero crates)
rustc pi_host/pnm_pi.rs -o pnm_pi

# C (CM0-CM4 via spidev ioctl)
gcc -o pnm_pi pi_host/pnm_pi_spi.c

# C (CM5 via PCIe BAR0 mmap)
gcc -o pnm_pi_cm5 pi_host/pnm_pi_cm5.c
```

### Reproducing results

The top-level script runs all verification:

```bash
bash reproduce.sh    # co-sim, Go tests, HDL testbenches (exits on first failure)
```

### Unified host driver

The `pnmhost` CLI is a single entry point for all PNM workloads. It replaces
the fragmented `cmd/pnm`, `cmd/pnmc`, and language CLI toolchains with one
driver that handles scenarios, HPC benchmarks, programs, model compilation,
and LLM inference — all with timestamped logging and structured result export.

#### Commands

| Command | Description |
|---------|-------------|
| `pnmhost scenario <name> [...]` | Fabric verification (sweep, vcsweep, load, hotspot, stress, replay) |
| `pnmhost workload <name>` | HPC workload (jacobi5, matvec, reduction, broadcast, nbody) |
| `pnmhost program <path.pnm>` | Compile and run a .pnm program |
| `pnmhost model <dir>` | Compile a HuggingFace model onto the chassis |
| `pnmhost inference <dir> <prompt>` | Run LLM inference |
| `pnmhost benchmark` | Fabric sweep + cost/TCO model (PNM vs HBM vs SRAM LPU) |
| `pnmhost run <path.pnm>` | Auto-detect and run |

#### Usage

```bash
# Run multiple scenarios with result export
pnmhost scenario sweep load stress -l 4 -x 4 -y 4 -output results/

# Run an HPC workload
pnmhost workload matvec -l 4 -x 4 -y 4 -frag 32

# Compile and run a program with logging
pnmhost program examples/bias_add.pnm -log results/run.log

# Full model compilation + inference pipeline
pnmhost model examples/gemma4_test_synthetic -o results/
pnmhost inference examples/gemma4_test_synthetic "Hello, world!" -max-tokens 16

# Architecture benchmark: measured fabric sweep (latency / bytes-per-cycle /
# machine-checked delivery) + the projected cost/TCO table + the DRAM
# latency/bandwidth estimate (per memory class), exported to CSV/JSON
pnmhost benchmark -output results/bench
```

The benchmark report appends a `DRAM latency / bandwidth estimate` table:
for each memory class (LPDDR6 reference, LPDDR5X, LPDDR5, DDR5 baseline,
HBM3E, GDDR6) it derives a bandwidth-bound token rate (chassis aggregate
bandwidth after refresh / bytes-per-token) and a strict serial read-latency
floor (1/(30 layers x read latency)), then reports the headroom against the
honest alpha=7/8 fabric anchor (~1.1M tok/s) and the measured reference-chassis
sweep point. Every figure in that table is a characterized model input
(published-typical class values / repo RTL profiles), not a measurement; the
JSON export carries it under `dram_estimate`.

Two further model tables are appended, both labeled projections:

- **`Node-network energy estimate`** (`energy_estimate`): per chassis shape, the
  repeater/SerDes dynamic power `270 dispatches/token x mean NoB hops x per-hop
  repeater+SerDes energy` (hops = `E|layer diff| + E|dx| + E|dy|`, dimension-order
  spine + X/Y), the node rail power (`nodes x (idle 1.15 W + MAC 8.7 W + DRAM
  3.0 W)`, from `power_rails.v`), chassis infrastructure, and the wall power
  (raw/0.92 PSU). The flit-repeater network is a small share of a 512-node
  chassis (well under 1%).
- **`Per-node multi-channel memory`** (`memory_channels`): the `node_mem.v`
  interleave scaling — each node's memory split into C word-interleaved
  channels multiplies node bandwidth by C (per-channel rate unchanged) and
  widens the `node.v` `MEM_CHAN` ingest to `C x element width` bytes/clock. The
  reference node is two 64 GB 192-bit LPCAMM2 modules (128 GB, 384-bit, 32
  twelve-bit sub-channels, ~512 GB/s); the sweep runs the per-module and
  two/four-module points and flags the two-module reference row. The RTL is
  validated bit-exact by `HDL/core/node_mem_reference_test.py`
  (CHANNELS in {2,4,8}, CAS in {1,2,5}) and the node result is
  channel-invariant by `HDL/core/node_reference_test.py` (MEM_CHAN in {1,2,4}).
  The assembly board `implementations/boards/node_dual_mem.json` composes the
  two-module memory with the node (`build_asm.py`, vvp).

#### Global options

All flags can appear anywhere in the command line (order-independent):

| Flag | Description | Default |
|------|-------------|---------|
| `-l`, `-layers` | Spine layers / boards | 3 |
| `-x`, `-board-x` | X columns per board | 4 |
| `-y`, `-board-y` | Y rows per board | 4 |
| `-seed` | RNG seed | 0xC0FFEE |
| `-groups` | Parallel vvp slices | auto |
| `-output`, `-o` | Write results (CSV/JSON) to directory | none |
| `-log` | Write timestamped log to file | stdout only |
| `-flits` | Override flit count (scenarios) | per-scenario |
| `-frag` | Workload parameter (vector length, etc.) | per-workload |
| `-max-tokens` | Max inference tokens | 32 |
| `-temperature` | Sampling temperature (0=greedy) | 0 |

#### Programmatic API

```go
hd := pnm.NewHostDriver(pnm.HostConfig{
    Layers: 4, Bx: 4, By: 4,
    OutputDir: "results/",
    LogFile:   "results/run.log",
})
hd.RunScenarios("sweep", "load", "stress")
hd.RunWorkload("matvec", 32)
hd.RunProgram("examples/bias_add.pnm")
hd.RunModel("examples/gemma4_test_synthetic")
hd.RunInference("examples/gemma4_test_synthetic", "Hello")
hd.WriteResults()
fmt.Print(hd.Summary())
```

### Data output and logging

The co-simulation harness and inference client export structured results
for analysis. All output is opt-in via `--output <dir>`.

#### Co-simulation results (`cmd/pnm`)

```bash
go run ./cmd/pnm --output results/ --scenarios sweep load stress
```

Writes four files:

| File | Format | Contents |
|------|--------|----------|
| `pnm_run_results.csv` | CSV | Per-scenario: pass/fail, activations, rejections, packets, DMA bytes, latency min/mean/max, bytes/cycle throughput |
| `pnm_run_results.json` | JSON | Full `RunResult` with dims, seed, per-scenario metrics, error lists |
| `pnm_run_latency.csv` | CSV | Per-packet latency (one row per packet per scenario) for histogram/CDF analysis |
| `pnm_run_summary.csv` | CSV | Single-row summary across all scenarios (wide format, one column group per scenario) |

#### Inference results (`cmd/pnmc run-driver`)

```bash
go run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -o results/
```

In addition to `routing_table.json`, `moe_map.json`, and `dispatch_plan.txt`,
writes `dispatch_plan.csv` with per-dispatch-step structured data (layer, phase,
target node, expert index, flit bytes, compute unit, KV action).

#### MoE gating proof through real gates (`cmd/pnmc run-fabric -prompt`)

```bash
go run ./cmd/pnmc run-fabric examples/gemma4_test_synthetic -l 2 -x 2 -y 2 -n 1 -prompt "Hello world"
```

Runs the whole pipeline end-to-end on a scaled-down chassis: the prompt is
tokenized (the model's real BPE tokenizer when `tokenizer.json` is present,
otherewise a whitespace tokenizer over the synthetic `token_%d` vocabulary; IDs
packed 2-byte big-endian, 16 per 32-byte payload), the firmware scores it against
each model layer's full expert population (`Firmware.GateToken`, FNV-1a +
splitmix64, top-k with node mapping), and the dispatch flits are driven through
real iverilog/vvp gates. After the fabric proves byte-exact delivery, the
verified per-node resident-kernel outputs are printed, labeled with their
dense/MoE packet composition.

#### LLM client token export

The `LLMClient` provides two export methods:

- `WriteTokens(path, prompt, tokenIDs)` — writes prompt + generated text + token IDs to a human-readable file
- `ExportInference(path, prompt, tokenIDs, dispatches)` — writes complete inference result as JSON (tokens + stats + dispatch plan)

#### Programmatic API

```go
// Collect scenario results from RunOne
result, ok := pnm.RunOne(prog, nodes, dims, groups, 1)
if result != nil {
    pnm.WriteScenarioCSV("results.csv", []pnm.ScenarioResult{*result})
    pnm.WriteScenarioJSON("results.json", &pnm.RunResult{Scenarios: []pnm.ScenarioResult{*result}})
}
```

### Haskell-to-PNM compilation

The `pnmsrc` front end compiles a subset of Haskell, R, or HLSL to
dispatch instructions on the PNM chassis; `haskell_pnm`, `r_pnm` and
`hlsl_pnm` are per-language wrappers over the same implementation.
Haskell and R compile through an FP64 IR; HLSL compiles through an
FP32 ALU IR (`alu.*` ops targeting `fp32_alu.v`) that is then lowered
to the same `f64_*` PNM kernels for chassis dispatch.

#### Supported syntax

| Feature | Haskell | R | HLSL |
|---------|---------|---|------|
| Assignments | `f x y = expr` | `x <- expr` | `float x = expr;` |
| Arithmetic | `+`, `-`, `*`, `/` | `+`, `-`, `*`, `/` | `+`, `-`, `*`, `/` |
| Comparisons | `==`, `/=`, `<=`, `>=`, `<`, `>` | `==`, `!=`, `<=`, `>=`, `<`, `>` | `==`, `!=`, `<=`, `>=`, `<`, `>` |
| If-then-else | `if cond then val else val` | (not yet) | (not yet) |
| Function calls | `f arg1 arg2` | `f(arg1, arg2)` | `f(arg1, arg2)` |
| Built-in functions | `sum`, `product`, `abs`, `sqrt` | `sum`, `mean`, `min`, `max`, `abs`, `sqrt` | `dot`, `lerp`, `clamp`, `abs`, `sqrt`, `min`, `max`, `rcp` |
| Float literals | `3.14`, `1e-5` | `3.14`, `1e-5` | `3.14`, `1e-5` |
| Types | (untyped) | (untyped) | `float`, `float2`, `float3`, `float4`, `int` |

#### Example

Haskell:
```haskell
mul x y = x * y
add a b = a + b
f x y = add (add (mul x y) x) y
```

R:
```r
result <- x * y
result <- result + x
result <- result + y
```

HLSL:
```hlsl
float result = x * y;
result = result + x;
result = result + y;
```

#### Compilation pipeline

```
Haskell/R/HLSL source
  → FP64/FP32 IR (f64.add, alu.mul, ...)
  → PNM dispatch (kernel + token directives)
  → co-simulation on the chassis
```

Each operation maps to a node running an `f64_*` kernel. Haskell and
R emit the FP64 IR directly; HLSL emits an FP32 ALU IR that is
lowered to `f64_*` kernels for ABI/dispatch compatibility on the
chassis. Operands are packed in the FP64 payload format (8 bytes per
slot) in token payloads.

#### Chained dataflow execution (`-run`)

The static `.pnm` listing serializes operands as deterministic
name-hash placeholders, so a `.pnm` program dispatched through `pnmc`
exercises the fabric structure but never threads actual values between
operations. The `-run` flag executes the **value-accurate chained
dataflow** instead: each IR instruction's operand registers are
resolved against the real producer results, real big-endian FP64
payloads are packed into each node's token, and the whole schedule is
verified with a single cycle-exact fabric run (`PASS: byte-exact
delivery ...`). The `f64_*` kernels execute in the host twin exactly
as for any dispatched token; the fabric verifies byte-exact transport
of every chained payload.

Free input registers (variables with no writer) are bound with
`-inputs name=value,...` and printed back as `inputs bound:`. For
`hello.R`/`hello.hs`/`hello.hlsl` the free inputs are `x, y`. For a
Haskell program the executable is its **entry function** (`main` when
defined, otherwise the last function in source order), fully inlined
with the function's own parameters as its free inputs. Constant and
move instructions fold into the register file without a dispatch.

Expected output:
```
[0] f64_mul r0 @ (0,0,0)  args=[4 7]  ->  28   [PASS]
[1] f64_add r0 @ (0,0,1)  args=[28 4]  ->  32   [PASS]
[2] f64_add r0 @ (0,1,0)  args=[32 7]  ->  39   [PASS]

result (r0) = 39   3 fabric dispatches across 3 node(s)
inputs bound: x, y
```

##### Function placement (`-place`, Haskell)

`-place` gives each compiled function a dedicated node and runs the
program's **entry function on the router SBC**. The SoC router chip
(orchestrator) executes the entry frame's control arithmetic on the host
side and dispatches every callee function's arithmetic to that function's
assigned node over the fabric. The assignment mirrors the `.pnm`
round-robin formula in source order:

```
-- funcs.hs
mul x y = x * y
add a b = a + b
main x = x + add (mul 4 7) 7

$ go run ./cmd/haskell_pnm funcs.hs -l 2 -x 2 -y 2 -run -place -inputs x=4

  mul      -> node (0,0,0)
  add      -> node (0,0,1)
  main     -> router SBC (entry, orchestration + folding)

  [2] f64_mul r12 @ (0,0,0)  args=[4 7]  ->  28   [PASS]
  [5] f64_add r14 @ (0,0,1)  args=[28 7]  ->  35   [PASS]
  [7] f64_add r7  @ router-SBC           ->  39   [PASS]

  result (r7) = 39   2 fabric dispatches across 2 node(s), 1 router-SBC fold(s)
```

The entry frame's own arithmetic (``x + add (mul 4 7) 7``'s leading
`+`) folds on the router SBC; only callee-function math is dispatched.
The R and HLSL frontends define no functions, so `-place` is
Haskell-only.

#### Usage

```bash
cd sim

# the unified front end (the language comes from the extension)
go run ./cmd/pnmsrc examples/hello.hs -l 2 -x 2 -y 2
go run ./cmd/pnmsrc examples/hello.hs -l 2 -x 2 -y 2 -run -inputs x=4,y=7
go run ./cmd/pnmsrc examples/hello.R -l 2 -x 2 -y 2 -run -inputs x=4,y=7
go run ./cmd/pnmsrc examples/hello.hlsl -l 2 -x 2 -y 2 -run -inputs x=4,y=7

# ... or name the language explicitly
go run ./cmd/pnmsrc -lang haskell examples/hello.hs -run -inputs x=4,y=7

# the per-language wrappers (same implementation)
go run ./cmd/haskell_pnm examples/hello.hs -l 2 -x 2 -y 2 -run -inputs x=4,y=7
go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2 -run -inputs x=4,y=7
go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2 -run -inputs x=4,y=7
```

#### FP64 kernels

| Kernel | Payload | Result |
|--------|---------|--------|
| `f64_add` | `[a:8B, b:8B]` | `a + b` (8 bytes) |
| `f64_sub` | `[a:8B, b:8B]` | `a - b` (8 bytes) |
| `f64_mul` | `[a:8B, b:8B]` | `a * b` (8 bytes) |
| `f64_div` | `[a:8B, b:8B]` | `a / b` (8 bytes) |
| `f64_fma` | `[a:8B, b:8B, c:8B]` | `a*b + c` (8 bytes) |
| `f64_min` | `[a:8B, b:8B]` | `min(a,b)` (8 bytes) |
| `f64_max` | `[a:8B, b:8B]` | `max(a,b)` (8 bytes) |
| `f64_neg` | `[a:8B]` | `-a` (8 bytes) |
| `f64_cmp` | `[a:8B, b:8B, op]` | `1.0/0.0` for `a OP b` (8 bytes; `OP` in `==,!=,<,>,<=,>=`, NaN compares unordered) |

### Hardware-gated inference (`cmd/pnmgate`)

`pnmgate` runs the MoE gating decision on the **RTL Gating ASIC**
(`HDL/core/gating_asic.v`) under `vvp` instead of in software: it loads a
layer's real `router.proj.weight` rows into the ASIC's on-chip RAM over the
register bus, runs the gating network (all expert logits plus top-k, BF16
fused-FMA) on the ASIC, feeds the ASIC's logits back into the engine's
softmax and MoE path, and finishes the forward pass on the CPU.

```bash
cd sim && go run ./cmd/pnmgate -model "$PNM_MODEL_DIR" -layers 0 -width 256 \
    "What is the capital of Germany"
# -> answer: "The capital of Germany is Berlin.<turn|>"   (same as the software engine)
```

| Flag | Meaning |
|------|---------|
| `-model` | the checkpoint directory (real weights) |
| `-layers` | model layers to gate, e.g. `0` or `0,7,14` |
| `-width` | the projection width loaded into the ASIC (256 = the paper's gating-SRAM tile; 2816 = full hidden) |
| `-max-tokens` | tokens to generate (0 = run until the stop token) |
| `-prefill-last` | gate only the final prefill position (default true) |
| `-think` | print the model's reasoning trace separately from the answer |
| `-network` | dispatch the ASIC's selected experts over the node-network fabric RTL |
| `-net-bx`, `-net-by` | the chassis grid (default 4×4) |
| `-net-layers` | chassis depth (default: cover the gated layers) |
| `-net-seed` | deterministic seed for the node resident weights |
| `-net-replays` | repeat the fabric run to check determinism |
| `-run-dir` | scratch directory for the ASIC's I/O files |
| `-keep`, `-v` | keep the scratch files / verbose ASIC logging |

With `-network`, each top-k expert becomes a routed flit on the X/Y grid and
`RunOne` proves byte-exact delivery to the expert node before the expert math
runs on the CPU:

```bash
cd sim && go run ./cmd/pnmgate -model "$PNM_MODEL_DIR" -layers 0 -width 256 \
    -network "Hello"
# -> asic L0 top-k experts: [109 103 51 41 1 79 4 56]
# -> network: 8 packets, 8 doorbell activations, 304 DMA bytes, latency 40/41/43 cyc
# -> network: PASS — byte-exact to the expert nodes
```

Expert `e` of layer `l` maps to node `(l, e mod bx, (e/bx) mod by)`.
`reproduce.sh --real-weights` exercises this end to end.

### Workload classification

#### Small chassis (an MCU host)

- Stencil (jacobi5): intra-layer nearest-neighbor communication
- Reduction: tree-based parallel reduction along the spine
- Broadcast: fan-out from spine root to all nodes
- Matrix-vector multiply: spine descent, single-layer

#### Full chassis (a Pi or workstation host)

- LLM inference: model compiler transpiles HuggingFace safetensors
- MoE dispatch: top-k expert selection, gating, token routing
- KV cache management: FIFO eviction
- Model weight persistence: the host's own storage

#### Compute-intensive

- O(N^2) saturation: n-body all-pairs (tests bisection bandwidth)
- Attention QKV: BF16/FP16 systolic array
- Dense MLP: BF16 FMA across all nodes

### Real-weight inference

The harness runs the actual Gemma 4 26B-A4B checkpoint on the simulated
hardware stack — a self-contained pure-Go forward pass over the real BF16
weights with the real BPE tokenizer (no torch, no external runtime).
See [Real weights](#8-real-weights) for the benchmark numbers and examples:

```
cd sim && go run ./cmd/pnmhost inference /data/gemma4_dl/complete \
  "What is the capital of France?" -max-tokens 40

go run ./cmd/pnmc run-fabric /data/gemma4_dl/complete -l 2 -x 2 -y 2 \
  --prompt "Who was Alan Turing?"
```

Summary: decode ≈ 6.5 s/token steady-state (single-threaded scalar Go),
peak RSS ≈ 21 GB, deterministic splitmix64-seeded sampling.

---

## 7. Profiling and benchmarks

### Simulation Benchmarks

#### Co-simulation Harness (`sim/`)

The Go co-simulation harness (`cmd/pnm`) runs six scenarios against the generated
Verilog fabric, measuring cycle-accurate latency and throughput.

**Run all scenarios:**
```bash
cd sim && go run ./cmd/pnm                       # default 3x4x4 = 48 nodes
cd sim && go run ./cmd/pnm -l 8 -x 8 -y 8        # 512-node reference chassis
cd sim && go run ./cmd/pnm --scenarios sweep stress --seed 1
```

**Profiling:**
```bash
go run ./cmd/pnm --cpuprofile /tmp/pnm.cpu --memprofile /tmp/pnm.mem
go tool pprof -http=:8080 /tmp/pnm.cpu
```

**Model compiler profiling:**
```bash
go run ./cmd/pnmc --cpuprofile /tmp/pnmc.cpu compile-model examples/gemma4_test_synthetic -l 8 -x 8 -y 8
```

#### Scenario Descriptions

| Scenario | What it measures | Pass criterion |
|----------|-----------------|----------------|
| `sweep` | Exact closed-form latency per flit path | Byte-exact match to formula |
| `vcsweep` | Sweep + all 4 VC classes, MixedVC | Byte-exact match |
| `load` | 500-flit throughput, per-node backpressure | Floor check |
| `hotspot` | MoE hot expert, kilobyte tokens, 1-in-8 DMA | Floor check |
| `stress` | ~3% corrupt-CRC messages, doorbell rejection | Reject count match |
| `replay` | Stress run twice, delivery logs bit-identical | Replay determinism |

#### Closed-Form Latency

The sweep scenario asserts exact equality to:

```
latency = wire_len - 1 + l_eff + x + PE_PIPE_DELAY
```

Where:
- `wire_len`: byte-wide link pipeline depth (HFR stages)
- `l_eff`: effective spine hops scoped to this slice (layer repeater + crossbar)
- `x`: X-dimension hops
- `PE_PIPE_DELAY = 2`: generated MAC stub elastic pipe

This is the exact closed form asserted by the sweep scenario (`verify()`
in `sim/internal/pnm/run.go`): one cycle per HFR/stage (`wire_len - 1`),
plus `l_eff` spine hops and `x` X-lane hops, plus the node MAC pipe.

#### Workloads

```bash
go run ./cmd/pnmc workload jacobi5 -l 1 -x 4 -y 4 -run     # stencil (intra-layer)
go run ./cmd/pnmc workload matvec -l 4 -x 4 -y 4 -frag 16 -run   # matvec (spine)
go run ./cmd/pnmc workload reduction -l 4 -x 4 -y 4 -frag 32 -run # reduction
go run ./cmd/pnmc workload broadcast -l 4 -x 4 -y 4 -frag 64 -run # broadcast
go run ./cmd/pnmc workload nbody -l 4 -x 2 -y 2 -frag 8 -run     # O(N^2) saturation
```

### HDL Synthesis Metrics

#### Verilator Lint

```bash
# Individual modules
verilator --lint-only <module>.v

# Full orchestrator_sbc
verilator --lint-only -Wno-MULTITOP orchestrator_sbc.v rv32_core.v uart.v clint.v pcie_phy.v nvme_ctrl.v

# Full fabric
verilator --lint-only -Wno-MULTITOP hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v
```

#### Resource Estimates (post-lint, iverilog elaboration)

| Module | Approx. gates | Notes |
|--------|--------------|-------|
| `rv32_core.v` | ~3K | 5-stage FSM, no caches |
| `uart.v` | ~200 | 16550-compatible |
| `clint.v` | ~150 | mtime + msip |
| `bmc_orchestrator_top.v` | ~8K | Full BMC SoC |
| `orchestrator_sbc.v` | ~15K | SBC + SRAM + PCIe + NVMe |
| `orchestrator_sbc_moe.v` | ~12K | SBC + MoE gating + BF16 |
| `pcie_phy.v` | ~4K | Gen5 x16 LTSSM + DMA |
| `nvme_ctrl.v` | ~3K | NVMe command FSM + DMA |
| `bf16_fma.v` | ~1K | 3-cycle FMA pipeline |
| `moe_gating.v` | ~2K | Top-k sorter |
| `doorbell.v` | ~500 | 3-condition fire + CRC |
| `lpddr5_phy.v` | ~1K | 4-bank, CL16 |
| `lpddr5x_phy.v` | ~1K | 4-bank, CL14 |
| `lpddr6_phy.v` | ~500 | Flat, CL4 |

#### Simulation Timing

| Testbench | Sim time | Notes |
|-----------|----------|-------|
| `tb_fabric` | ~500 us | 500 flits, 6 scenarios |
| `tb_orchestrator_sbc` | ~945 us | SRAM + DRAM + PCIe + NVMe |
| `tb_bmc_orchestrator` | ~50 ms | Full BMC boot sequence |
| `tb_pcie_phy` | ~19 ms | 12-test suite |
| `tb_nvme_ctrl` | ~10 ms | 8-block read/write |
| `tb_lpddr5_phy` | ~3.5 ms | Write/read + telemetry |
| `tb_lpddr5x_phy` | ~3.5 ms | Write/read + telemetry |
| `tb_lpddr6_phy` | ~3.3 ms | Write/read + telemetry |

#### Scaling Profile

| Chassis | Nodes | Layers | Sim time (sweep) | vvp processes |
|---------|-------|--------|-------------------|---------------|
| Small   | 16    | 1      | ~1s               | 1             |
| Default | 48    | 3      | ~5s               | 3             |
| Large   | 128   | 4      | ~15s              | 4             |
| Full    | 512   | 8      | ~60s              | 8             |

### Go Test Suite

```bash
go test ./internal/pnm/                         # all tests
go test ./internal/pnm/ -run TestPyRand          # CPython RNG pinning
go test ./internal/pnm/ -run TestDESClosedForm   # DES twin validation
go test ./internal/pnm/ -run TestDESCrossCheckRTL # DES vs RTL cross-check
go test -bench=. ./internal/pnm/                 # microbenchmarks
```

### Compiler Profiling

```bash
# C firmware (compile check)
gcc -Wall -Wextra -std=c11 -c fw/pnm_fw.c -o /dev/null

# Model compiler
go run ./cmd/pnmc compile-model examples/gemma4_test_synthetic -l 8 -x 8 -y 8
go run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -l 8 -x 8 -y 8

# Program compiler (default mode; no subcommand)
go run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8
```

---

## 8. Real weights

The co-simulation harness runs the **actual Gemma 4 26B-A4B checkpoint** on
the simulated stack — no torch, no transformers, no Python runtime — a pure Go
forward pass over the real BF16 weights, driven by the real Gemma BPE
tokenizer, with the fabric/firmware/MoE dispatch artifacts underneath.  As of
the parity session it is **greedy-token-identical to a Hugging Face / vLLM
reference** on the tested chat prompts.

### Download the model

The checkpoint is a gated Google release.  Accept the licence on Hugging
Face, create a read token, then:

```bash
HF_TOKEN=hf_xxx ./download_model.sh                 # -> models/gemma-4-26B-A4B (~52 GB)
HF_TOKEN=hf_xxx ./download_model.sh --out /data/gemma4_dl/complete
```

Every file is pinned to its upstream SHA-256 and verified after download; a
partial transfer is resumed (`curl -C -`) and a corrupt one is re-fetched.
Point `PNM_MODEL_DIR` at the directory (or pass it as the first argument to
`pnmhost inference`).  The instruction-tuned checkpoint used only for chat
templates can be fetched with `--repo google/gemma-4-26B-A4B-it`.

`reproduce.sh --real-weights` downloads the model if absent and then runs the
serving check below (needs `HF_TOKEN`).

### Model under test

| Property | Value |
|---|---|
| Model | google/gemma-4-26B-A4B (Gemma 4, 26.5B params, BF16) |
| Weights | `models/gemma-4-26B-A4B/` (2 shards, URL+SHA-256 pinned in `download_model.sh`) |
| Tokenizer | `tokenizer.json` — 262,144 vocab, byte-fallback BPE, 514,906 merges |
| Chassis | 30 layers × hidden 2816, 16 attn heads (256) / 2 global KV (512) on full-attn layers |
| MoE | 128 experts, top-8, gate_up_proj [128,1408,2816] + down_proj [128,2816,704] |

### Serving parity with HF/vLLM (greedy)

Two things were needed to behave like a real serving stack — answer the
question and stop:

1. **Chat template = `enable_thinking` rendering.**  HF
   `apply_chat_template(..., enable_thinking=True)` prepends a system turn
   `<|turn>system\n<|think|>\n<turn|>\n` (ids `[105 9731 107 98 107 106 107]`)
   even with no user system message.  The engine now emits the same ids as HF.
2. **bf16 store emulation.**  HF/vLLM store every activation tensor in bf16
   between ops.  `roundBF16` (round-to-nearest-even) is applied at every
   store: embeddings, all Linear outputs, every RMSNorm/vNorm, RoPE cos/sin +
   rotated outputs, the SDPA output, GELU/swiglu gate·up products, the expert
   gate/up/act/down and the bf16 weighted add (bf16 accumulate), the router
   chain (norm × scale × hidden^-½ → Linear → softmax → normalized weights),
   the tied-embedding logits and the final softcap, the KV cache, residual
   adds and layer boundaries.  Router weights now land on HF's exact bf16
   grid and near-ties (e.g. the L5 7↔27 tie) break like HF.

Greedy results (verified against HF `transformers` 5.12, bf16, CPU):

| Prompt (chat template) | Engine greedy tokens | Match |
|---|---|---|
| "What is the capital of Germany" | `[818 5279 529 9405 563 15687 236761 106]` → "The capital of Germany is Berlin." | first 8 = HF exactly, stops on `<turn|>` (106) |
| "What is the capital of France?" | `[818 5279 529 7001 563 9079 236761 106]` → "The capital of France is Paris." | first 8 = HF exactly |
| "The capital of Germany is" (plain completion) | step-0 token now `▁Germany` (matches HF) | diverges at step 1 only on ~1-ULP router near-ties |

```bash
$ pnmhost inference models/gemma-4-26B-A4B "What is the capital of Germany" -max-tokens 32
[1m48s] real-weights forward: "The capital of Germany is Berlin.<turn|>" (engine: gemma4-bf16)
  result: ALL PASSED
```

The base checkpoint is a pretrained text-completer, not an instruction-tuned
assistant: asked to "define concatenation" it echoes or loops under either
template.  Use the `-it` variant (`--repo google/gemma-4-26B-A4B-it`) for
instruction answers; the numeric engine is the same.

### Run it

```bash
cd sim
go run ./cmd/pnmhost inference "$PNM_MODEL_DIR" "What is the capital of Germany" -max-tokens 32

# real-weight debug harnesses (logits / routes / chat ids), opt-in:
PNM_REAL_TESTS=1 go test ./internal/pnm/ -run TestTmp -count=1 -v

# fabric dispatch with real token payloads through the Verilog co-sim:
go run ./cmd/pnmc run-fabric "$PNM_MODEL_DIR" -l 2 -x 2 -y 2 --prompt "Who was Alan Turing?"
```

### Benchmark (single process, host CPU)

30-layer stack, 262,144-vocab logits per step, BF16 weights, pure-Go float32
arithmetic and bf16 store rounding (no BLAS, no SIMD, no GPU).

| Run | Wall | Notes |
|---|---|---|
| load + prefill + 1 token | 76.8 s | embedding (3 GB) + full prompt attention + 1 decode |
| full chat answer (8 tokens) | 108.9 s | stops on `<turn|>`; `-max-tokens` above 8 does not extend it |
| steady-state decode | ≈5 s/token | one KV append + 30 layers + full-vocab logits |
| peak RSS | ≈15.9 GB | cached BF16 weight matrices; experts read per top-k row |

- The 262,144 × 2816 embedding is ~3 GB; the full-vocab logits (738 M MAC per
  step) dominates decode.
- MoE experts materialise only the top-8 rows per token (46 MB/step instead of
  the full ~2 GB gate_up/down per layer) — the RL dispatch the paper describes.
- At the paper's projected silicon (1 GHz, systolic arrays) the fabric loop
  timing is `Scenario model-fabric [PASS]`.

### RTL proof of concept: real weights on the BF16 FMA array (vvp)

The full numeric forward runs in Go because a cycle-accurate simulation of
26 B parameters is infeasible, and the RTL currently exposes the compute
*primitives* (BF16 FMA, systolic MAC array, MoE gating, RoPE, KV cache)
rather than an integrated transformer datapath.  To show that real checkpoint
weights *do* execute on the project's BF16 FMA hardware, `real_matvec_poc.py`
runs a real tensor through the systolic array under `iverilog`/`vvp` and checks
the result bit-for-bit:

```bash
python3 HDL/core/real_matvec_poc.py --model "$PNM_MODEL_DIR"
```

It takes a 16×16 tile of the real layer-0 `router.proj.weight` and a real
16-wide activation (the scaled embedding of token 15938, `√2816 · embed`),
loads them into `bf16_mac_array.v`, fires the array, and compares the 16
outputs against an exact BF16-FMA reference (exact product+sum, round-nearest-
even to bf16).  Result: **16/16 outputs bit-exact**, e.g. column values
`be00 3d8f be03 3e4f …` — a genuine MoE router projection slice computed on
RTL BF16 FMA units under `vvp`, not in Go.

### RTL: integrated decoder block, bit-exact on real layer-0 (vvp)

A full decoder datapath — attention + KV cache + dense gelu-tanh MLP + MoE
top-2 experts — now runs as RTL under `iverilog`/`vvp` and reproduces the
Go/HF reference **bit-for-bit** on real weights.

- `HDL/core/bf16_fp.vh` — combinational BF16 library: mul/add/sub/div
  (exact-RNE with FTZ), exp (log2-e range reduction + 17-entry 2^(i/16) LUT),
  rsqrt (exponent-halve seed + 4 Newton iters), tanh (`1 − 2/(e^2x+1)`),
  gelu-tanh, numeric `bf16_gt`/max/softmax helpers.  Validated standalone:
  **10984/10984 vectors bit-exact** vs the exact-Fraction oracle in
  `bf16_fp_ref.py` (mul/add/sub/div/exp/rsqrt/tanh).
- `HDL/core/gemma_decoder_block.v` — parameterised FSM (one clock per stage,
  ~45 stages) mirroring `decoder_forward()` in `real_decoder_block.py`:
  input norm → q/k/v → per-head q-norm + half-split RoPE → attention scores
  → max-subtract softmax over the KV cache → context → o-proj →
  post-attn-norm + residual → pre-ff norm → dense gate/up gelu-tanh → 
  post-ff-1 norm → router (norm-no-scale × scale × hidden^−½ → E-softmax
  → top-2 → renormalise → × per_expert_scale) → pre-ff-2 norm over the plain
  residual → ascending top-2 experts (gate_up / down with gelu-tanh) →
  post-ff-2 norm → combine + post-ff norm + residual → × layer_scalar.
- `HDL/core/real_decoder_block.py` — BF16 spec reference + emitter (homunculus
  N=16 NH=2 HD=8 FFD=16 E=4 EFF=8 CACHE=4, real layer-0 slices + real
  embeddings, `√2816` embed scale, θ=1e4 rope).  Emits `dblock_{addrs,vmem,kc,
  vc,rope,x,out}.hex`, compiles both `.v`, runs `vvp` and compares every
  output word:
  `*** PASS: integrated decoder block N/16 bit-exact vs BF16 reference ***`
  (output `3d88 bdf6 be02 bf11 bd8c be36 bde6 beac c052 …`).

```bash
python3 HDL/core/bf16_fp_ref.py      # self-contained bf16 library check
python3 HDL/core/real_decoder_block.py --model "$PNM_MODEL_DIR"
```

### RTL: compute node, bit-exact on real layer-0 expert (vvp)

`HDL/core/node.v` is the compute node of the node network — one MoE expert
pass (gate/up → gelu-tanh·up → down) on the same BF16 fused-FMA datapath as
the router. Its `CU_TYPE` parameter selects the embedded numeric ASIC behind
one shared accumulate interface (`c = a*b + c`) and control FSM:

| `CU_TYPE` | Engine | `WIDTH` | Datapath |
|-----------|--------|---------|----------|
| 0 | `bf16_fma` | 16 | gate/up → swiglu → down (Gemma expert) |
| 1 | `fp16_fma` | 16 | gate → down (identity activation) |
| 2 | `fp32_fma` | 32 | gate → down |
| 3 | `fp64_fma` | 64 | gate → down |
| 4 | `int8_mac` | 8 | INT8 gate → down, INT32 accumulate |
| 5 | `int4_mac` | 8 | packed-nibble INT4 |
| 6 | `fp4_mac` | 8 | FP4 (E2M1) |
| 7 | `fp4_mac` | 8 | FP4 + `MXFP4_SHIFT` block scale |

`node_reference_test.py` + `tb_node.v` boot the weight SRAM, stream the
hidden vector, then compare every output word against an exact oracle:

```bash
python3 HDL/core/node_reference_test.py            # BF16, random 16x8 -> bit-exact
python3 HDL/core/node_reference_test.py --cu 4     # INT8 expert pass -> bit-exact
PNM_MODEL_DIR="$PNM_MODEL_DIR" \
  python3 HDL/core/node_reference_test.py --real   # real layer-0 expert 0 -> bit-exact
```

CU 0 (BF16) is bit-exact vs the fused-FMA + bf16_fp.vh gelu oracle; CU 4
(INT8) vs an exact integer matvec. CU 1/2/3 report a finite-value smoke and
CU 5/6/7 an elaboration+run smoke (their arithmetic is validated by each
unit's own testbench).

### Architecture notes (how it maps to the paper)

1. **Real weights**: `safetensors.go` header parsing + absolute-offset
   row-range reads; only the top-k expert rows are materialised per step.
2. **Tokenizer**: `real_tokenizer.go` — byte-fallback BPE with 514,906 merges,
   wired into the host SDK, `compile-model`, `run-fabric` and `run-driver`.
3. **Forward engine** (`real_infer.go`) per HF `modeling_gemma4.py`: q/k/v
   RMSNorm, half-split RoPE (θ=1e4 sliding / θ=1e6 partial-0.25 full), attn
   scaling 1.0, k_eq_v full layers, scaled embeddings (√hidden), dense
   gelu-tanh MLP + top-8 MoE with per-expert scale, router norm-no-scale
   transform, layer_scalar, logit softcap 30, tied-embedding logits, KV-cache
   prefill/decode; every tensor store is bf16-rounded.
4. **Sampling**: greedy by default (`-temperature 0`); splitmix64-seeded
   temperature sampling when set.

### Verification

- `go build ./...`, `go vet ./...` clean; `go test ./internal/pnm/` green
  (3.6 s; the real-weight harnesses are gated behind `PNM_REAL_TESTS=1`).
- `reproduce.sh` — all scenarios and testbenches pass.
- BPE round-trip `"Who was Alan Turing?"` ↔ `[15938 691 27369 63809 236881]`.
- Greedy serving parity: Germany and France chat token-for-token against HF
  through the terminating `<turn|>`.
- RTL PoC: real router-weight tile on `bf16_mac_array` bit-exact under vvp.
- RTL integrated decoder block (attn+MLP+MoE) bit-exact vs the BF16 reference
  on real layer-0 slices; `bf16_fp` library 10984/10984 vectors bit-exact.
- RTL compute node (`node.v`) full MoE expert pass bit-exact vs the fused-FMA
  oracle (BF16 + INT8), incl. a real layer-0 expert-0 gate_up/down slice.

### Known limitations

- The plain-completion path still diverges from HF at step 1 on ~1-ULP router
  near-ties (f32 accumulation order vs torch) — not a structural bug.
- Single-threaded scalar Go: ≈5 s/token decode.
- Intermediates are f32 with bf16 stores at tensor boundaries, matching the
  reference storage regime; bit-exactness of the *accumulation order* inside a
  matmul is not guaranteed against torch.

---

## 9. The boards

Physical board designs for the PNM architecture, targeting [LibrePCB](https://librepcb.org)
as the EDA tool. LibrePCB is a cross-platform, open-source PCB design suite that
produces production-ready Gerber/drill files and BOMs — no license server, no
vendor lock-in, no binary file corruption.

### Chassis architecture

A PNM chassis is a vertical stack of 1-15 board layers connected by a central
spine cable (the 4-bit Layer ID field of the routing bitmap caps a chassis at 15
routable layers; see the paper's Section 4.4). The reference chassis is 8 layers
with 64 compute nodes per layer (512 nodes total). The spine is a single cable:
every board layer taps that same line through its lxy_repeater, and the one
control board sits at the spine's root (one end). There are no branching fabric
paths, with the spine running as one vertical line through every layer:

```
                ┌───────────────────────┐
                │ host bridge board     │
                │ (spine root)          │
                │ PCIe/SPI + PNM bridge │
                └───────────┬───────────┘
                            │
        ┌───────────────────┼───────────────────────────────────────┐
        │                   │  THE SPINE: one vertical line. It      │
        │                   │  passes through every layer's          │
        │                   │  interconnect board (center cutout).   │
        │                   │  No branching.                         │
        │  ┌────────────────┼─────────────────┐                     │
        │  │ layer N:       │                 │                     │
        │  │  ┌─────────────┴───────┐   ┌─────┴─────────────┐       │
        │  │  │ interconnect board  │   │ node board        │       │
        │  │  │ (lxy repeater, HFR, │◄──┤ MAC ASIC + LPDDR6 │       │
        │  │  │  spine pass-thru)   │NoB│ gating ASIC +     │       │
        │  │  └─────────────────────┘   │ mgmt node header  │       │
        │  │                            └───────────────────┘       │
        │  └────────────────────────────────────────────────────┘   │
        │  layer N-1 … 1: identical boards down the same spine      │
        └───────────────────┼───────────────────────────────────────┘
                            │  (spine continues to the last layer)
```

### Implementation status

- `interconnect_board/` — generated schematic + circuit netlist (`gen_schematic.py`,
  5 components: Searay spine tap, LXY repeater, HFR pipe stage, two DF40 NoB
  connectors), board outline placeholder.
- `pnm_node/`, `processor/`, `gating_asic/` — project shells with populated
  local libraries (the symbols/packages/devices listed below); schematics and
  boards are empty placeholders awaiting placement and routing.

### Two management modes

Every board in the chassis is managed from one of two places, and the choice is
a board-level strapping, not a silicon variant.

**Mode A — the embedded management node.** Each node board carries a
mezzanine header (`PNM MGMT NODE HDR`) for an MCU or a Raspberry Pi Compute
Module. The module drives the board's gating ASIC directly over the gating
ASIC's management bus (`MGMT_*`), and it is a master of the node's NoB, so it
reaches the memory behind the node as well. It programs the gating weights
once during machine setup and then takes each token's routing decision locally:
the decision never leaves the board. The header carries a `MGMT_SEL` strap
that selects this manager.

**Mode B — the host.** The host owns the whole machine. The host's gating
programming is streamed over the fabric to the gating ASIC, whose fabric-side
receiver (`PROG_DATA`/`PROG_VALID`/`PROG_SOP`/`PROG_EOP`) decodes it into the
same register map the embedded node uses, and the decision is read back over
the fabric. This is the mode the host bridge at the spine root is built for.

The two modes are the same silicon. `HDL/core/gating_asic.v` exposes both
management paths on one register file (`mgmt_sel` picks the manager), and
`HDL/core/tb_gating_modes.v` programs the same weights and the same hidden
state through each path and requires the same top-K decision.

What changes between the modes is only what crosses the fabric. In mode A the
gating weights cross once, at setup; in mode B every weight byte crosses, and
so does every token's decision (256 bytes of logits, or 8 bytes for the top-K
identifiers, per token per layer).

All four projects open cleanly in LibrePCB (`librepcb-cli open-project`).

### Board descriptions

#### pnm_node — Compute node board

The core compute element. One DUV MAC ASIC socket (LGA-830, ~830 pins) paired
with **two** LPCAMM2/LPDDR6 sockets (644 pins each), connected via
point-to-point fabric links through a mezzanine connector to the interconnect
board above.

Each LPCAMM2 socket holds a 64 GB 192-bit LPDDR6 module; the pair gives the
node 128 GB across a **384-bit dual-module** memory bus (~512 GB/s), which is
the reference packaging. Total chassis capacity is unchanged at 64 TB (512
nodes x 128 GB) — the module count, not the capacity, is what doubles the
node-local bandwidth (Sections 2.4/2.16 of the paper). Both sockets escape to
the same ASIC, whose memory controller drives both 192-bit PHYs.

Per-node power: ~15 W total (9 W MAC, 5 W DRAM, 1 W fabric) on three rails
(core 0.8 V, I/O 1.2 V, LPDDR6 PHY 1.1 V).

**4-layer stackup**: top copper → inner1 (GND) → inner2 (power) → bottom copper.

#### processor board (was "orchestrator_sbc") — the host bridge board

The board at the spine root. It carries the PNM router bridge die and connects
the host to the fabric (spine cable). **The bridge has no processor of its
own**: the host runs the boot sequence, the weight upload and the dispatch
loop, so the same silicon serves a Raspberry Pi, a microcontroller, or a
workstation. Two host attach options (one active at a time, selected by a
solder jumper):

| Host attach | Interface | Use case |
|-----------|-----------|----------|
| **Pi Bridge** (`pi_bridge.v`) | SPI slave (SCLK/MOSI/MISO/CS) | CM0-CM4 host access via Python/Go/Rust/C drivers |
| **PCIe** (`PNM PCIE`) | PCIe Gen5 x16 | A workstation or server host, byte-stream flits in and out |

Both attach paths reach the same PNM register window at `0xF000_0000`: the
route table, the MoE map, the flit-builder command registers (destination,
length, payload byte, trigger), the status and counter registers, and the
extracted result bytes. The host-side firmware (`fw/pnm_fw.c`, the C port of
the Go reference in `sim/internal/pnm/firmware.go`) is unchanged between them.

The board also carries an M.2 M-Key NVMe slot for weight persistence and KV
spill; NVMe is storage, not compute, and the bridge never boots from it.

**Boot**: there is no boot ROM and no boot stub. The host boots the machine:
it POSTs the fabric, discovers the topology, loads the routing tables, uploads
the weights, and starts the dispatch loop. A bridge that had to boot itself
would need a processor, a ROM, a timer and a console — the four blocks this
design deliberately removed (Section 2.17 of the paper).

**Memory map** (as seen by the host):

| Region | Address Range | Size | Description |
|--------|--------------|------|-------------|
| SRAM | `0x8000_0000` | 64KB | On-chip SRAM (route table, MoE map, staging) |
| PCIe | `0xC000_0000` | 256MB | PCIe config/status registers |
| NVMe | `0xD000_0000` | 64B | NVMe controller (weights + KV spill) |
| PNM | `0xF000_0000` | 64B | PNM router engine |

**NVMe** provides block storage for:
- Model weight persistence (survives power cycles)
- KV cache overflow to swap
- General block I/O for NOMMU Linux userland
(The earlier Lustre FS striping backend is quarantined under `archive/`.)

**6-layer stackup** (board.lp declares `inner 4`): top copper → four inner GND/power planes → bottom copper.

#### gating_asic — MoE gating network board

Optional board for Mixture-of-Experts expert routing, mounted beside the
processor board at the spine root (chassis-wide, not one per layer). The gating
network can have ~1 GB of weights (gating matrices scale with expert count),
so this board includes DRAM for weight storage. Two options (footprints
overlap, populate one):

| Option | Package | Capacity | Bandwidth | Notes |
|--------|---------|----------|-----------|-------|
| **LPCAMM2** (default) | 644-ball CAMM2 | 16GB+ | 256 GB/s | Same single-module LPCAMM2 BOM as one pnm_node socket |
| **Soldered LPDDR5** | BGA-200 | 4-8GB | 50 GB/s | Lower cost, no socket |

The gating ASIC runs the moe_gating top-K unit (hidden × router_weights
projection plus top-K selection) once per token---the design bottleneck for MoE
routing---so DRAM bandwidth directly impacts expert selection latency. A BF16
MAC array dimension is provisioned as a parameter; the co-simulated RTL realizes
the gating unit itself, not a separate systolic-array instance.

The board also carries the `PNM MGMT NODE HDR` mezzanine: the header for the
embedded management node (an MCU or a Raspberry Pi Compute Module) that
programs this gating ASIC and reaches its memory. With the header populated
the board runs in mode A (the embedded node manages the gating ASIC locally);
with it empty and the `MGMT_SEL` strap open the board runs in mode B (the host
manages it over the fabric). See "Two management modes" above.

**Power**: ~8W (3W logic + 5W DRAM).

#### interconnect_board — Spine fabric

One per board layer. Contains LXY repeaters and HFRs that form the routing
fabric. The board has a **center cutout** for the spine cable to pass through,
with mezzanine connectors on both sides of the cutout.

```
  ┌─────────────────────────────────────────────┐
  │  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐      │
  │  │J2│  │U1│  │U2│  │U3│  │U4│  │J3│      │  ← NoB connectors (to pnm_nodes)
  │  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘      │
  │         ┌──┐   ┌───────────┐   ┌──┐        │
  │         │U5│   │  SPINE    │   │U6│        │  ← LXY repeaters flanking spine
  │         └──┘   │  CABLE    │   └──┘        │
  │         ┌──┐   │ PASS-THRU │   ┌──┐        │
  │         │U7│   │  (center  │   │U8│        │  ← HFR pipe stages
  │         └──┘   │  cutout)  │   └──┘        │
  │                └───────────┘                │
  │  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐      │
  │  │J4│  │J5│  │J6│  │J7│  │J8│  │J9│      │  ← Mezzanine connectors (to pnm_nodes)
  │  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘      │
  └─────────────────────────────────────────────┘
            ↑ spine cable enters/exits here
```

The spine cable is a shielded cable harness with Samtec SEARAY 12G pass-through
connectors (60-pin, 1.27mm pitch). Each SEARAY tap carries one byte-wide fabric
lane (8 data + valid/sop/eop/ready + 2 VC bits and power); the paper's
≈2 TB/s spine aggregate (Section 2.1) is provisioned as 128 parallel
16 GB/s lanes spanning the whole chassis, not as a single connector pair. Each
board taps into the spine via the LXY repeater's `spin_in`/`spin_out` port pair
— one upstream connector, one downstream. Traffic not destined for this layer
passes straight through. The SEARAY pass-through design allows boards to be
added or removed without desoldering the cable harness. The board has a center
cutout (15mm x 150mm) for the spine cable to pass through, with SEARAY
connectors flanking the cutout on both sides.

**6-layer stackup** (board.lp declares `inner 4`): top copper → four inner GND/power planes → bottom copper.

### Project layout

```
pcb/
├── README.md                  this file
├── pnm_node/                  compute-node board (MAC ASIC + LPCAMM2 socket)
│   ├── pnm_node.lpp           LibrePCB project
│   ├── library/               MAC ASIC (LGA-830), LPCAMM2 (644-ball)
│   ├── schematics/            schematic sheets
│   └── boards/                4-layer board layout
├── processor/                 host bridge board (was orchestrator_sbc)
│   ├── processor.lpp          LibrePCB project
│   ├── library/               Pi Bridge, MCU header, PCIe x16 edge, M.2 NVMe
│   ├── schematics/            schematic sheets
│   └── boards/                6-layer board layout
├── gating_asic/              MoE gating ASIC board (BF16 MAC) + LPCAMM2/LPDDR5
│   ├── gating_asic.lpp       LibrePCB project
│   ├── library/               Gating ASIC, mgmt-node mezzanine, LPCAMM2, LPDDR5 BGA
│   ├── schematics/            schematic sheets
│   └── boards/                4-layer board layout
└── interconnect_board/        spine fabric (LXY repeaters + HFRs + spine pass-through)
    ├── interconnect_board.lpp LibrePCB project
    ├── library/               LXY Repeater, HFR, NoB connector, Spine pass-through
    ├── schematics/            schematic sheets
    ├── gen_topology.py         parameterized topology generator
    ├── gen_schematic.py        schematic netlist generator
    └── boards/                6-layer board layout
```

### Local library — PNM-specific components

Each project ships its own project-local library. Current inventory (device
names as they appear in `library/dev/`):

| Project | Device | Package | Description |
|---------|--------|---------|-------------|
| `pnm_node` | PNM-MAC-ASIC | `LGA-830 MAC ASIC` | DUV MAC compute ASIC socket, ~830 pins |
| `pnm_node` | PNM-LPCAMM2 | `LPCAMM2-644` | LPCAMM2/LPDDR6 CAMM2 socket, 644-ball; 2 per node (64 GB 192-bit modules, 384-bit dual-module bus) |
| `processor` | PNM-SOC | `Router SoC BGA-400` | Custom RISC-V SoC, 17x17 mm BGA-400 |
| `processor` | PNM-PCIE | `PCIe x16 Edge` | PCIe Gen5 x16 edge connector |
| `processor` | PNM-NVME | `M.2 M-Key` | M.2 Key-M NVMe module slot |
| `processor` | PNM-PI-BRIDGE | `PinHeader_2x6` | SPI slave header for Pi CM0-CM4 |
| `processor` | PNM-MCU-HEADER | `PinHeader_2x10` | UART+GPIO header for ESP32/Pico/Arduino |
| `processor` | PNM-SPDT-JUMPER | `SOT-23_SolderJumper` | Processor-select solder jumper |
| `gating_asic` | PNM-GATE-ASIC | `QFN-48 Gating ASIC` | MoE gating ASIC (moe_gating top-K unit) |
| `gating_asic` | PNM-MGMT-NODE-HDR | `PinHeader_2x10` | Mezzanine for the embedded management node (MCU / CM4) that manages the gating ASIC and the memory behind it |
| `gating_asic` | — (packages only) | `LPCAMM2_Socket`, `LPDDR5_BGA_Soldered` | DRAM option footprints (no device entry yet) |
| `interconnect_board` | Samtec-Searay-60 | `Searay-60 Spine Mezzanine` | Spine tap, SEARAY 12G 60-pin |
| `interconnect_board` | PNM-SPINE-MEZZ | `Searay-60 Spine Pass-Through` | Spine cable pass-through, SEARAY 12G 60-pin |
| `interconnect_board` | Hirose-DF40-40 | `DF40-40 NoB Connector` | NoB board-to-board connector to pnm_node |

The fabric symbols (`LXY Repeater`, `HFR`, `Spine Mezzanine`, `NoB Connector`,
`Spine SEARAY Pass-Through`) live as components in
`interconnect_board/library/cmp/`.

### Assembly variable: board count

The chassis supports 1-15 board layers (the routing bitmap's 4-bit Layer ID
field; see the paper's Section 4.4). The reference configuration is
**8 layers × 64 nodes = 512 compute nodes**.

Board count is a build-time parameter. The shipped interconnect board
schematic is regenerated with `gen_schematic.py` (single fixed variant);
`gen_topology.py` explores parameterized placement layouts (its emitted
circuit carries nets only — component instances must be completed in
LibrePCB):

```bash
# Regenerate the committed interconnect board (in place)
python3 gen_schematic.py

# Parameterized layout exploration (output only)
python3 gen_topology.py --variant x2_lxy --layers 8 --board-x 4 --board-y 4 --output /tmp/board
```

The Go co-simulation mirrors this:

```bash
go run ./cmd/pnm -l 8 -x 8 -y 8       # reference: 512 nodes
go run ./cmd/pnm -l 2 -x 2 -y 2       # small: 8 nodes
go run ./cmd/pnm -l 16 -x 8 -y 8      # large: 1024 nodes
```

### Spine cable

The spine is a shielded cable harness that passes through the center cutout
of each interconnect board. Each board taps into the spine via two Samtec
SEARAY 12G connectors (60-pin, 1.27mm pitch; each tap carries one byte-wide
fabric lane — the ≈2 TB/s aggregate spine of the paper's Section 2.1
spans 128 parallel such lanes chassis-wide):

- **Upstream** (toward processor): carries `spin_in_data/valid/sop/eop/ready/vc`
- **Downstream** (toward bottom): carries `spin_out_data/valid/sop/eop/ready/vc`

The cable uses SEARAY pass-through connectors so each board can be
added or removed without desoldering. The processor board sits at the top
of the stack and injects/ejects flits from the spine.

### Processor board: MCU selector

The processor board has two host-attach footprints. A solder jumper selects
which one drives the PNM bus:

| Jumper | Position | Active host attach | Interface |
|--------|----------|-----------------|-----------|
| JP1 | 1-2 | Pi Bridge | SPI (SCLK/MOSI/MISO/CS) |
| JP1 | 2-3 | PCIe | PCIe Gen5 x16 |
| JP2 | 1-2 | MCU header | UART (TX/RX) + GPIO |
| JP2 | 2-3 | (reserved) | — |

Only one host attach can be active at a time. The PNM register window is
the same regardless of which one is selected, and the host-side firmware is
the same source in every case.

### Integration with HDL/

LibrePCB handles the physical board; the HDL sources handle the logic.
The connection between them is the register map documented in:
- `HDL/pnm_host_bridge.v` — the router bridge: memory map (SRAM, PCIe, NVMe,
  PNM windows) and the host bus
- `HDL/pi_bridge.v` — SPI bridge register protocol (for Pi Bridge / CM0–CM4)
- `HDL/core/pe_tile_stub.v` — MAC ASIC port list (symbol pin definitions)
- `HDL/core/gating_asic.v` — the gating ASIC's management bus (`MGMT_*`) and
  its fabric-side programming port (`PROG_*`)

### LibrePCB setup

```bash
# install (flatpak recommended on Linux)
flatpak install org.librepcb.LibrePCB

# or from source
git clone https://github.com/LibrePCB/LibrePCB.git
cd LibrePCB && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)
```

#### Workflow

1. Open LibrePCB, File → Open Project → `pcb/pnm_node/pnm_node.lpp`.
2. The project opens with an empty schematic and a 4-layer board.
3. Add components from the local library (`library/`) or standard passives.
4. Place footprints on the board; route DDR escape and fabric links.
5. Run DRC; export Gerber + drill + BOM via File → Output → Manufacturing.

---

## 10. Board assembly

This directory turns the repository's module library into *products*: JSON
assembly schemas (`schema.md`) describe a PCB — which silicon sits where,
which traces join them, how clock gating and reset synchronization are
wired — and `build_asm.py` elaborates that description into a complete,
simulable Verilog assembly using only modules already verified under
`HDL/`.

```
implementations/
├── README.md          this file
├── schema.md          the pnm-assembly/v1 format specification
├── build_asm.py       schema → validated wrapper + testbench + iverilog/vvp run
├── boards/*.json      example assemblies
└── build/             generated artifacts (gitignored)
```

### Quick start

```bash
# elaborate, compile, and smoke-run a board (exit 0 = assembly is sound)
python3 implementations/build_asm.py implementations/boards/node_board.json

# static check only (verilator --lint-only on the generated top)
python3 implementations/build_asm.py implementations/boards/node_board.json --lint

# emit wrapper + testbench without running iverilog (schema + port validation only)
python3 implementations/build_asm.py implementations/boards/node_board.json --no-sim

# keep a VCD waveform next to the artifacts
python3 implementations/build_asm.py implementations/boards/node_board.json --waves

# custom output directory
python3 implementations/build_asm.py <schema.json> -o /tmp/myboard
```

### What the builder guarantees

Every connection in an assembly is checked before a line of Verilog is
emitted:

- **existence** — endpoint ports are matched against ANSI port lists parsed
  from the actual `HDL/*.v` sources, so a renamed port fails loudly;
- **direction** — component outputs / external inputs drive; component
  inputs / external outputs load; anything else is rejected;
- **width** — parameter-aware: `[WIDTH-1:0]` with `{"WIDTH": 8}` evaluates
  to 8 bits and mismatches fail;
- **single driver** — no load port may be connected twice or both tied and
  driven.

Dangling component inputs produce warnings naming each one. The generated
testbench runs the assembly for `run_cycles` after reset release and prints
a PASS banner; any elaboration or runtime fault exits nonzero.

### Modeling PCBs

Copper is modeled with the same modules the paper's §2.18 profiles use —
traces are components, not special cases:

| Trace population | Component | Profile |
|------------------|-----------|---------|
| Motherboard P2P (~40 mm) | `pcb_link` | `DELAY_NS=40` |
| CAMM2 socket escape (~20 mm) | `pcb_link` | `DELAY_NS=20` |
| Spine mezzanine (~5 mm) | `pcb_link` | `DELAY_NS=5`, `WIDTH=128` |
| Electrical channel w/ SI | `pcb_si_link` | loss/crosstalk/jitter model |
| Inter-chassis fiber | `optical_link` | async CDC + propagation |

See `boards/node_board.json` for a complete worked example: two timed
traces around a MAC stub whose clock passes through a `clk_gate` cell and
whose reset crosses domains through `rst_sync` — i.e., the DFT discipline
of Paper §4.6 expressed as ordinary wiring.

### Node compute variants

`HDL/core/node.v` is the compute node of the node network (one MoE expert
pass). Its `CU_TYPE` parameter selects the embedded numeric ASIC behind a
shared accumulate interface and FSM, so the same node source builds as
different products:

| Board | `CU_TYPE` / `WIDTH` | Engine |
|-------|---------------------|--------|
| `boards/node_bf16.json` | 0 / 16 | BF16 expert (gate/up → swiglu → down) |
| `boards/node_fp32.json` | 2 / 32 | FP32 MAC (identity activation) |
| `boards/node_int8.json` | 4 / 8 | INT8 MAC, INT32 accumulate |
| `boards/node_ternary.json` | 8 / 8 | BitNet b1.58 ternary {-1,0,+1} x INT8 MAC |
| `boards/node_fp4.json`  | 6 / 8 | FP4 (E2M1) MAC, INT32 accumulate |
| `boards/node_dual_mem.json` | 0 / 16 | Reference node: BF16 expert + dual-module memory (`node_mem.v`, CHANNELS=2 = 2 x 64 GB 192-bit LPCAMM2, 384-bit, ~512 GB/s) |

Each instantiates `rst_sync` + `clk_gate` + `node` and builds/lints/sims
clean. The BF16 (`CU_TYPE 0`) and INT8 (`CU_TYPE 4`) expert passes are
bit-exact validated by `HDL/core/node_reference_test.py` (see `--cu`); the
other formats are validated by their unit testbenches.

### Adding an assembly

1. Copy `boards/node_board.json` and change `name`.
2. List components (any non-testbench module in `HDL/` participates) with
   their parameter overrides.
3. Connect endpoints; consult warnings for dangling inputs.
4. Run the builder; iterate until exit 0.
5. Commit the schema — it regenerates deterministically from sources.

---

## 11. Board assembly schema

The assembly schema composes verified modules from `HDL/` into a complete,
simulable assembly: a PCB model with chips, traces, clock gating, reset
synchronization, and external connectors. It is the RTL analogue of a board
netlist — components are silicon, connections are copper, and traces carry
the paper's §2.18 electrical profiles.

### File format

One JSON file per assembly. See `boards/*.json` for working examples.

```json
{
  "schema":   "pnm-assembly/v1",
  "name":     "node_board",
  "description": "One compute node: ingress trace, MAC stub, egress trace",
  "clock":    { "period_ns": 10 },
  "reset_cycles": 4,
  "run_cycles": 2000,

  "external": [
    { "name": "clk",       "dir": "input",  "width": 1 },
    { "name": "in_tdata",  "dir": "input",  "width": 8 },
    { "name": "out_tdata", "dir": "output", "width": 8 }
  ],

  "components": [
    { "instance": "u_in_trace", "module": "pcb_link",
      "params": { "WIDTH": 8, "DELAY_NS": 40 } }
  ],

  "connections": [
    { "from": "ext.clk", "to": ["u_in_trace.clk"] },
    { "from": "u_in_trace.rx_data", "to": ["ext.out_tdata"] }
  ],

  "tieoffs": [
    { "to": "u_pe.routing_bitmap", "value": "11'h080" }
  ]
}
```

### Sections

#### `schema`, `name`, `description`
Identity. `schema` must be exactly `pnm-assembly/v1`; the builder rejects
other versions rather than guessing.

#### `clock.period_ns`, `reset_cycles`, `run_cycles`
Simulation envelope emitted into the generated testbench: clock half-period
is `period_ns/2` ns, `rst_n` is held low for `reset_cycles` rising edges, and
the simulation ends after `run_cycles` cycles with a PASS banner.

#### `external[]`
Top-level ports of the generated wrapper. Each entry: `name` (Verilog
identifier), `dir` (`input`|`output`), `width` (bits). External inputs drive
internal loads; internal drivers feed external outputs. Referenced from
connections as `ext.<name>`.

#### `components[]`
Silicon instances. Each entry:
- `instance`: unique Verilog identifier for the instantiation.
- `module`: a module defined somewhere under `HDL/`. The builder scans all
  `HDL/*.v` files, parses ANSI port lists and parameters, and resolves the
  module to its source file automatically.
- `params` (optional): synthesis-time overrides. Values may be numbers
  (`40`) or raw Verilog literals (`"8'h07"`). Numeric params are also used
  to evaluate parameterized port widths (`[WIDTH-1:0]` with `WIDTH=8`).

Traces are components too: `pcb_link`, `pcb_si_link`, `optical_link`, and
`pcb_triple_link` are the copper/fiber between chips. A `pcb_link` with
`DELAY_NS=40, WIDTH=8` *is* the 40 mm motherboard profile of Paper §2.18.

#### `connections[]`
Point-to-point nets. `from` is a single driver endpoint
(`<instance>.<port>` or `ext.<name>`); `to` is a list of load endpoints.
The builder enforces:
- endpoints exist (port names checked against parsed modules),
- direction legality (component output / external input drives;
  component input / external output loads),
- width equality (parameter-aware),
- one driver per load port.

Unconnected component inputs are reported as warnings so dangling brings-up
surface early; unconnected outputs are legal and left floating.

#### `tieoffs[]`
Constant drivers for configuration inputs: `{ "to": "<inst>.<port>",
"value": "<verilog literal>" }`. A tieoff and a connection targeting the
same port is rejected.

### Generated artifacts

`build_asm.py boards/<x>.json` writes into `implementations/build/<x>/`:

| Artifact | Contents |
|----------|----------|
| `<x>_top.v` | Wrapper: external ports, wires, tieoffs, instances |
| `tb_<x>.v` | Clock/reset generator, idle-run testbench with PASS banner |
| `filelist.f` | Source files (+ `-I` include dir) for iverilog/verilator |
| `<x>_top.out` | Compiled simulation binary |

Exit code 0 means: schema valid, all endpoints resolved, compile clean,
simulation ran to completion. The same filelist feeds
`verilator --lint-only` via `--lint`.

### Conventions honored

The schema assumes the repository's link convention
(`*_data/_valid/_sop/_eop/_ready` groups, `clk`/`rst_n` first), but nothing
is hard-coded: any module with parseable ANSI ports participates, including
the DFT primitives (`rst_sync.v`, `clk_gate.v`) — gate a domain by
instantiating `clk_gate` and driving downstream `clk` ports from its `gclk`;
 synchronize resets with `rst_sync` chains.

---

## 12. Raspberry Pi host drivers

Host-side tooling for talking to a PNM chassis through the SPI-to-PNM bridge
(`HDL/pi_bridge.v`). The same 48-bit frame protocol and register API is
implemented four times so any Pi image can drive the chassis, plus a separate
PCIe driver for CM5-class modules:

| File | Language | Deps | Transport | Target |
|------|----------|------|-----------|--------|
| `pnm_pi.py` | Python 3 | `spidev` | GPIO SPI | CM0/CM1/CM3/CM4 |
| `pnm_pi.go` | Go (stdlib only) | none | raw spidev ioctl | CM0/CM1/CM3/CM4 |
| `pnm_pi.rs` | Rust (no crates) | none | raw spidev ioctl | CM0/CM1/CM3/CM4 |
| `pnm_pi_spi.c` | C (no deps) | libc only | raw spidev ioctl | CM0/CM1/CM3/CM4 |
| `pnm_pi_cm5.c` + `pnm_pi.h` | C | libc only | PCIe BAR0 mmap | CM5 |

All five share identical semantics: `reg_read` / `reg_write` / `boot_done` /
`dispatch_count` / `inject`.

### Wiring (GPIO SPI path)

Bridge side signals map to the Pi's SPI0 header as follows (physical pins for
the 40-pin connector):

| Pi signal | Pin | Bridge pin |
|-----------|-----|------------|
| MOSI (GPIO10) | 19 | `mosi` |
| MISO (GPIO9)  | 21 | `miso` |
| SCLK (GPIO11) | 23 | `sclk` |
| CE0 (GPIO8)   | 24 | `cs_n` |
| 3V3           | 1  | logic supply rail |
| GND           | 6  | ground |

Enable the SPI overlay (`dtparam=spi=on`) so `/dev/spidev0.0` exists.
SPI mode 0; keep `--speed` at or below what the FPGA-side system clock can
settle (bridge needs roughly 10x the SCLK rate internally).

### Frame format

48 bits per frame, MSB first, full duplex:

```
byte 0   : header { rw(1b) << 7 | sel[6:0] }    rw=1 read, rw=0 write
bytes 1-4: 32-bit data field, MSB first
           write: value shifted in on MOSI
           read : register value returned on MISO
byte 5   : status byte returned by the bridge
           0x01 = write acknowledged, 0x00 = read ok
```

Register selectors (match the router-chip PNM window):

```
sel 0=CTRL 0x00  1=LAYER 0x04  2=MODULE 0x08   3=LEN 0x0C   4=DATA 0x10
sel 5=STATUS 0x14  6=RESULT 0x18  7=ERRORS 0x1C  8=DISPATCHES 0x20
sel 9=WEIGHT_FLITS 0x24
```

CTRL bits: bit 0 = INJECT (send the staged flit), bit 2 = BOOTDONE.

### Usage

Python:

```python
from pnm_pi import PNMPi, SEL_LAYER

with PNMPi(0, 0, 10_000_000) as pnm:
    pnm.reg_write(SEL_LAYER, 1)
    print(pnm.reg_read(SEL_LAYER))
    pnm.inject(layer=1, module=5, payload=b"\xaa\x55")
    pnm.boot_done()
```

Go:

```bash
go build -o pnm_pi_go pnm_pi.go        # or GOOS=linux GOARCH=arm64 go build ...
./pnm_pi_go -bus 0 -dev 0 -speed 10000000
```

Rust:

```bash
rustc -O --edition 2021 pnm_pi.rs -o pnm_pi_rs
./pnm_pi_rs --bus 0 --dev 0 --speed 10000000
```

C (SPI):

```bash
make demo CROSS=aarch64-linux-gnu-     # builds pnm_pi_spi_demo + pnm_pi_demo
./pnm_pi_spi_demo 0 0 10000000         # bus dev speed
```

C (CM5 PCIe): the PNM endpoint enumerates on the CM5's FPC Gen3 link; BAR0 is
the router register window. No kernel module needed:

```bash
./pnm_pi_demo /sys/bus/pci/devices/0001:01:00.0
```

Each CLI binary runs the same smoke test: write `0xDEADBEEF` to LAYER, read it
back, report the dispatch counter.

---

## 13. Archived components

Code that is no longer part of the active build, test, or documentation path.
Kept for provenance and possible later revival. Nothing under this tree is
compiled, tested, or documented as current.

| Path | What it was | Why it left the active tree |
|------|-------------|------------------------------|
| `fw/pnm_lustre.{c,h}` | C Lustre OSS striping client | Unrelated to the processing-near-memory argument (a filesystem striping feature); no runtime callers. The Go twin is under `sim/` in `archive/`. |
| `sim/nvme_lustre.{go,_test.go}` | Go Lustre client twin + alias/spacing tests | Same feature; the in-package half that the KV-cache overflow path actually needs (the `NVMeDev` block device) now lives in `sim/internal/pnm/nvme_device.go`. |
| `toolchain/soc-linux/` | Full OS image builder (Redox-path) | Superseded by the seL4 microkernel story in `fw/os/sel4/`/`toolchain/soc/`; orphaned (no build or doc references to the actual stack). |
| `hdl/tb_expert_loop.v` | Monolithic integrated expert loop testbench (1361 lines) | Superseded by `HDL/core/node.v` + `tb_node.v` + `node_reference_test.py`; no build/test path ran it. |
| `hdl/tb_integration.v` | Early fabric integration TB | Superseded by `tb_fabric.v` / `tb_load.v`; referenced by nothing. |
| `hdl/tb_rv32_core.v`, `hdl/tb_rv32_core_load.v` | RV32 core + load TBs | Historical bring-up scaffolding; only `AGENTS.md` prose mentioned them. |
| `hdl/tb_flit_gate.v`, `hdl/tb_hfr.v` | Per-cell fabric TBs | Superseded by the combined `tb_fabric.v`. |
| `hdl/core/tb_int4_mac.v` | Standalone INT4 MAC TB | `pnmt` exercises `tb_int4_mac_array.v` (arrays), not this scalar TB. |
| `hdl/orchestrator_chip_haskell.v` | "Haskell-optimized Router Chip" variant | Dead ceremony: no instantiation and no compiler emits it (the Haskell frontend targets generic FP64 IR). |
| `hdl/core/ram_phy_stub.v` | RAM PHY stub | Only consumed by the archived `tb_expert_loop.v`; no live instantiation. |
| `hdl/gen_orchestrator.py` | Generator for the four `orchestrator_*.v` SoC tiers (CPU + boot ROM + UART + CLINT) | The tiers were deleted when the router chip became the CPU-less host bridge (`HDL/pnm_host_bridge.v`); the generator reads its sources from `git show HEAD:HDL/<file>`, so it can no longer regenerate them. |

Relevant constraints honoured during the move: `kv_cache.go` depends on
`NVMeDev` (`KVCache.NVMe`), which stays in the package; the C firmware build
(`fw/`) does not reference `pnm_lustre.*`; `pnmt`'s `c` category no longer
compiles the Lustre twin.
