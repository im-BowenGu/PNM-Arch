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
| **Reference chassis** | 512 nodes (8 layers × 8×8 grid) · 64 TB · ~262 TB/s aggregate · ~197 TFLOPS FP64 |
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
  cmd/pnmgate/            hardware-gated inference (real router on the Gating ASIC, vvp)
  cmd/pnmsrc/             source-language front end (R / Haskell / HLSL)
  cmd/haskell_pnm/        Haskell → PNM compiler + co-simulation runner
  cmd/r_pnm/              R → PNM compiler + co-simulation runner
  cmd/hlsl_pnm/           HLSL → PNM compiler + co-simulation runner
  internal/pnm/           harness library (topology gen, doorbell, DES, RNG)
  examples/               test configs (gemma4_test_synthetic, mini_glm_moe)

fw/                       C firmware port for MCU targets
toolchain/                MCU and SoC cross-build systems
fw/os/                   router-chip OS images (Linux NOMMU, seL4)
pi_host/                  Raspberry Pi Compute Module host drivers

implementations/        ← Board netlist assembly + schema
docs/                   ← Usage manual, profiling guide
```

### The router chip's software (and what actually runs on it)

The router SoC ships two OS stacks, both **software** (so they live with the
firmware, not with the cross-compilers):

| Tree | What it is | Status |
|------|------------|--------|
| `fw/os/linux/` | Trimmed NOMMU Linux (RV32I, no MMU/FPU) + a freestanding init that prints a banner, reads the PNM status register, probes the NVMe window and idles | the kernel and the init image **build**; the init does **not yet boot** on the proof-of-concept core (see below) |
| `fw/os/sel4/` | seL4 microkernel root task for the same chip | the build system is in place; the seL4 source tree is not vendored |

```bash
cd fw/os/linux
make init.hex            # link the init image (needs the RISC-V cross compiler)
```

**What is machine-checked.** `HDL/tb_linux_init.v` executes that init binary
on the chip's *own* `rv32_core.v` and `uart.v` and checks the boot banner, so
the driver is verified against the chip's models rather than a host's. It is
currently reported as a **skip** by `pnmt`, because it exposes a real gap in
the proof-of-concept core: **the core does not implement the JAL/JALR link
store**, so the return address is never written to `memory[sp-4]`, and no
compiler-generated code (which always spills the link to the stack) can run
on it. The fix is small, but the hand-written boot-ROM firmware in the
orchestrator testbenches has to establish a stack pointer first.

**How the test suite decides.** `iverilog`'s `$finish(1)` exits with status
0 (the argument is the diagnostic level, not the exit code), so the test
runner now decides on the *output*: a `FAILED` marker in a testbench's
output fails the test. Without that, a broken testbench was reported as a
pass.

### Published split repositories

This monorepo is the working source of truth. The same content is published
as six sibling repositories so each component can be cloned on its own:

| Repo | Contents |
|------|----------|
| [`PNM-HDL`](https://github.com/im-BowenGu/PNM-HDL) | Routing fabric + compute-unit RTL, the compute node, the RISC-V orchestrator family, `implementations/` board tooling |
| [`PNM-sim`](https://github.com/im-BowenGu/PNM-sim) | Go co-simulation harness, model compiler, inference client, source-language frontends |
| [`PNM-fw`](https://github.com/im-BowenGu/PNM-fw) | C firmware twin for MCU/SoC targets |
| [`PNM-PCB`](https://github.com/im-BowenGu/PNM-PCB) | LibrePCB board designs (interconnect, processor, gating ASIC, node) |
| [`PNM-toolchain`](https://github.com/im-BowenGu/PNM-toolchain) | MCU / SoC cross-compilation build systems |
| [`PNM-paper`](https://github.com/im-BowenGu/PNM-paper) | Manuscript (`Paper.MD`), build pipeline, submission artifacts |

Re-sync them after changing the monorepo:

```bash
tools/split_sync.sh            # report what would change (dry run)
tools/split_sync.sh --apply    # copy the git-tracked files + prune stale ones
tools/split_sync.sh --apply --commit "message"   # ... and commit in each repo
```

Only files tracked by git are copied, so generated artifacts can never leak
into a public repo; each split repo keeps its own `README.md`, `LICENSE` and
`.gitignore`. The harness resolves its siblings in both layouts, so a
split checkout runs its own suite: `cd PNM-sim && go run ./cmd/pnmt`.

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

### Real-weight inference (Gemma 4 26B-A4B)

The harness runs the **actual Gemma 4 26B-A4B checkpoint** — a pure-Go BF16
forward pass with bf16 store emulation, no torch/transformers — and is
greedy-token-identical to a Hugging Face / vLLM reference on the tested chat
prompts:

```bash
HF_TOKEN=hf_xxx ./download_model.sh                 # gated, ~52 GB, SHA-256 verified
cd sim && go run ./cmd/pnmhost inference "$PNM_MODEL_DIR" \
    "What is the capital of Germany" -max-tokens 32
