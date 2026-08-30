# PNM Architecture Usage Manual

## Overview

The PNM (Processing-Near-Memory) Architecture is a distributed compute
platform designed for large-scale LLM inference. It places BF16/FP16/FP32
FMA compute units directly next to LPDDR6 CAMM2 memory modules, connected
by a byte-wide source-routed wormhole routing fabric.

This manual covers how the design works and how to build it, from Verilog
RTL through PCB assembly to firmware and boot.

## How the design works

### System architecture

A PNM chassis is a stack of X/Y grid boards connected by a single spine:

```
            ┌─────────────────────────────────┐
            │       Orchestrator chip          │
            │  (RISC-V SoC, PCIe, MoE route)  │
            └──────────────┬──────────────────┘
                           │ spine (SEARAY 12G)
         ┌─────────────────┼─────────────────┐
         │                 │                 │
    ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
    │ Inter-  │      │ Inter-  │      │ Inter-  │
    │ connect │      │ connect │      │ connect │
    │ board   │      │ board   │      │ board   │
    └────┬────┘      └────┬────┘      └────┬────┘
         │                │                │
    ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
    │  Node   │      │  Node   │      │  Node   │
    │  board  │      │  board  │      │  node   │
    │(MAC+DRAM)│     │(MAC+DRAM)│     │(MAC+DRAM)│
    └─────────┘      └─────────┘      └─────────┘
```

Four kinds of hardware:

| Component | What it is | Package |
|-----------|-----------|---------|
| LPDDR6 CAMM2 module | Commodity DRAM (~256 GB/s per node) | CAMM2 socket |
| MAC ASIC | Mature-node DUV compute (BF16/FP16/FP32 FMA, INT8 MAC) | LGA-830 |
| Hardware Flit Repeater (HFR) | Stateless retimer for signal integrity | On interconnect board |
| Orchestrator chip | RISC-V SoC: boot, dispatch, MoE routing, PCIe | BGA-400 |

### Wire format

Every link carries the same byte-wide packet format:

```
Byte 0: LAYER_ID          (stripped by lxy_repeater on match)
Byte 1: MODULE_ID = {X[3:0], Y[3:0]}
Byte 2: CTRL = {vc_class[7:6], op[5:4], rsvd[3:0]}
Byte 3: LEN_LO
Byte 4: LEN_HI
Bytes 5..: payload (LEN bytes)
Last 2: CRC_HI, CRC_LO
```

CRC-16/CCITT-FALSE covers MODULE_ID through payload (not LAYER_ID).
Routing is source-routed wormhole: each gate compares one header byte
against a parameter. No runtime scheduling, no routing tables in the
fabric (only the orchestrator chip holds routing state).

### Doorbell mechanism

The doorbell is the hardware activation gate. A message fires if and only if
all three conditions hold:

1. Byte count matches `LEN + 6` (header + payload + CRC)
2. End-to-end CRC validates
3. Destination matches the local module ID

Refusals assert an error signal and increment a rejection counter. This
replaces software interrupt handling with sub-microsecond hardware gating.

### Compute units

Each node's PE tile instantiates one compute unit type:

| Module | Type | Precision | Latency | Use case |
|--------|------|-----------|---------|----------|
| `bf16_fma.v` | FMA | BF16 | 3 cycles | MoE experts, dense MLP |
| `fp16_fma.v` | FMA | FP16 | 3 cycles | FP16 models |
| `fp32_fma.v` | FMA | FP32 | 3 cycles | High-precision compute |
| `fp64_fma.v` | FMA | FP64 | 3 cycles | Double-precision scientific |
| `bf16_mac_array.v` | Systolic array | BF16 | variable | Attention QKV |
| `fp16_mac_array.v` | Systolic array | FP16 | variable | FP16 attention |
| `fp32_alu.v` | ALU | FP32 | 3 (MIN/MAX/CMP), 4 (FMA), 28 (DIV) | Layernorm |
| `int8_mac.v` | MAC | INT8 | 2 cycles | Quantized inference |

### Orchestrator chip family

