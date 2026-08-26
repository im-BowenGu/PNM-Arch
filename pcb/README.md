# pcb/ — PCB-level board designs for PNM chassis

Physical board designs for the PNM architecture, targeting [LibrePCB](https://librepcb.org)
as the EDA tool. LibrePCB is a cross-platform, open-source PCB design suite that
produces production-ready Gerber/drill files and BOMs — no license server, no
vendor lock-in, no binary file corruption.

## Chassis architecture

A PNM chassis is a vertical stack of 1-16 board layers connected by a central
spine cable. The reference chassis is 8 layers with 16 compute nodes per layer
(128 nodes total).

```
                    ┌─────────────────────────┐
                    │    processor board       │  Spine root (1 per chassis)
                    │  (Pi Bridge / MCU / SoC) │
                    │  PCIe host + NVMe boot   │
                    └──────────┬──────────────┘
                               │ spine cable (pass-through connectors)
               ┌───────────────┼───────────────┐
               │               │               │
        ┌──────┴──────┐ ┌──────┴──────┐ ┌──────┴──────┐
        │ interconnect│ │ interconnect│ │ interconnect│  One per board layer
        │   board     │ │   board     │ │   board     │  Center cutout for spine
        └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
               │               │               │
        ┌──────┴──────┐ ┌──────┴──────┐ ┌──────┴──────┐
        │  pnm_node   │ │  pnm_node   │ │  pnm_node   │  Compute nodes
        │  MAC + DRAM │ │  MAC + DRAM │ │  MAC + DRAM │  (16 per layer)
        └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
               │               │               │
        ┌──────┴──────┐ ┌──────┴──────┐ ┌──────┴──────┐
        │gating board │ │gating board │ │gating board │  Optional MoE gating
        │ LPCAMM2 or  │ │ LPCAMM2 or  │ │ LPCAMM2 or  │  (1 per layer)
        │ LPDDR5      │ │ LPDDR5      │ │ LPDDR5      │
        └─────────────┘ └─────────────┘ └─────────────┘
```

## Board descriptions

### pnm_node — Compute node board

The core compute element. One DUV MAC ASIC socket (LGA-830, ~830 pins) paired
with one LPCAMM2/LPDDR6 socket (644 pins), connected via point-to-point fabric
links through a mezzanine connector to the interconnect board above.

Per-node power: ~15 W total (9 W MAC, 5 W DRAM, 1 W fabric) on three rails
(core 0.8 V, I/O 1.2 V, LPDDR6 PHY 1.1 V).

**4-layer stackup**: top copper → inner1 (GND) → inner2 (power) → bottom copper.

### processor board (was "orchestrator_sbc")

The management board at the spine root. Connects the host (PCIe) to the PNM
fabric (spine cable). Supports three processor options (one active at a time,
selected by solder jumpers):

| Processor | Interface | Use case |
|-----------|-----------|----------|
| **Pi Bridge** (`pi_bridge.v`) | SPI slave (SCLK/MOSI/MISO/CS) | CM0-CM4 host access via Python/Go/Rust/C drivers |
| **Off-the-shelf MCU** | UART (TX/RX) + GPIO (DOORBELL_TRIG, PNM_VALID) | ESP32, Arduino, Pi Pico — simple dispatch controller |
| **Custom SoC** (BGA-400) | Native bus (AXI-Lite) | Full RISC-V SoC with NOMMU Linux, NVMe boot, PCIe Gen5 |

All three processor options share the same PNM register window at `0xF000_0000`
(on custom SoC) or the same SPI/UART protocol (on Pi Bridge / MCU).

**Boot**: 4KB bootstub ROM copies the kernel from NVMe into SRAM (500KB-32MB
configurable), then jumps to it. NOMMU Linux fits in ~1MB stripped down.
No DRAM on the processor package — everything runs from on-chip SRAM.

**Memory map** (custom SoC only):

| Region | Address Range | Size | Description |
|--------|--------------|------|-------------|
| Boot ROM | `0x0000_0000` | 4KB | Bootstub: NVMe→SRAM copy + jump |
| UART | `0x1000_0000` | 4KB | 16550-compatible debug console |
| CLINT | `0x2000_0000` | 4KB | Timer + software interrupt |
| SRAM | `0x4000_0000` | 500KB-32MB | On-chip SRAM (kernel + runtime) |
| PCIe | `0xC000_0000` | 4KB | PCIe config/status registers |
| NVMe | `0xD000_0000` | 4KB | NVMe controller (boot + weights + swap) |
| PNM | `0xF000_0000` | 4KB | PNM orchestrator engine |

**NVMe** provides block storage for:
- Model weight persistence (survives power cycles)
- KV cache overflow to swap
- Lustre FS backing store
- General block I/O for NOMMU Linux userland

**4-layer stackup**: top copper → inner1 (GND) → inner2 (power) → bottom copper.

### gating_board — MoE gating network board

Optional per-layer board for Mixture-of-Experts expert routing. The gating
network can have ~1 GB of weights (gating matrices scale with expert count),
so this board includes DRAM for weight storage. Two options (footprints
overlap, populate one):

| Option | Package | Capacity | Bandwidth | Notes |
|--------|---------|----------|-----------|-------|
| **LPCAMM2** (default) | 644-ball CAMM2 | 16GB+ | 256 GB/s | Same BOM as pnm_node |
| **Soldered LPDDR5** | BGA-200 | 4-8GB | 50 GB/s | Lower cost, no socket |

The gating ASIC itself contains a BF16 MAC array for logit computation and a
top-K sorter. It runs once per token (the design bottleneck for MoE routing),
so DRAM bandwidth directly impacts expert selection latency.

**Power**: ~8W (3W logic + 5W DRAM).

### interconnect_board — Spine fabric

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
connectors (60-pin, 1.27mm pitch, >2 TB/s per pair). Each board taps into the
spine via the LXY repeater's `spin_in`/`spin_out` port pair — one upstream
connector, one downstream. Traffic not destined for this layer passes straight
through. The SEARAY pass-through design allows boards to be added or removed
without desoldering the cable harness. The board has a center cutout
(15mm x 150mm) for the spine cable to pass through, with SEARAY
connectors flanking the cutout on both sides.

**4-layer stackup**: top copper → inner1 (GND) → inner2 (power) → bottom copper.

## Project layout

```
pcb/
├── README.md                  this file
├── pnm_node/                  compute-node board (MAC ASIC + LPCAMM2 socket)
│   ├── pnm_node.lpp           LibrePCB project
│   ├── library/               MAC ASIC (LGA-830), LPCAMM2 (644-ball)
│   ├── schematics/            schematic sheets
│   └── boards/                4-layer board layout
├── processor/                 processor board (was orchestrator_sbc)
│   ├── processor.lpp          LibrePCB project
│   ├── library/               Pi Bridge, MCU header, Custom SoC BGA-400,
│   │                          PCIe x16 edge, M.2 NVMe
│   ├── schematics/            schematic sheets
│   └── boards/                4-layer board layout
├── gating_board/              MoE gating board (gating ASIC + LPCAMM2/LPDDR5)
│   ├── gating_board.lpp       LibrePCB project
│   ├── library/               Gating ASIC, LPCAMM2, LPDDR5 BGA
│   ├── schematics/            schematic sheets
│   └── boards/                4-layer board layout
└── interconnect_board/        spine fabric (LXY repeaters + HFRs + spine pass-through)
    ├── interconnect_board.lpp LibrePCB project
    ├── library/               LXY Repeater, HFR, NoB connector, Spine pass-through
    ├── schematics/            schematic sheets
    ├── gen_topology.py         parameterized topology generator
    ├── gen_schematic.py        schematic netlist generator
    └── boards/                4-layer board layout
```

## Local library — PNM-specific components

| Device | Symbol | Package | Description |
|--------|--------|---------|-------------|
| PNM-MAC-ASIC | `mac_asic.ls` | `lga830_mac_asic.lp` | DUV MAC compute ASIC, 28x28 mm LGA-830 |
| PNM-LPCAMM2 | `lpamm2.ls` | `lpamm2_644.lp` | LPCAMM2/LPDDR6 CAMM2 socket, 644-ball |
| PNM-GATING-ASIC | `gating_asic.ls` | `gating_asic.lp` | MoE gating network ASIC with BF16 MAC |
| PNM-PI-BRIDGE | `pi_bridge.ls` | `spi_header.lp` | SPI slave interface for Pi CM0-CM4 |
| PNM-MCU-HEADER | `mcu_header.ls` | `2x10_header.lp` | UART+GPIO header for ESP32/Pico/Arduino |
| PNM-ROUTER-SOC | `router_soc.ls` | `bga400_soc.lp` | Custom RISC-V SoC, 17x17 mm BGA-400 |
| PNM-PCIE-X16 | `pcie_edge.ls` | `pcie_x16_edge.lp` | PCIe Gen5 x16 edge connector |
| PNM-M2-NVME | `m2_nvme.ls` | `m2_m_key.lp` | M.2 Key-M NVMe module slot |
| PNM-SPINE-MEZZ | `spine_pass.ls` | `searay_60.lp` | Spine cable pass-through, SEARAY 12G 60-pin |
| PNM-MEZZ | `mezz.ls` | `searay_60.lp` | Mezzanine connector to pnm_node, SEARAY 12G 60-pin |

## Assembly variable: board count

The chassis supports 1-16 board layers. The reference configuration is
**8 layers × 16 nodes = 128 compute nodes**.

Board count is a build-time parameter. The `gen_topology.py` script generates
the interconnect board schematic and the Verilog topology for any valid
configuration:

```bash
# Reference chassis: 8 layers, 4×4 nodes per layer
python3 gen_topology.py --variant x2_lxy --layers 8 --board-x 4 --board-y 4

# Small config: 2 layers, 2×2 nodes per layer (8 nodes total)
python3 gen_topology.py --variant x2_lxy --layers 2 --board-x 2 --board-y 2

# Large config: 16 layers, 8×8 nodes per layer (1024 nodes)
python3 gen_topology.py --variant x2_lxy --layers 16 --board-x 8 --board-y 8
```

The Go co-simulation mirrors this:

```bash
go run ./cmd/pnm -l 8 -x 4 -y 4       # reference: 128 nodes
go run ./cmd/pnm -l 2 -x 2 -y 2       # small: 8 nodes
go run ./cmd/pnm -l 16 -x 8 -y 8      # large: 1024 nodes
```

## Spine cable

The spine is a shielded cable harness that passes through the center cutout
of each interconnect board. Each board taps into the spine via two Samtec
SEARAY 12G connectors (60-pin, 1.27mm pitch, >2 TB/s per pair):

- **Upstream** (toward processor): carries `spin_in_data/valid/sop/eop/ready/vc`
- **Downstream** (toward bottom): carries `spin_out_data/valid/sop/eop/ready/vc`

The cable uses SEARAY pass-through connectors so each board can be
added or removed without desoldering. The processor board sits at the top
of the stack and injects/ejects flits from the spine.

## Processor board: MCU selector

The processor board has three processor footprints. Solder jumpers select
which one drives the PNM bus:

| Jumper | Position | Active processor | Interface |
|--------|----------|-----------------|-----------|
| JP1 | 1-2 | Pi Bridge | SPI (SCLK/MOSI/MISO/CS) |
| JP1 | 2-3 | MCU header | UART (TX/RX) + GPIO |
| JP2 | 1-2 | Custom SoC | Native AXI-Lite bus |
| JP2 | 2-3 | (reserved) | — |

Only one processor can be active at a time. The PNM register window is
the same regardless of which processor is selected.

## Integration with HDL/

LibrePCB handles the physical board; the HDL sources handle the logic.
The connection between them is the register map documented in:
- `HDL/orchestrator_sbc.v` — memory map (SRAM, PCIe, NVMe, PNM windows)
- `HDL/pi_bridge.v` — SPI bridge register protocol (for Pi Bridge / CM0–CM4)
- `HDL/core/pe_tile_stub.v` — MAC ASIC port list (symbol pin definitions)
- `HDL/orchestrator_mcu.v` — minimal MCU variant (UART + PNM only)

## LibrePCB setup

```bash
# install (flatpak recommended on Linux)
flatpak install org.librepcb.LibrePCB

# or from source
git clone https://github.com/LibrePCB/LibrePCB.git
cd LibrePCB && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)
```

### Workflow

1. Open LibrePCB, File → Open Project → `pcb/pnm_node/pnm_node.lpp`.
2. The project opens with an empty schematic and a 4-layer board.
3. Add components from the local library (`library/`) or standard passives.
4. Place footprints on the board; route DDR escape and fabric links.
5. Run DRC; export Gerber + drill + BOM via File → Output → Manufacturing.