# -> real-weights forward: "The capital of Germany is Berlin.<turn|>"   (stops on <turn|>)
```

The downloader is also wired into `./reproduce.sh --real-weights`. See
[`docs/real_weights.md`](docs/real_weights.md) for the HF parity results
(Germany and France chat token-for-token through the stop), the benchmark, and
the RTL proofs of concept — a real router-weight tile executed on the BF16 FMA
systolic array under `vvp` bit-exact, and the full RTL decoder block
(attention, dense MLP, MoE top-2) bit-exact against a BF16 reference on real
layer-0 slices.

### Node compute ASIC (`HDL/core/node.v`)

`node.v` is the compute node of the node network: one MoE expert pass
(gate/up → swiglu → down) on the same BF16 fused-FMA datapath as the router.
Its `CU_TYPE` parameter selects the embedded numeric ASIC behind a shared
accumulate interface, so the one source builds as BF16 / FP16 / FP32 / FP64 /
INT8 / INT4 / FP4 / MXFP4 nodes. Bit-exact validation
(`HDL/core/node_reference_test.py`, `--cu N`) covers BF16 and INT8 against
exact oracles, plus a real layer-0 expert; the format-specific boards live in
`implementations/boards/node_{bf16,fp32,int8,fp4}.json`.

### Hardware-gated inference (`pnmgate`)

`pnmgate` routes selected MoE layers through the **RTL Gating ASIC**
(`HDL/core/gating_asic.v`) running under `vvp`: it loads the layer's real
`router.proj.weight` rows into the ASIC's on-chip RAM over the register bus,
runs the gating network (all 128 expert logits + top-k, BF16 fused-FMA)
on the ASIC, feeds the ASIC logits back into the Go engine's softmax/MoE, and
runs the rest of the forward pass on the CPU over the real weights:

```bash
cd sim && go run ./cmd/pnmgate -model "$PNM_MODEL_DIR" -layers 0 -width 256 \
    "What is the capital of Germany"
# -> answer: "The capital of Germany is Berlin.<turn|>"   (same as the software engine)
```

`-width` sets the projection width loaded into the ASIC (256 = the paper's
gating-SRAM tile; `-width 2816` = full hidden). `-layers 0,7,14` gates several
layers, `-prefill-last=false` gates every prompt position. Needs `iverilog`/`vvp`
(`nix develop`) and `./reproduce.sh --real-weights` exercises it end-to-end.

Add `-network` to dispatch the ASIC's selected experts over the **node-network
fabric RTL** (`HDL/`: `hfr`/`flit_gate`/`xy_turn`/`node_eject`/...): each
top-k expert becomes a routed flit on the X/Y grid and `RunOne` proves
byte-exact delivery to the expert node (and per-node kernel correctness) before
the expert math runs on the CPU:

```bash
cd sim && go run ./cmd/pnmgate -model "$PNM_MODEL_DIR" -layers 0 -width 256 \
    -network "Hello"
# -> asic L0 top-k experts: [109 103 51 41 1 79 4 56]
# -> network: 8 packets, 8 doorbell activations, 304 DMA bytes, latency 40/41/43 cyc
# -> network: PASS — byte-exact to the expert nodes
```

`-net-bx/-net-by` set the chassis grid, `-net-layers` the chassis depth
(default: cover the gated layers), `-net-replays 2` checks determinism. Expert
`e` of layer `l` maps to node `(l, e mod bx, (e/bx) mod by)`.

Note on checkpoints: `/data/gemma4_dl/complete` is the **base/pretrained**
`google/gemma-4-26B-A4B` — it completes/echoes and never reasons, so for
instruction-following runs point `-model` at the bf16 instruction-tuned model
built from the FP8 export (`/data/ai/models/gemma-4-26b-a4b-it-bf16-fused`,
converted with `tools/dequant_fp8.py` + `tools/fuse_experts.py`). The IT model
opens its `thought` channel on its own (first token is `<|channel>`), so its
`generation_config` (`do_sample, temperature 1.0, top_k 64, top_p 0.95`) is
what governs output; use `-temp 0.7` for a serving-style answer and `-think` to
see the reasoning trace.

`./compare_vllm.sh` runs this engine and the official vLLM stack (the FP8 IT
checkpoint) in parallel on the same prompt, chat template and sampling params —
on the IT weights both sides produce essentially the same reasoning
(`<|channel>thought\n* Topic 1: Dataflow Architecture.…`, first 13 tokens
identical, a near-tie fork that reconverges).

### Source-language compilation

A subset of Haskell, R, and HLSL compiles to PNM dispatch instructions
on the chassis: Haskell and R through an FP64 IR, HLSL through an FP32
ALU IR that is lowered to the same `f64_*` kernels for dispatch.

`pnmsrc` is the client-side front end for all three languages (the
language comes from `-lang` or the file extension):

```bash
cd sim
go run ./cmd/pnmsrc examples/hello.hs -l 2 -x 2 -y 2 -run -inputs x=4,y=7
go run ./cmd/pnmsrc examples/hello.R -l 2 -x 2 -y 2 -run -inputs x=4,y=7
go run ./cmd/pnmsrc examples/hello.hlsl -l 2 -x 2 -y 2 -run -inputs x=4,y=7
```

The per-language binaries `haskell_pnm`, `r_pnm` and `hlsl_pnm` are thin
wrappers over the same front end, so the three languages cannot drift apart.

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

# node compute variants (same node.v, different CU_TYPE/WIDTH)
python3 implementations/build_asm.py implementations/boards/node_bf16.json
python3 implementations/build_asm.py implementations/boards/node_int8.json
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
| `fw/os/linux/` | Linux tinyconfig | RV32I | `Image` + `initrd.cpio` (16 MB) |
| `fw/os/sel4/` | seL4 microkernel | RV32IMA | root task ELF |

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
| `toolchain/` | MCU/SoC cross-compilation build systems | AGPL-3.0 |
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