| Chip | Class | Key features |
|------|-------|-------------|
| `bmc_orchestrator_top` | Full BMC | CPU + UART + CLINT + PNM engine |
| `orchestrator_mcu` | Minimal MCU | CPU + UART only |
| `orchestrator_sbc` | SBC | CPU + SRAM + DRAM + PCIe + NVMe |
| `orchestrator_sbc_moe` | SBC+MoE | CPU + MoE gating + PCIe |

### Memory map (orchestrator_sbc)

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| Boot ROM | `0x0000_0000` | 64 KB | Reset vector + SPL |
| UART | `0x1000_0000` | 4 KB | 16550-compatible console |
| CLINT | `0x2000_0000` | 64 KB | Machine-mode timer + software IRQ (page-decoded) |
| SRAM | `0x4000_0000` | 512 KB (default; configurable 500 KB–32 MB) | Kernel image + stack |
| DRAM | `0x8000_0000` | 1 GB | LPDDR5/6 heap + data |
| PCIe | `0xC000_0000` | 4 KB | Gen5 x16 PHY registers |
| NVMe | `0xD000_0000` | 64 B | AXI-Lite register window |
| PNM | `0xF000_0000` | 64 B | Router chip registers |

## Build system

The build pipeline has three stages: RTL assembly, PCB design, and
firmware compilation.

### Stage 1: RTL assembly

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
[`implementations/schema.md`](../implementations/schema.md). Key sections:

- **`components[]`** — silicon instances (modules from `HDL/` with parameter overrides)
- **`connections[]`** — point-to-point nets (validated for existence, direction, width)
- **`tieoffs[]`** — constant drivers for configuration inputs
- **`external[]`** — top-level ports of the generated wrapper

PCB traces are components too: `pcb_link` with `DELAY_NS=40` models a 40 mm
motherboard trace. Clock gating uses `clk_gate`, reset synchronization uses
`rst_sync`.

Generated artifacts (in `implementations/build/<name>/`):

| File | Contents |
|------|----------|
| `<name>_top.v` | Wrapper: external ports, wires, tieoffs, instances |
| `tb_<name>.v` | Clock/reset generator, idle-run testbench |
| `filelist.f` | Source files for iverilog/verilator |

### Stage 2: PCB design

All boards use LibrePCB (open-source EDA), 4-layer stackup (top copper,
GND, power, bottom copper).

#### Interconnect board (parameterized)

The interconnect board is generated from a topology schema:

```bash
# X2+LXY variant, 8 layers, 4x4 grid per board
python3 pcb/interconnect_board/gen_topology.py \
  --variant x2_lxy --layers 8 --board-x 4 --board-y 4

# XY-only variant (no Z-axis, no HFR)
python3 pcb/interconnect_board/gen_topology.py \
  --variant xy --layers 2 --board-x 4 --board-y 4
```

Variants:
- **`x2_lxy`** — LXY repeater at center, HFR pipe stage, dual NoB connectors
- **`xy`** — Pure XY repeater (no Z-axis, no HFR)

The generator emits LibrePCB schematic files (`.lp`) with components,
netsegments, junctions, and labels.

#### Processor board (manual)

Three processor options selected by solder jumpers:

| Option | Interface | Connector |
|--------|-----------|-----------|
| Pi Bridge | SPI slave (CM0-CM4) | 2x6 header |
| MCU Header | UART + GPIO (ESP32, Pi Pico) | 2x10 header |
| Custom SoC | RISC-V + PCIe Gen5 + NVMe | BGA-400 |

Open `pcb/processor/processor.lpp` in LibrePCB to place and route.

#### Gating ASIC board (manual)

MoE gating ASIC with DRAM options:

| Option | Package | Notes |
|--------|---------|-------|
| LPCAMM2 socket | 644-pin, 0.5mm pitch | Field-replaceable, up to 64 GB |
| Soldered LPDDR5 | 200-ball, 0.65mm pitch | Compact, lower cost |

Open `pcb/gating_asic/gating_asic.lpp` in LibrePCB.

