# Breaking the HBM wall

> Replace HBM with commodity 192-bit LPDDR6 CAMM2 (~$16/GB, ~24× cheaper per
> byte) paired with mature-node DUV MAC ASICs on a deterministic single-spine
> wormhole fabric — 512 nodes, 64 TB, ~262 TB/s, no runtime scheduling, no
> cache coherency, and a hardware doorbell that fires on byte count, CRC, and
> destination match.

## TL;DR

**The problem.** GPU/HBM monoliths cost ~$375/GB (H100-class), are
capacity-capped by interposer reticle limits, and spend most energy on data
movement rather than compute.

**The solution.** A distributed spatial Processing-Near-Memory architecture
that replaces HBM with commodity LPDDR6 CAMM2 modules, each paired with a
mature-node (14/28 nm) DUV MAC ASIC on a rigid X/Y motherboard grid.

**Key numbers** (512-node reference chassis):

| Metric | Value |
|--------|-------|
| Nodes | 512 (8 layers × 8×8 grid) |
| Aggregate memory | 64 TB |
| Aggregate bandwidth | ~262 TB/s (512 nodes × ~512 GB/s node-local, 2×64 GB modules) |
| FP64 throughput | ~197 TFLOPS |
| Cost per GB | ~$16 (vs ~$375 for HBM) |
| Chassis power | 8–10 kW |
| Spine bandwidth | ~2 TB/s per direction |

**How it works.**

1. **Four kinds of hardware:** DRAM modules, MAC ASICs, stateless flit
   repeaters, and one CPU-less router bridge the host drives.
2. **Deterministic routing:** a single-spine tree with dimension-order
   on-board paths; routing is O(1) coordinate arithmetic on the
   `[Layer ID | Module ID]` header. No runtime scheduling, no cache coherency.
3. **Doorbell activation:** hardware three-condition fire (byte count, CRC,
   destination match) — sub-microsecond, with no software interrupt.
4. **AOT compilation:** a five-stage compiler maps HuggingFace models onto the
   physical chassis; the output is a static dataflow graph where the address
   *is* the coordinate and the doorbell *is* the program counter.
5. **MoE inference:** expert weights stay resident in the DRAM pools; only
   tokens travel, via wormhole routing (~270 dispatches per token).

**Target workloads:** MoE transformer inference, FP64 stencil computation for
scientific HPC, and large-scale numerical simulation.

**What is machine-checked.** All transport claims are machine-checked by the
co-simulation harness against a cycle-exact Verilog model. Six scenarios
(`sweep`, `vcsweep`, `load`, `hotspot`, `stress`, `replay`) verify byte-exact
delivery, zero drops, doorbell accounting, kernel correctness, and
deterministic replay. The compute node and the gating ASIC are bit-exact
against their software oracles, the gating→fabric→node composition is
bit-exact per layer, and the firmware's own bus trace is replayed against the
real gating ASIC. On the real **Gemma-4 26B-A4B** checkpoint the harness's
pure-Go BF16 forward pass is greedy-token-identical to a Hugging Face
reference on the tested chat prompts.

## The paper

***Breaking the HBM wall*** — a distributed spatial Processing-Near-Memory
architecture. The manuscript, its build pipeline, and the submission artifacts
are in [`paper/`](paper/); the abstract and a self-contained arXiv source
package are in [`paper/submission/arxiv/`](paper/submission/arxiv/).

Five contributions:

1. **An architecture specification** — the single-spine deterministic wormhole
   fabric with dimension-order on-board paths, the doorbell activation
   discipline, and the reference 512-node / 64 TB chassis, with closed-form
   latency and spine-sizing rules.
2. **An ahead-of-time compilation pipeline** that lowers HuggingFace
   safetensors models and typed source-language IRs onto physical coordinates,
   with capacity-aware expert placement and static dispatch schedules.
3. **A machine-checking methodology** — a cycle-exact co-simulation of the
   Verilog fabric whose five oracles check byte conservation, zero misroutes,
   doorbell accounting against an independent software twin, kernel results
   against a golden model, and exact closed-form latency.
