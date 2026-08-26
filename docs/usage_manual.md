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
| `fp32_alu.v` | ALU | FP32 | 1-24 cycles | Layernorm |
| `int8_mac.v` | MAC | INT8 | 1 cycle | Quantized inference |

### Orchestrator chip family

| Chip | Class | Key features |
|------|-------|-------------|
| `bmc_orchestrator_top` | Full BMC | CPU + UART + CLINT + PNM engine |
| `orchestrator_mcu` | Minimal MCU | CPU + UART only |
| `orchestrator_sbc` | SBC | CPU + SRAM + DRAM + PCIe + NVMe |
| `orchestrator_sbc_moe` | SBC+MoE | CPU + MoE gating + BF16 array + PCIe |

### Memory map (orchestrator_sbc)

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| Boot ROM | `0x0000_0000` | 64 KB | Reset vector + SPL |
| UART | `0x1000_0000` | 4 KB | 16550-compatible console |
| CLINT | `0x2000_0000` | 4 KB | Machine-mode timer + software IRQ |
| SRAM | `0x4000_0000` | 16 MB | Kernel image + stack |
| DRAM | `0x8000_0000` | 512 MB | LPDDR5/6 heap + data |
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
| LPCAMM2 socket | 262-pin BGA, 0.5mm pitch | Field-replaceable, up to 64 GB |
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
cd sim/toolchain/mcu
make            # → firmware.bin + firmware.hex
```

Output: flat binary for ROM burn-in. Linker script splits 8 KB ROM
(`0x0000_0000`) and 4 KB SRAM (`0x8000_0000`).

#### SoC daemon (NOMMU Linux, RV32IMA)

For `orchestrator_sbc` running Linux/Redox NOMMU userspace.

```bash
cd sim/toolchain/soc
make            # → pnm_socd (static musl binary)
```

Statically linked against musl-libc. Accesses PNM via `/dev/pnm` mmap.

#### Linux tinyconfig (RV32I)

Minimal Linux image that fits in 16 MB SRAM.

```bash
cd sim/toolchain/fw-linux
make check      # compile-check drivers + init
make image      # → build/Image (requires Linux source tree)
make initrd     # → build/initrd.cpio
```

Kernel config enables only: 16550 UART, NVMe block device, INITRD.
Everything else disabled.

#### seL4 microkernel (RV32IMA)

Formally-verified microkernel for hardened control plane.

```bash
cd sim/toolchain/fw-sel4
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
python3 sim/pi_host/pnm_pi.py

# Go (CM0-CM4 via raw ioctl)
go run sim/pi_host/pnm_pi.go

# Rust (CM0-CM4, zero crates)
rustc sim/pi_host/pnm_pi.rs -o pnm_pi

# C (CM0-CM4 via spidev ioctl)
gcc -o pnm_pi sim/pi_host/pnm_pi_spi.c

# C (CM5 via PCIe BAR0 mmap)
gcc -o pnm_pi_cm5 sim/pi_host/pnm_pi_cm5.c
```

## Reproducing results

The top-level script runs all verification:

```bash
bash reproduce.sh    # co-sim, Go tests, HDL testbenches (exits on first failure)
```

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