#### Compute node board (manual)

MAC ASIC (LGA-830) + LPCAMM2 socket. Open `pcb/pnm_node/pnm_node.lpp`.

#### PCB workflow

1. Open LibrePCB, File -> Open Project -> `pcb/<board>/<board>.lpp`
2. Add components from the local library (`library/`) or standard passives
3. Place footprints on the board; route DDR escape and fabric links
4. Run DRC; export Gerber + drill + BOM via File -> Output -> Manufacturing

### Stage 3: Firmware

Four toolchains for the RISC-V orchestrator chip:

#### MCU (bare-metal, RV32I)

For `orchestrator_mcu` on small chassis. No OS, no libc, 8 KB ROM.

```bash
cd toolchain/mcu
make            # → firmware.bin + firmware.hex
```

Output: flat binary for ROM burn-in. Linker script splits 8 KB ROM
(`0x0000_0000`) and 4 KB SRAM (`0x8000_0000`).

#### SoC daemon (NOMMU Linux, RV32IMA)

For `orchestrator_sbc` running Linux/Redox NOMMU userspace.

```bash
cd toolchain/soc
make            # → pnm_socd (static musl binary)
```

Statically linked against musl-libc. Accesses PNM via `/dev/pnm` mmap.

#### Linux tinyconfig (RV32I)

Minimal Linux image that fits in 16 MB SRAM.

```bash
cd toolchain/fw-linux
make check      # compile-check drivers + init
make image      # → build/Image (requires Linux source tree)
make initrd     # → build/initrd.cpio
```

Kernel config enables only: 16550 UART, NVMe block device, INITRD.
Everything else disabled.

#### seL4 microkernel (RV32IMA)

Formally-verified microkernel for hardened control plane.

```bash
cd toolchain/fw-sel4
make            # → seL4 kernel + root task ELF (requires seL4 source tree)
```

### Boot sequence

```
Boot ROM (64 KB)
  → SPL: probe NVMe, load kernel to DRAM 0x8000_0000
    → kernel or seL4
      → init: UART banner, NVMe probe, wfi idle
        → pnm_socd: mmaps /dev/pnm, runs dispatch loop
```

The orchestrator chip's firmware:
1. **POST discovery** — walks the spine, identifies all nodes
2. **Routing table load** — programs the flit builder's coordinate map
3. **Weight upload** — streams model weights to node DRAM via PCIe
4. **MoE gating load** — programs expert-to-node assignment
5. **Dispatch loop** — routes tokens to experts, collects results

## Pi host drivers

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

## Reproducing results

The top-level script runs all verification:

```bash
bash reproduce.sh    # co-sim, Go tests, HDL testbenches (exits on first failure)
```

## Unified host driver

The `pnmhost` CLI is a single entry point for all PNM workloads. It replaces
the fragmented `cmd/pnm`, `cmd/pnmc`, and language CLI toolchains with one
driver that handles scenarios, HPC benchmarks, programs, model compilation,
and LLM inference — all with timestamped logging and structured result export.

### Commands

| Command | Description |
|---------|-------------|
| `pnmhost scenario <name> [...]` | Fabric verification (sweep, vcsweep, load, hotspot, stress, replay) |
| `pnmhost workload <name>` | HPC workload (jacobi5, matvec, reduction, broadcast, nbody) |
| `pnmhost program <path.pnm>` | Compile and run a .pnm program |
| `pnmhost model <dir>` | Compile a HuggingFace model onto the chassis |
| `pnmhost inference <dir> <prompt>` | Run LLM inference |
| `pnmhost run <path.pnm>` | Auto-detect and run |

### Usage

```bash
# Run multiple scenarios with result export
pnmhost scenario sweep load stress -l 4 -x 4 -y 4 -output results/

# Run an HPC workload
pnmhost workload matvec -l 4 -x 4 -y 4 -frag 32

# Compile and run a program with logging
pnmhost program examples/bias_add.pnm -log results/run.log

# Full model compilation + inference pipeline
pnmhost model examples/gemma4_test -o results/
pnmhost inference examples/gemma4_test "Hello, world!" -max-tokens 16
```

