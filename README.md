# Breaking the HBM wall

> An open-source distributed spatial Processing-Near-Memory architecture built
> from commodity LPDDR6 CAMM2 modules, mature-node DUV MAC ASICs, and a
> deterministic single-spine wormhole routing fabric.

**Paper:** [*Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing*](paper/Paper.MD) · [TL;DR](TLDR.md) · [Architecture brief](paper/TLDR_Paper.md)

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
    pnm_defs.vh             shared definitions (wire format, parameters)
    hfr.v                   Hardware Flit Repeater
    flit_gate.v             shared demux core
    vc_merge.v              VC arbitration for egress
    lxy_repeater.v          layer gate (strips LAYER_ID on match)
    xy_turn.v               X→Y dimension-order turn gate
    node_eject.v            node eject gate
    core/doorbell.v         doorbell discipline (three-condition fire)
    core/crc16.v            CRC-16/CCITT-FALSE
    core/pe_tile_stub.v     PE tile stub (bias add + CRC recompute)
    tb_fabric.v             functional smoke test
    tb_load.v               500-packet load test with backpressure
    tb_flit_gate.v          flit_gate unit tests
    tb_hfr.v                HFR unit tests
    core/tb_doorbell.v      doorbell unit tests

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
  internal/pnm/           harness library (topology gen, doorbell, DES, RNG)
  fw/                     C firmware port for MCU targets
  toolchain/              MCU, SoC, fw-linux, fw-sel4, pi_host drivers
  examples/               test configs (gemma4_test, mini_glm_moe)

implementations/        ← Board netlist assembly + schema
docs/                   ← Usage manual, profiling guide
```

## Getting started

Requires [Nix](https://nixos.org) with flakes-style `nix-shell` support.

```bash
nix-shell                    # enter environment (iverilog, go, pdflatex, pandoc)
```

### Build the paper

```bash
cd paper && python3 build.py           # → submission/paper.docx
python3 build.py --review              # → submission/paper_review.pdf (single-column)
```

### Verify the fabric (paper proofs)

```bash
cd paper/HDL

# 500-packet load test: byte-exact delivery, zero drops, zero misroutes
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out

# doorbell discipline: six activations, two refusals, two corrupt_out pulses
iverilog -g2005 -o tb_doorbell.out \
  core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v && vvp tb_doorbell.out

# full fabric smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
```

### Co-simulation (6 scenarios at any chassis scale)

```bash
cd sim
go run ./cmd/pnm                  # 3×4×4 = 48 nodes, all 6 scenarios
go run ./cmd/pnm -l 8 -x 8 -y 8  # 512-node reference chassis
```

Scenarios: `sweep` (exact closed-form latency), `vcsweep` (all VC classes),
`load` (500 flits, lossless), `hotspot` (MoE hot expert), `stress` (3%
corrupt CRC the doorbell must reject), `replay` (bit-identical determinism).

### All HDL testbenches

See [`paper/HDL/`](paper/HDL/) for the paper-verification subset. The full
test suite lives in [`HDL/`](HDL/) — run all tests with:

```bash
cd HDL
# See HDL/README.md for the full list of 30+ testbenches
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
| `interconnect_board` | Spine fabric: SEARAY 12G pass-through, LXY repeaters, HFR pipe stages | `gen_topology.py` (parameterized) |
| `processor` | Management: Pi Bridge / MCU Header / Custom SoC (BGA-400) | manual placement |
| `gating_asic` | MoE gating + DRAM (LPCAMM2 socket or soldered LPDDR5) | manual placement |
| `pnm_node` | Compute node: MAC ASIC (LGA-830) + LPCAMM2 socket | manual placement |

```bash
python3 pcb/interconnect_board/gen_topology.py --variant x2_lxy --layers 8 --board-x 4 --board-y 4
```

Open any `.lpp` in LibrePCB to place footprints, route, run DRC, and
export Gerber + drill + BOM. See [`pcb/README.md`](pcb/README.md) for
board architecture and wiring.

### Firmware

Four toolchains for the RISC-V orchestrator chip, from bare-metal to Linux:

| Toolchain | Target | ISA | Output |
|-----------|--------|-----|--------|
| `sim/toolchain/mcu/` | Bare-metal MCU | RV32I | `firmware.bin` (8 KB ROM) |
| `sim/toolchain/soc/` | NOMMU Linux daemon | RV32IMA | `pnm_socd` (static musl) |
| `sim/toolchain/fw-linux/` | Linux tinyconfig | RV32I | `Image` + `initrd.cpio` (16 MB) |
| `sim/toolchain/fw-sel4/` | seL4 microkernel | RV32IMA | root task ELF |

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

## What the paper proves

Five properties are machine-checked on every run:

1. **Byte-exact delivery** — bytes delivered to each node equal bytes injected; no loss, no duplication, no reorder
2. **Zero drops and zero misroutes** — every injected flit reaches its declared destination; dimension-order routing leaves no residual
3. **Doorbell accounting** — hardware verdicts (activations, refusals, corrupt_out pulses) match the three-condition fire logic message by message
4. **Kernel correctness** — each resident kernel executes on what the hardware delivered and matches the golden model
5. **Latency bounds** — sweep checks every packet against the closed form (hop count × per-hop delay + serialization) exactly

## Manufacturable design

Everything outside `paper/` is the production design:

| Directory | What it contains | License |
|-----------|-----------------|---------|
| `HDL/` | Full Verilog-2005 fabric: routing gates, compute units (BF16/FP16/FP32/FP64 FMA, FP32 ALU, INT8 MAC, systolic arrays), RISC-V SoCs, memory controllers, PHYs, testbenches | CERN-OHL-S v2 |
| `pcb/` | PCB assembly: interconnect board (SEARAY 12G spine, >2 TB/s), processor board (Pi Bridge / MCU / Custom SoC), gating ASIC (MoE + DRAM) | CERN-OHL-S v2 |
| `sim/` | Go co-simulation, model compiler (HuggingFace → PNM), inference client, firmware (Go + C), MCU/SoC/Linux toolchains, Pi host drivers (Python/Go/Rust/C) | AGPL-3.0 |
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
