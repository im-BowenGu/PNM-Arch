# Breaking the HBM wall

> An open-source distributed spatial Processing-Near-Memory architecture built
> from commodity LPDDR6 CAMM2 modules, mature-node DUV MAC ASICs, and a
> deterministic single-spine wormhole routing fabric.

**Paper:** [*Breaking the HBM wall*](paper/readme.md) · [TL;DR](TLDR.md) · [Architecture brief](paper/TLDR_Paper.md)

## What this is

This repository is an open-source hardware project: a complete, manufacturable
design for a distributed PNM machine — from Verilog RTL through PCB assembly
to firmware and host drivers — built around the architecture described in the
paper.

The paper proves the routing fabric is lossless, deterministic, and correctly
gated by the doorbell mechanism. This repository contains everything needed to
build it: the HDL, the PCB designs, the co-simulation harness, the firmware,
and the host drivers.

## The architecture in 30 seconds

| | |
|---|---|
| **Problem** | GPU/HBM monoliths cost ~$375/GB (H100-class), are capacity-capped by interposer reticle limits, and spend most energy on data movement |
| **Solution** | Replace HBM with commodity 192-bit LPDDR6 CAMM2 (~$16/GB, ~24× cheaper per byte), each paired with a mature-node DUV MAC ASIC on a rigid X/Y grid |
| **Reference chassis** | 512 nodes (8 layers × 8×8 grid) · 64 TB · ~131 TB/s aggregate · ~197 TFLOPS FP64 |
| **Hardware** | Four kinds: DRAM modules, MAC ASICs, stateless flit repeaters, one RISC-V orchestrator chip |
| **Routing** | Source-routed wormhole, O(1) coordinate arithmetic, deterministic latency, no runtime scheduling |
| **Gate** | Hardware doorbell: three-condition fire (byte count, CRC, destination match) — sub-microsecond activation, no software interrupt |

## Repository layout

```
paper/                  ← The paper + its proofs
  Paper.MD                manuscript source (Markdown, LaTeX-escaped)
  TLDR_Paper.md           architecture brief
  build.py                build pipeline → submission/*.docx
  submission/             generated artifacts (DOCX, PDF, TeX)
  HDL/                    routing fabric RTL + verification testbenches

HDL/                    ← Full Verilog fabric (RTL + all compute units + SoC)
  core/                   compute primitives (FMA, ALU, MAC, systolic arrays)
  (plus all routing gates, orchestrator SoCs, memory models, PHYs, testbenches)

pcb/                    ← Manufacturable PCB assembly
  README.md               board architecture (spine, processor, gating, NVMe)
  interconnect_board/     spine pass-through (SEARAY 12G), LXY repeaters, mezzanines
  processor/              three processor options (Pi Bridge / MCU / Custom SoC)
  gating_asic/            MoE gating ASIC + DRAM (LPCAMM2 / LPDDR5)

sim/                    ← Go co-simulation harness (stdlib only)
  cmd/pnm/                orchestrator + verification scenarios
  cmd/pnmc/               program compiler + model compiler + driver CLI
  cmd/pnmhost/            unified host driver (all workloads)
  cmd/haskell_pnm/        Haskell → PNM compiler + co-simulation runner
  cmd/r_pnm/              R → PNM compiler + co-simulation runner
  cmd/hlsl_pnm/           HLSL → PNM compiler + co-simulation runner
  internal/pnm/           harness library (topology gen, doorbell, DES, RNG)
  examples/               test configs (gemma4_test_synthetic, mini_glm_moe)

fw/                       C firmware port for MCU targets
toolchain/                MCU, SoC, fw-linux, fw-sel4 toolchains
pi_host/                  Raspberry Pi Compute Module host drivers

implementations/        ← Board netlist assembly + schema
docs/                   ← Usage manual, profiling guide
```

## Getting started