### Global options

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

### Programmatic API

```go
hd := pnm.NewHostDriver(pnm.HostConfig{
    Layers: 4, Bx: 4, By: 4,
    OutputDir: "results/",
    LogFile:   "results/run.log",
})
hd.RunScenarios("sweep", "load", "stress")
hd.RunWorkload("matvec", 32)
hd.RunProgram("examples/bias_add.pnm")
hd.RunModel("examples/gemma4_test")
hd.RunInference("examples/gemma4_test", "Hello")
hd.WriteResults()
fmt.Print(hd.Summary())
```

## Data output and logging

The co-simulation harness and inference client export structured results
for analysis. All output is opt-in via `--output <dir>`.

### Co-simulation results (`cmd/pnm`)

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

### Inference results (`cmd/pnmc run-driver`)

```bash
go run ./cmd/pnmc run-driver examples/gemma4_test -o results/
```

In addition to `routing_table.json`, `moe_map.json`, and `dispatch_plan.txt`,
writes `dispatch_plan.csv` with per-dispatch-step structured data (layer, phase,
target node, expert index, flit bytes, compute unit, KV action).

### LLM client token export

The `LLMClient` provides two export methods:

- `WriteTokens(path, prompt, tokenIDs)` — writes prompt + generated text + token IDs to a human-readable file
- `ExportInference(path, prompt, tokenIDs, dispatches)` — writes complete inference result as JSON (tokens + stats + dispatch plan)

### Programmatic API

```go
// Collect scenario results from RunOne
result, ok := pnm.RunOne(prog, nodes, dims, groups, 1)
if result != nil {
    pnm.WriteScenarioCSV("results.csv", []pnm.ScenarioResult{*result})
    pnm.WriteScenarioJSON("results.json", &pnm.RunResult{Scenarios: []pnm.ScenarioResult{*result}})
}
```

## Haskell-to-PNM compilation

The `haskell_pnm`, `r_pnm`, and `hlsl_pnm` tools compile a subset of
Haskell, R, or HLSL to FP64 dispatch instructions on the PNM chassis.

### Supported syntax

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

### Example

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

### Compilation pipeline

```
Haskell/R/HLSL source
  → FP64/FP32 IR (f64.add, alu.mul, ...)
  → PNM dispatch (kernel + token directives)
  → co-simulation on the chassis
```

Each operation maps to a node running an `f64_*` kernel. Operands
are packed as big-endian FP64 bytes (8 bytes each) in token payloads.

### Usage

```bash
cd sim

# Haskell
go run ./cmd/haskell_pnm examples/hello.hs -l 2 -x 2 -y 2
go run ./cmd/haskell_pnm examples/hello.hs -l 2 -x 2 -y 2 -run

# R
go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2
go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2 -run

# HLSL
go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2
go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2 -run
```

### FP64 kernels

| Kernel | Payload | Result |
|--------|---------|--------|
| `f64_add` | `[a:8B, b:8B]` | `a + b` (8 bytes) |
| `f64_mul` | `[a:8B, b:8B]` | `a * b` (8 bytes) |
| `f64_fma` | `[a:8B, b:8B, c:8B]` | `a*b + c` (8 bytes) |

## Workload classification

### MCU-class (orchestrator_mcu)

- Stencil (jacobi5): intra-layer nearest-neighbor communication
- Reduction: tree-based parallel reduction along the spine
- Broadcast: fan-out from spine root to all nodes
- Matrix-vector multiply: spine descent, single-layer

### SoC-class (orchestrator_sbc)

- LLM inference: model compiler transpiles HuggingFace safetensors
- MoE dispatch: top-k expert selection, gating, token routing
- KV cache management: LRU eviction, NVMe overflow
- Model weight persistence: NVMe save/load across power cycles

### Compute-intensive

- O(N^2) saturation: n-body all-pairs (tests bisection bandwidth)
- Attention QKV: BF16/FP16 systolic array
- Dense MLP: BF16 FMA across all nodes
