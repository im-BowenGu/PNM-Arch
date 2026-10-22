# Breaking the HBM wall

> Replace HBM with commodity 192-bit LPDDR6 CAMM2 (~$16/GB, ~24× cheaper per
> byte) paired with mature-node DUV MAC ASICs on a deterministic single-spine
> wormhole fabric — 512 nodes, 64 TB, ~262 TB/s, no runtime scheduling, no
> cache coherency, and a hardware doorbell that fires on byte count, CRC, and
> destination match.

**TL;DR:** [TLDR.md](TLDR.md) · **Architecture:** [docs/architecture.md](docs/architecture.md) · **Manual:** [docs/usage_manual.md](docs/usage_manual.md)

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

## The architecture

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
docs/                     usage manual, architecture summary, profiling guide
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

## Links

| | |
|---|---|
| [TL;DR](TLDR.md) | the numbers, in one page |
| [paper/readme.md](paper/readme.md) | building the paper, verifying the fabric proofs |
| [paper/TLDR_Paper.md](paper/TLDR_Paper.md) | the architecture brief |
| [paper/submission/arxiv/](paper/submission/arxiv/) | abstract + self-contained arXiv source |
| [docs/architecture.md](docs/architecture.md) | the architecture in one screen |
| [docs/usage_manual.md](docs/usage_manual.md) | every command, option, and workload (including `pnmgate`, the hardware-gated inference) |
| [docs/profiling.md](docs/profiling.md) | latency model and profiling |
| [docs/real_weights.md](docs/real_weights.md) | HF-parity results on the real checkpoint |
| [HDL/README.md](HDL/README.md) | the RTL, the wire format, the compute units |
| [pcb/README.md](pcb/README.md) | board architecture and wiring |
| [implementations/README.md](implementations/README.md) | the board-assembly schema |

## License

Three-way split, see [LICENSE](LICENSE):

| Scope | License |
|-------|---------|
| `paper/` (manuscript, build pipeline, submission) | CC BY-SA 4.0 |
| `HDL/`, `pcb/` (Verilog RTL, PCB designs) | CERN-OHL-S v2 |
| Everything else (`sim/`, `fw/`, `docs/`, toolchains) | AGPL-3.0-or-later |