Requires [Nix](https://nixos.org) with flake support (`nix develop`).

```bash
nix develop                  # enter environment (iverilog, go, pdflatex, pandoc)
```

| What you want | Where to go |
|---------------|-------------|
| Build the paper | [`paper/readme.md`](paper/readme.md) |
| Verify fabric proofs (paper) | [`paper/readme.md`](paper/readme.md#verifying-the-fabric-paper-proofs) |
| Run co-simulation | [Simulation](#simulation) below |
| Run HPC workloads | [Simulation → HPC workloads](#hpc-workloads) below |
| Build hardware | [Build system](#build-system) below |

## Simulation

The co-simulation harness compiles a Go stimulus program into Verilog
testbenches, runs them through `iverilog`/`vvp` in parallel slices, then
verifies byte-exact delivery against a golden model. Every scenario
checks all five properties the paper proves.

### Co-simulation (6 scenarios at any chassis scale)

```bash
cd sim
go run ./cmd/pnm                  # 3×4×4 = 48 nodes, all 6 scenarios
go run ./cmd/pnm -l 8 -x 8 -y 8  # 512-node reference chassis
```

Scenarios: `sweep` (exact closed-form latency), `vcsweep` (all VC classes),
`load` (500 flits, lossless), `hotspot` (MoE hot expert), `stress` (3%
corrupt CRC the doorbell must reject), `replay` (bit-identical determinism).

### Unified host driver (`pnmhost`)

A single entry point for all PNM workloads — scenarios, HPC benchmarks,
programs, model compilation, and LLM inference — with timestamped logging
and structured result export:

```bash
go run ./cmd/pnmhost/ scenario sweep load stress -output results/
go run ./cmd/pnmhost/ workload matvec -l 4 -x 4 -y 4 -frag 32
go run ./cmd/pnmhost/ program examples/bias_add.pnm
go run ./cmd/pnmhost/ model examples/gemma4_test_synthetic -o results/
go run ./cmd/pnmhost/ inference examples/gemma4_test_synthetic "Hello" -max-tokens 16
```

See [`docs/usage_manual.md`](docs/usage_manual.md#unified-host-driver)
for full command reference and all options.

### Source-language compilation

A subset of Haskell, R, and HLSL compiles to PNM dispatch instructions
on the chassis: Haskell and R through an FP64 IR, HLSL through an FP32
ALU IR that is lowered to the same `f64_*` kernels for dispatch.

```bash
cd sim
go run ./cmd/haskell_pnm examples/hello.hs -l 2 -x 2 -y 2 -run
go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2 -run
go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2 -run
```

Each operation (add, mul, fma, ...) maps to a node running an `f64_*`
kernel, with operands packed in the FP64 payload format in token
payloads. HLSL's internal IR targets the FP32 ALU and is lowered to
`f64_*` kernels for dispatch compatibility; Haskell and R compile
through the FP64 IR directly.
See [`docs/usage_manual.md`](docs/usage_manual.md#haskell-to-pnm-compilation)
for the full syntax reference and three-column comparison table.

### HPC workloads

Five built-in HPC benchmarks exercise different routing patterns:

| Workload | Routing pattern | Description |
|----------|----------------|-------------|
| `jacobi5` | Intra-layer X→Y dimension-order | 5-point Jacobi stencil, one grid point per node |
| `matvec` | Spine descent (cross-layer) | Matrix-vector product, row-per-node weight-stationary |
| `reduction` | Reverse-path merge (egress→Y→X→spine) | Merge tree collecting partial sums |
| `broadcast` | Spine descent + X→Y fan-out | Weight distribution from root to every node |
| `nbody` | All paths saturated (worst case) | O(N²) all-pairs interaction, limited to 64 nodes |

```bash
go run ./cmd/pnmc workload jacobi5 -l 1 -x 4 -y 4 -run
go run ./cmd/pnmc workload matvec -l 4 -x 4 -y 4 -frag 16 -run
go run ./cmd/pnmc workload reduction -l 4 -x 4 -y 4 -frag 32 -run
go run ./cmd/pnmc workload broadcast -l 4 -x 4 -y 4 -frag 64 -run
go run ./cmd/pnmc workload nbody -l 4 -x 2 -y 2 -frag 8 -run
```

Or via the unified driver:
```bash
go run ./cmd/pnmhost/ workload matvec -l 4 -x 4 -y 4 -frag 32
```

### Data output and logging

All simulation tools support structured output (CSV/JSON) and timestamped
logging. Add `--output <dir>` to any command:

```bash
go run ./cmd/pnm --output results/                              # scenario CSV/JSON
go run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -o results/   # dispatch CSV
go run ./cmd/pnmhost/ scenario sweep -output results/ -log results/run.log
```

See [`docs/usage_manual.md`](docs/usage_manual.md#data-output-and-logging)
for the full list of output files and their schemas.

### HDL testbenches

The paper-verification subset lives in [`paper/HDL/`](paper/HDL/).
The full test suite (30+ testbenches) lives in [`HDL/`](HDL/):

```bash
cd HDL
# See HDL/README.md for the full list
```

## Build system

The build pipeline turns Verilog modules into a complete, simulable board
assembly, and the PCB tools turn that into physical hardware.

### RTL assembly (`implementations/`)

JSON schemas describe a board: which silicon sits where, which traces join
them, how clock gating and reset synchronization are wired. The builder
validates every connection against the actual Verilog port lists, then emits
a wrapper, testbench, and filelist.

```bash
python3 implementations/build_asm.py implementations/boards/node_board.json
python3 implementations/build_asm.py implementations/boards/node_board.json --lint    # verilator only
python3 implementations/build_asm.py implementations/boards/node_board.json --no-sim  # emit only
```

See [`implementations/schema.md`](implementations/schema.md) for the
`pnm-assembly/v1` format and [`implementations/README.md`](implementations/README.md)
for the full reference.

### PCB design (`pcb/`)

Four boards, all LibrePCB (open-source EDA), 4-layer stackup:

| Board | What it is | Generator |
|-------|-----------|-----------|
| `interconnect_board` | Spine fabric: SEARAY 12G pass-through taps (one byte-wide lane each), LXY repeaters, HFR pipe stages | `gen_schematic.py` (fixed variant; `gen_topology.py` explores parameterized layouts) |
| `processor` | Management: Pi Bridge / MCU Header / Custom SoC (BGA-400) | manual placement |
| `gating_asic` | MoE gating + DRAM (LPCAMM2 socket or soldered LPDDR5) | manual placement |
| `pnm_node` | Compute node: MAC ASIC (LGA-830) + LPCAMM2 socket | manual placement |

```bash
python3 pcb/interconnect_board/gen_schematic.py
```

Open any `.lpp` in LibrePCB to place footprints, route, run DRC, and
export Gerber + drill + BOM. See [`pcb/README.md`](pcb/README.md) for
board architecture and wiring.

### Firmware

Four toolchains for the RISC-V orchestrator chip, from bare-metal to Linux:

| Toolchain | Target | ISA | Output |
|-----------|--------|-----|--------|
| `toolchain/mcu/` | Bare-metal MCU | RV32I | `firmware.bin` (8 KB ROM) |
| `toolchain/soc/` | NOMMU Linux daemon | RV32IMA | `pnm_socd` (static musl) |
| `toolchain/fw-linux/` | Linux tinyconfig | RV32I | `Image` + `initrd.cpio` (16 MB) |
| `toolchain/fw-sel4/` | seL4 microkernel | RV32IMA | root task ELF |

Build any toolchain with `make` in its directory. See
[`docs/usage_manual.md`](docs/usage_manual.md) for details.

### Boot sequence

```
Boot ROM (64 KB) → SPL (NVMe → DRAM) → kernel or seL4 → init → dispatch
```

The orchestrator chip boots, discovers the POST chain, loads routing tables
and MoE expert maps, then dispatches workloads to the fabric. On the SoC
variant, `pnm_socd` mmaps `/dev/pnm` and runs the dispatch loop from
userspace.

## Manufacturable design

Everything outside `paper/` is the production design:

| Directory | What it contains | License |
|-----------|-----------------|---------|
| `HDL/` | Full Verilog-2005 fabric: routing gates, compute units (BF16/FP16/FP32/FP64 FMA, FP32 ALU, INT8/INT4/FP4/MXFP4 MAC + systolic arrays, weight dequant), RISC-V SoCs, memory controllers, PHYs, testbenches | CERN-OHL-S v2 |
| `pcb/` | PCB assembly: interconnect board (SEARAY 12G spine taps; ≈2 TB/s aggregate across 128 parallel lanes per the paper's spine sizing rule), processor board (Pi Bridge / MCU / Custom SoC), gating ASIC (MoE + DRAM) | CERN-OHL-S v2 |
| `sim/` | Go co-simulation, model compiler (HuggingFace → PNM), inference client, firmware (Go), source-language compilers (R/Haskell/HLSL) | AGPL-3.0 |
| `fw/` | C firmware port for MCU targets (ARM Cortex-M/R, RISC-V) | AGPL-3.0 |
| `toolchain/` | MCU/SoC/Linux/seL4 cross-compilation toolchains | AGPL-3.0 |
| `pi_host/` | Raspberry Pi Compute Module host drivers (Python/Go/Rust/C) | AGPL-3.0 |
| `implementations/` | Board netlist assembly, build scripts, schema | AGPL-3.0 |
| `docs/` | Usage manual, profiling guide | AGPL-3.0 |

The processor board supports three options selected by solder jumpers:
- **Pi Bridge** — SPI slave for Raspberry Pi CM0-CM4 host access
- **MCU Header** — UART + GPIO for ESP32, Pi Pico, Arduino
- **Custom SoC** — RISC-V with PCIe Gen5, NVMe, and spine engine

The gating board carries the MoE gating ASIC with DRAM options:
- **LPCAMM2 socket** (default) — field-replaceable, up to 64 GB
- **Soldered LPDDR5** — compact, lower cost

## License

Three-way split, see [LICENSE](LICENSE):

| Scope | License |
|-------|---------|
| `paper/` (manuscript, build pipeline, submission) | CC BY-SA 4.0 |
| `HDL/`, `paper/HDL/`, `pcb/` (Verilog RTL, PCB designs) | CERN-OHL-S v2 |
| Everything else (`sim/`, `implementations/`, `docs/`, toolchains) | AGPL-3.0-or-later |