4. **An explicit validation-scope discipline** — every bandwidth, power, and
   cost figure is labeled a projection; every machine-checked claim is
   enumerated.
5. **An open artifact** — the Verilog fabric, the compute-unit library, a
   CPU-less router bridge with a host link, matching Go and C firmware linked
   by a shared dispatch-plan wire format, the model compiler, PCB and
   assembly models, and a reproducible test suite.

## The architecture in 30 seconds

| | |
|---|---|
| **Problem** | GPU/HBM monoliths cost ~$375/GB (H100-class), are capacity-capped by interposer reticle limits, and spend most energy on data movement |
| **Solution** | Commodity 192-bit LPDDR6 CAMM2 + a mature-node DUV MAC ASIC per node, on a rigid X/Y grid |
| **Reference chassis** | 512 nodes (8 layers × 8×8) · 64 TB · ~262 TB/s aggregate · ~197 TFLOPS FP64 · 8–10 kW |
| **Hardware** | Four kinds: DRAM modules, MAC ASICs, stateless flit repeaters, one CPU-less router bridge the host drives |
| **Routing** | Source-routed wormhole, O(1) coordinate arithmetic, deterministic latency, no runtime scheduling |
| **Gate** | Hardware doorbell: three-condition fire — sub-microsecond activation, no software interrupt |

The router bridge has **no processor**: the host (a Raspberry Pi over the SPI
adapter, or any third-party microcontroller) runs the boot sequence, the
weight upload, and the dispatch loop.

## Repository layout

```
paper/                    the manuscript, build pipeline, submission + arXiv bundle
HDL/                      Verilog-2005 RTL: the fabric, the compute node, the
                          gating ASIC, the host bridge, memory models, testbenches
sim/                      Go co-simulation harness (stdlib only): model compiler,
                          inference client, source-language front ends, benchmarks
fw/                       C firmware: host-side dispatch, the plan codec, the
                          embedded management node
pcb/                      LibrePCB board designs (interconnect, host bridge,
                          gating ASIC, node)
implementations/          board netlist assembly (JSON schemas + build script)
toolchain/  pi_host/      MCU cross-build · Raspberry Pi host drivers
docs/pnm.md               the detailed documentation: architecture, paper, RTL,
                          harness, commands, boards, real weights
```

## Build and run

Requires [Nix](https://nixos.org) with flake support.

```bash
nix develop                                    # iverilog, go, pdflatex, pandoc
cd sim && go run ./cmd/pnmt                    # the whole test suite
cd sim && go run ./cmd/pnm                     # fabric co-simulation (48 nodes)
bash reproduce.sh                              # every step, end to end
python3 paper/build.py                         # the paper (docx, pdf, arXiv bundle)
```

Real checkpoint weights are optional: `./download_model.sh` fetches the gated
Gemma-4-26B-A4B checkpoint, and `reproduce.sh --real-weights` runs the
real-slice checks. Nothing in the default suite needs it.

## Documentation

| | |
|---|---|
| [docs/pnm.md](docs/pnm.md) | the detailed documentation: architecture, the paper and its build, the RTL, the harness, every command, the boards, real weights |
| [docs/pnm.md#2-the-architecture-in-brief](docs/pnm.md#2-the-architecture-in-brief) | the architecture brief |
| [docs/pnm.md#3-the-paper](docs/pnm.md#3-the-paper) | building the paper and verifying its fabric proofs |
| [paper/submission/arxiv/](paper/submission/arxiv/) | abstract + self-contained arXiv source |

## License

Three-way split, see [LICENSE](LICENSE):

| Scope | License |
|-------|---------|
| `paper/` (manuscript, build pipeline, submission) | CC BY-SA 4.0 |
| `HDL/`, `pcb/` (Verilog RTL, PCB designs) | CERN-OHL-S v2 |
| Everything else (`sim/`, `fw/`, `docs/`, toolchains) | AGPL-3.0-or-later |
