# Repository Documentation

> Comprehensive documentation for the PNM Architecture paper repository.

## Overview

This repository contains the working artifacts behind the paper *Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing*. It includes the manuscript source, a Go-Verilog co-simulation harness, Verilog HDL for the routing fabric and compute units, a RISC-V BMC/orchestrator chip SoC, and a build pipeline that produces the DOCX submission.

## Repository Structure

```
Paper/
  Paper.MD              # Manuscript source (Markdown with LaTeX-escape conventions)
  build.py              # Build pipeline -> submission/paper.docx (+ .pdf, .tex)
  AGENTS.md             # Agent guidance for working in this repository
  flake.nix             # Nix flake with the full toolchain (`nix develop`)
  README.md             # Project overview
  HDL/                  # Verilog-2005 fabric model + compute units
  sim/                  # Co-simulation harness (Go, stdlib only)
  fw/                   # C firmware port for MCU targets
  toolchain/            # MCU/SoC/Linux/seL4 cross-compilation toolchains
  pi_host/              # Raspberry Pi Compute Module host drivers
  sim/examples/         # Synthetic test configurations
  submission/           # Build artifacts (gitignored)
```

## Hardware Description Language (HDL/)

### Routing Fabric

The fabric is a byte-wide, Verilog-2005 model of the deterministic single-spine wormhole routing topology.

| Module | File | Description |
|--------|------|-------------|
| `hfr.v` | Hardware Flit Repeater | Stateless retimer; forwards flits one byte per cycle |
| `flit_gate.v` | Flit Gate | Combinational demux; compares header byte against parameter |
| `vc_merge.v` | VC Merge | 2-in/1-out round-robin arbiter for egress tree |
| `lxy_repeater.v` | LXY Repeater | Layer gate; matches LAYER_ID, strips on match |
| `xy_turn.v` | XY Turn | X-dimension gate; matches X nibble of MODULE_ID |
| `node_eject.v` | Node Eject | Destination gate; matches full MODULE_ID |
| `pnm_defs.vh` | Definitions | Wire format constants, VC classes, CRC parameters |

### Compute Units

| Module | Type | Precision | Latency | Use Case |
|--------|------|-----------|---------|----------|
| `bf16_fma.v` | FMA | BF16 | 3 cycles | MoE experts, dense MLP |
| `fp16_fma.v` | FMA | FP16 | 3 cycles | FP16 models |
| `fp32_fma.v` | FMA | FP32 | 3 cycles | High-precision compute |
| `fp64_fma.v` | FMA | FP64 | 3 cycles | Double-precision scientific |
| `bf16_mac_array.v` | Systolic array | BF16 | variable | Attention QKV |
| `fp16_mac_array.v` | Systolic array | FP16 | variable | FP16 attention |
| `fp32_alu.v` | ALU | FP32 | 3 (MIN/MAX/CMP), 4 (FMA), 28 (DIV) cycles | Layernorm (divider) |
| `int8_mac.v` | MAC | INT8 | 2 cycles | Quantized inference |
| `int4_mac.v` | MAC | INT4 | 2 cycles | INT4 quantized (packed nibbles) |
| `int4_mac_array.v` | Systolic array | INT4/INT8 | variable | INT4 quantized inference (4x density) |
| `fp4_mac.v` | MAC | FP4 (E2M1) | 2 cycles | FP4 quantized (packed nibbles) |
| `fp4_mac_array.v` | Systolic array | FP4 | variable | FP4 quantized inference (4x density vs BF16) |
| `mxfp4_mac_array.v` | Systolic array | MXFP4 | variable | MXFP4 block-scaled (OCP microscaling) inference |
| `moe_gating.v` | MoE Gating | BF16 | variable | Top-k expert selection |

### Doorbell and CRC

| Module | File | Description |
|--------|------|-------------|
| `doorbell.v` | Doorbell | Three-condition fire: byte count, CRC validate, DEST match |
| `crc16.v` | CRC-16 | CCITT-FALSE (init 0xFFFF, poly 0x1021) |
| `pe_tile_stub.v` | PE Tile Stub | MAC stub with bias-add, CRC recompute, AXI-Stream interface |

### Router Chip Family (RISC-V SoC)

The orchestrator chip family is implemented as RISC-V System-on-Chip designs for chassis management, topology discovery, MoE dispatch, and host PCIe. Three tiers target different deployment classes:

| Module | File | Class | Description |
|--------|------|-------|-------------|
| `rv32_core.v` | RV32IMA CPU | shared | Multi-cycle 5-stage FSM core: RV32I base + M extension + Zicsr |
| `uart.v` | UART | shared | 16550-compatible, 8N1, configurable baud, interrupt output |
| `clint.v` | CLINT | shared | Machine-mode timer (mtime/mtimecmp) + software interrupt (msip) |
| `bmc_orchestrator_top.v` | BMC SoC | full | CPU + 64KB ROM + 64KB SRAM + UART + CLINT + PNM orchestrator engine |
| `orchestrator_mcu.v` | MCU Orchestrator | minimal | RV32I + 8KB ROM + 4KB SRAM + UART only. No PCIe/MoE/FPU. For stencil/reduction/broadcast on small chassis |
| `orchestrator_sbc_moe.v` | SBC+MoE Router | mid-tier | RV32IMA + LPDDR5 DRAM stub + 64KB MoE gating SRAM + moe_gating unit + PCIe Gen5 register stub. For MoE/dense LLM dispatch |
| `orchestrator_sbc.v` | SBC Orchestrator | general | RV32IMA + 64KB ROM + on-chip SRAM (0x40000000, configurable 512KB default up to 32MB via SRAM_WORDS; fw-linux targets 16MB) + LPDDR5 DRAM stub (1GB window) + PCIe Gen5 x16 PHY + NVMe storage controller. Runs Linux/seL4 NOMMU + CPython userland. For transpiler orchestration and complex data workflows |

Memory maps:
- **bmc_orchestrator_top**: ROM@0x00000000, UART@0x10000000, CLINT@0x20000000, SRAM@0x80000000, PNM@0xF0000000.
- **orchestrator_mcu**: ROM@0x00000000 (8KB), UART@0x10000000, SRAM@0x80000000 (4KB), PNM@0xF0000000.
- **orchestrator_sbc_moe**: ROM@0x00000000, UART@0x10000000, CLINT@0x20000000, GatingSRAM@0x40000000 (64KB BF16), DRAM@0x80000000 (512MB), PCIe@0xC0000000, PNM@0xF0000000.
- **orchestrator_sbc**: ROM@0x00000000 (64KB), UART@0x10000000, CLINT@0x20000000, SRAM@0x40000000 (256MB window; 512KB default, configurable up to 32MB), DRAM@0x80000000 (1GB), PCIe@0xC0000000 (Gen5 x16 PHY), NVMe@0xD0000000, PNM@0xF0000000.

**Why DRAM on SBC-class chips:** software stacks like CPython on Linux require hundreds of MB for kernel + interpreter + site-packages; on-chip SRAM cannot scale to that capacity at reasonable cost. The SBC variants model an external LPDDR5 controller with a behavioral array and programmable CAS latency (`DRAM_LATENCY`). Production silicon replaces this with a hard DDR PHY.

**Why an SoC, not an MCU (for the SBC/BMC tier):** (1) OS compatibility — NOMMU Linux/seL4 requires an RV32IMAFC-class core with sufficient system RAM; MCU silicon typically lacks both. (2) PCIe Gen5 endpoint termination requires dedicated PHY + controller blocks integrated into SoC silicon. (3) MoE gating evaluation at 10^8–10^9 tokens/s demands clock rates beyond typical MCU envelopes. (4) Source-routed routing tables for 512 nodes plus MoE expert maps exceed MCU on-chip SRAM. The current RTL implements RV32IMA as a proof of concept; production upgrades to RV32IMAFC for NOMMU Linux support.

For source-language transpilation (R/Haskell/HLSL), the main thread runs on the orchestrator chip's CPU: the host compiles source to typed IR and ships it over PCIe, and the orchestrator's firmware lowers it onto the chassis without round-tripping through the host.

### Memory and PCB interconnect models

Two behavioral models close the physical gap between the orchestrator chips and the
rest of the chassis:

- **`lpddr6_camm.v` — LPCAMM2/LPDDR6 memory module** (`tb_dma_lpddr6.v`,
  `tb_sodimm_lpddr.v`). JEDEC LPCAMM2-class behavioral array that speaks the
  same valid/ready CPU bus as the orchestrator chips' DRAM windows. Parameters cover
  CAS-latency wait states, a refresh scheduler that stalls command acceptance
  every REFRESH_CYCLES for REFRESH_BURST cycles, and rd/wr/refresh activity
counters. The same module, re-parameterized, models DDR4/DDR5 SODIMM modules:
  `tb_sodimm_lpddr.v` muxes one protocol stack (Pi → pi_bridge → pnm_arb →
  DMA engine) across LPDDR6 CAMM2 / DDR4 SODIMM / DDR5 SODIMM timing profiles
  and proves identical semantics under each.
- **`pcb_link.v` — PCB trace model** (`tb_pcb_link.v`). A unidirectional link
  modeled as a pure timed wire: shift-register delay of ceil(DELAY_NS/10)
  clock cycles with SOP/EOP/data preserved bit-exactly; DRIVE_MA and
  IMPEDANCE_OH parameters document the electrical envelope. `pcb_triple_link`
  instantiates three of them for the X/Y/spine populations a node fans out to,
  with an aggregate flit counter. Three profiles map onto the paper's PCB
  populations: spine mezzanine (~5 mm), motherboard P2P trace (~40 mm), and
  CAMM2 socket escape (~20 mm).
- **`pcb_si_link.v` — electrical (SI) PCB link** (`tb_pcb_si_link.v`). A
  specific implementation of the `pcb_link` concept that models the channel
  instead of just the delay: length-derived insertion loss (0–14 dB table,
  voltage gain = 10^(-dB/20) in ppm), a single-bounce reflection echo tap
  (REFL_PCT = 100·Γ), per-lane NEXT crosstalk from a shared aggressor bus
  (edge × COUPLE_PCT), PRBS-32 noise (±NOISE_MV uniform approximation),
  rare deterministic-jitter kicks with an event counter, a worst-case eye
  monitor in µV with marginal-sample counting, SKEW_PS timing-budget
  reporting, and hard-decision BER counters checked against the delayed TX
  reference. Framing and the fixed 2-cycle latency match `pcb_link` exactly,
  so it is a drop-in replacement; all arithmetic is integer fixed point.
  `tb_pcb_si_link.v` validates exact physics on five parallel instances:
  loss-table entries and the capped 14 dB long channel, the reflection step
  response to the exact µV (undershoot 320850, settled 392150, echo tap
  35650), byte-exact 20000-word streaming with zero BER while jitter events
  fire, crosstalk closing the eye by exactly the coupled edge (374325 →
  324325 µV) without hard errors but with margin violations counted, and a
  900 mV-noise instance whose errors the detector must catch.
- **`pcie_phy.v` — PCIe Gen5 x16 PHY** (`tb_pcie_phy.v`). Host-side PCIe
  endpoint for SBC-class orchestrator chips. Provides register-level access to
  the SoC CPU through an AXI-Lite register window (ID, CMD, STATUS, staging
  buffer, CPL_DATA FIFO). The LTSSM FSM drives link-up through
  POLL_ACTIVE/CONFIG/RECOVERY states; a DMA engine performs memory-mapped
  read/write (MemWr/MemRd) to host memory with 64-word staging buffer for
  writes and completion-data FIFO for reads. Interrupt support via W1C INT
  register. `tb_pcie_phy.v` validates ID register readback, LTSSM link-up
  timing, CMD/STATUS field access, staging buffer push, MemWr/MemRd DMA
  completion, CPL_DATA round-trip integrity (64 words), W1C interrupt clear,
  insufficient-staging error, CPL FIFO flush, recovery mode on large reads,
  and LANE_STS field access — all 12 tests pass.
- **`nvme_ctrl.v` — NVMe storage controller** (`tb_nvme_ctrl.v`). A lightweight
  NVMe endpoint for SBC-class orchestrator chips providing block storage to the SoC
  firmware: model weight persistence across power cycles, KV cache overflow
  to NVMe-backed swap, Lustre FS object storage backend, and general-purpose
  block I/O. AXI-Lite register window (16 registers at 0x00–0x3C) drives a
  command FSM (READ/WRITE/FLUSH) that moves data over AXI-Stream DMA with
  completion interrupts. `tb_nvme_ctrl.v` validates register reads (CAP,
  version), controller enable, an 8-block READ with exact status, a
  4-block WRITE, FLUSH immediate completion, error on zero NLB, random
  backpressure DMA, and a full 4KB page transfer — all exact-check.
- **`lpddr5_phy.v` / `lpddr5x_phy.v` / `lpddr6_phy.v` — LPDDR generation PHY
  variants** (`tb_lpddr5_phy.v`, `tb_lpddr5x_phy.v`, `tb_lpddr6_phy.v`). Three
  behavioral memory-PHY profiles behind one bus contract (valid → accept →
  CAS wait → rdv): LPDDR5 (4-bank row/bank hierarchy, CL16, tRCD=4, tRP=3,
  tRAS=8, 3.9 µs refresh), LPDDR5X (same structure, tightened to CL14,
  tRCD=3, tRP=2, tRAS=7), and LPDDR6 (flat bank array, CL4). Each carries
  telemetry counters (rd/wr/refresh) so testbenches poll the ready strobe
  instead of assuming fixed delays. Selecting a module class for a board is
  a synthesis-time parameter; MAC arrays, doorbell DMA, and firmware are
  untouched across generations.
- **`rst_sync.v` / `clk_gate.v` — DFT primitives** (`tb_rst_sync.v`,
  `tb_clk_gate.v`). A two-flop reset synchronizer (async assert, sync
  deassert; STAGES parameter) used at every clock-domain boundary, and a
  latch-based glitch-free clock-gating cell whose enable captures on the
  falling edge with an unconditional scan_en bypass for DFT observability.
- **`kv_cache_bank.v` — Per-direction KV cache bank** (verified via co-sim `kvcache=true` path, no dedicated standalone TB).
  On-chip SRAM bank storing Key/Value tensors for autoregressive inference.
  Each physical layer has 4 banks (X+, X-, Y+, Y-). Snoop the NoB link for
  KV_STORE/KV_LOAD opcodes; when full, asserts `kv_full` for the offload
  controller. FIFO eviction at configurable threshold.
- **`kv_offload.v` — KV cache offloading controller** (verified via co-sim; no dedicated standalone TB).
  Manages eviction and reclaim between on-chip banks and host memory via the
  spine fabric. Compile-time `EVICTION_TARGET` parameter selects the
  destination: 0=discard (no persistence), 1=BMC DMA (round-trip over spine),
  2=NVMe (persistent storage via PCIe bridge). Circular LBA region for NVMe
  overflow.
- **`sodimm_ctrl.v` — SODIMM memory controller** (`tb_sodimm_ctrl.v`). Unlike
  the behavioral `lpddr6_camm`, this is a real banked DDR controller: a
  per-bank open-page tracker (open row + tRAS countdown per bank) driving an
  ACT/PRE/CAS micro-FSM (ST_WAIT_RAS → ST_PRE → ST_RCD → ST_CAS), so a row hit
  costs CL, a row miss costs tRCD+CL, and a row conflict costs
tRP+tRCD+CL with tRAS enforced between ACT and PRE. Byte-enable write masking,
  a refresh scheduler that closes all banks and drops `bus_ready` for
  REFRESH_BURST cycles every REFRESH_CYCLES (commands are never silently
dropped), and rd/wr/refresh counters complete the picture. The bus interface
  is pin-compatible with `lpddr6_camm` (same valid/ready contract, byte
  address, ready-down-until-complete), so it drops behind `pnm_arb`
  unchanged. `tb_sodimm_ctrl.v` drives three timing profiles directly on the
  bus — DDR4-like (CL/tRCD/tRP 15, tRAS 38), DDR5-like (36/36/36/44) and a
  short-interval stress unit (refresh every 150 cycles, burst 25) — and checks:
  exact closed-form latencies (cold=32, hit=16, conflict=48 cycles,
  Δ=tRCD+tRP pipeline overhead), tRAS wait insertion under immediate conflict,
  64-word write/readback integrity, partial-byte-write masking, refresh-storm
data integrity with stall accounting, and DDR4-vs-DDR5 latency ordering.
- **`optical_link.v` — optical inter-chassis link** (`tb_optical_link.v`). A
  protocol-transparent fiber PHY between chassis: a dual-clock elastic FIFO
  (gray-coded pointers, 2-FF synchronizers) followed by a PROP_CYCLES-deep
  propagation pipe modeling electrical-to-optical conversion, fiber transit at
  the physical 4.9 ns/m (c/1.468 in glass), and optical-to-electrical
  recovery. Each entry packs `{sop, eop, data}`, so packet framing survives
  the hop bit-exactly and the fabric wire format is unchanged on either side.
  The read domain pops unconditionally whenever the FIFO is non-empty (no
  cross-domain return handshake); all backpressure is write-side: `tx_ready`
  deasserts once gray-synced occupancy reaches
  `READY_LIMIT = FIFO_DEPTH - PROP_CYCLES - 2`, which guarantees no overflow
  for any ready-respecting producer, and a protocol violation sets a sticky
  `overflow_err`. Word and packet counters instrument both directions.
  `optical_pair` composes two links into one bidirectional
  chassis-to-chassis port with an aggregate packet counter. With the default
  2 m span the PHY budgets 1 + 9.8 + 1 ns, i.e. PROP_CYCLES = 2 at 100 MHz,
  and the measured idle-link latency is PROP_CYCLES + 5 cycles (FIFO sync
  visibility plus the output register).
- **`power_rails.v` — power model + rail validation** (`tb_power_rails.v`).
  Cycle-accurate energy-per-event accounting rather than analog simulation:
  a `power_node` accumulates pJ per cycle from activity knobs (`mac_en`,
  `dram_rd`, `dram_wr`, `link_act`) against measured constants (87 nJ/MAC,
  40/30 nJ per LPDDR6 read/write, 8 nJ DRAM background, 9.5 nJ/link),
  splits the draw across the paper's three rails (0.8 V core, 1.2 V I/O,
  1.1 V LPDDR6 PHY), and derives per-rail current, IR droop, undervoltage
  lockout, and a 64-bit energy integral. `chassis_power` rolls up 512 nodes
  plus spine/router overhead, divides by 92% conversion efficiency, adds
  600 W thermal/cooling overhead, and compares against the 10 kW budget.
  The testbench validates exact draws: **1.15 W idle, 14.8 W active** per
  node (the paper's ~15 W claim), **8.93 kW wall at full chassis load**
  (inside the paper's 8–10 kW band), 1.33 kW idle-chassis wall, an exact
  11.5 mJ energy integral over 1000 idle cycles, and the brownout detector
  via a deliberately bad PDN instance (rail clamps to 0 V and flags).
  Full-load droop stays within spec only if the power distribution network
  keeps rail impedance at or below 4/20/5 mΩ (core/I/O/DRAM) — the model's
  falsifiable PDN requirement; nominal params hold every rail above its
  90% UVLO threshold under worst-case simultaneous activity.

Host↔BMC↔memory path verification: `tb_host_bmc.v` drives the SPI host through
`pi_bridge` + `pnm_arb` into the shared PNM register file and observes a flit
injected onto the spine plus boot-done/dispatch-counter readback.
`tb_dma_lpddr6.v` extends the register window with a DMA engine
(DMA_ADDR@0x40, DMA_COUNT@0x44, DMA_CTRL@0x48, DMA_DATA FIFO@0x4C) and moves a
4-word payload host→LPDDR6→host with byte-exact verification.

### Inter-chassis optical layer

The paper closes by naming what multi-chassis scale-out still needs: a second
routing level joining replicated 64TB chassis, plus one additional
virtual-channel class beyond the four monotonic intra-chassis classes that make
the dependency graph acyclic. `optical_link.v` is the physical realization of
that extension point. Cross-chassis traffic leaves through the spine root as
ordinary flits: the orchestrator chip terminates the (future) scale-out class on one
half of an `optical_pair`, and the peer chassis' router re-validates and
re-injects the stream into its own spine, so each chassis keeps its
deterministic internal closed form and no runtime coherence protocol enters
the stack. Because the link moves an uninterpreted byte pipe with SOP/EOP
delimiters, the fabric wire format (LAYER_ID | MODULE_ID | CTRL | LEN |
payload | CRC-16) crosses the fiber untouched; chassis addressing extends the
existing source-routed header (a chassis selector riding the CTRL byte's four
reserved bits, or a selector word ahead of SOP), a wire-format decision the
second-level router specification settles.

Design notes:

- **Clocking**: the two chassis are electrically and clock-wise independent;
  the link's gray-coded asynchronous FIFO absorbs the rate difference (the
  testbench exercises exactly this at 100 MHz ↔ 80 MHz). The unconditional
  read-side pop keeps the return path out of the crossing domain entirely.
- **Latency budget**: E/O conversion + fiber propagation (4.9 ns/m) + O/E
  recovery, quantized up to whole 100 MHz cycles (PROP_CYCLES), plus roughly
  five more cycles of FIFO synchronization and output register on the receive
  side. For the default 2 m board-to-board span that is ~70 ns end to end —
  about one spine hop of intra-chassis wire delay per meter of fiber, so a
  multi-chassis rack adds single-digit hop-equivalents of latency.
- **Flow control**: occupancy-threshold `tx_ready` on the transmitting edge
  router substitutes for credit-based flow control across the fiber; the
  READY_LIMIT headroom (FIFO depth minus propagation pipeline minus guard)
  makes drop-free operation structural rather than probabilistic.
- **Error containment**: the doorbell CRC-16 already covers everything after
  LAYER_ID and is verified at final ejection; because an optical hop adds
  serialization error sources mid-fabric, the receiving edge router re-runs
  the same CRC check on arrival (the `crc16.v` engine is shared) and refuses
  corrupt frames exactly like a node doorbell would, keeping silent corruption
  from propagating into a second chassis.

### Firmware tooling

Two toolchains target the chip family:

- **MCU** (`toolchain/mcu/`): bare-metal static firmware. Cross-compiles to flat binary for ROM burn-in via riscv-none-elf-gcc. Linker script places .text/.rodata in ROM and .data/.bss in SRAM with startup copy/zero code. No libc, no malloc, no OS.
- **SoC** (`toolchain/soc/`): NOMMU Linux/seL4 userspace daemon. Statically linked against musl-libc, accesses PNM registers via `/dev/pnm` mmap. Uses dynamic allocation (DRAM-backed heap). Entry point placed at DRAM offset 0x1000 by boot loader.
- **SoC Linux** (`toolchain/soc-linux/`): full OS image builder for `orchestrator_sbc`. Downloads, configures, and compiles a stripped RV32IMA NOMMU Linux kernel (6.6.x, no MMU/FPU/modules, 16550 UART + NVMe stub only), clones and builds seL4 microkernel (CMake cross-compile for riscv32), cross-compiles the `rustd` access-control daemon (Rust, no dependencies, bare-metal + NOMMU dual entry points), and packs an initramfs rootfs. The Rust daemon provides SHA-256/HMAC/PBKDF2 authentication, 32-user role-based access control, 64-job workload management, and configurable KV cache eviction routing (discard / BMC DMA / NVMe). Outputs land in a gitignored `build/` directory: flat kernel `Image`, seL4 ELF, `rustd`, and `initramfs.cpio`. Boot flow: ROM → SPL → kernel at DRAM 0x80000000 → `/init` → `rustd` mmaps `/dev/pnm` (0xF0000000) and starts dispatch.
- **fw-linux** (`toolchain/fw-linux/`): Linux tinyconfig + bare-metal init for `orchestrator_sbc`. Kernel config fragment (NOMMU, RV32I, no FPU) trims the kernel to fit in the 16 MB SRAM window (`0x4000_0000`). Produces `Image`, `init` binary, and `initrd.cpio` initramfs. The init binary prints a boot banner over UART@`0x10000000` (115200 8N1), probes the NVMe controller at `0xD0000000` (reads CAP, VS, CSTS), and enters a `wfi` idle loop. UART/PNM drivers are local; the NVMe driver is shared from `fw/pnm_nvme.c`.
- **fw-sel4** (`toolchain/fw-sel4/`): seL4 microkernel root task for `orchestrator_sbc`. CMake-based build for RV32IMA generic platform. The root task maps UART@`0x10000000` and PNM@`0xF0000000` device frames via seL4 capabilities, prints a boot banner, reads PNM STATUS to confirm the orchestrator chip is alive, and enters a `seL4_Yield` idle loop. seL4 provides formal verification, capability-based access control, and temporal isolation — a hardened alternative to Linux for the orchestrator chip's control plane.
- **Pi host** (`pi_host/`): Raspberry Pi Compute Module drivers that reach the orchestrator PNM register window from a Pi: through the `HDL/pi_bridge.v` SPI slave (CM0-CM4 GPIO SPI) or directly via PCIe BAR0 (CM5). The same 48-bit frame protocol is implemented five times for maximum compatibility — Python (`pnm_pi.py`, spidev), Go (`pnm_pi.go`, stdlib-only raw ioctl), Rust (`pnm_pi.rs`, zero crates), C (`pnm_pi_spi.c`, raw ioctl), and C-over-PCIe (`pnm_pi_cm5.c`, sysfs BAR0 mmap). Frame: header byte `{rw<<7|sel}`, 32-bit data, status byte (0x01 write-ack / 0x00 read-ok); sel 0-9 map to PNM offsets 0x00-0x24.

### NVMe storage and Lustre filesystem

The orchestrator chip's firmware gains block-level persistence through two
complementary layers:

- **NVMe driver** (`fw/pnm_nvme.{h,c}`, Go twin
  `sim/internal/pnm/nvme_lustre.go`): register-level driver for
  `HDL/nvme_ctrl.v`. Probes CAP, sets CSTS.ready, then submits READ/WRITE/
  FLUSH commands through the AXI-Lite window with poll-for-done completion.
  Used for model weight save/load across power cycles and KV cache overflow
  pages.
- **Lustre client** (`fw/pnm_lustre.{h,c}`): a minimal Lustre OSS
  endpoint that splits the NVMe device into up to 16 object storage targets
  and stripes files round-robin across them with configurable stripe count
  (1–8) and stripe size (up to 1 MB). Each router node acts as both a Lustre
  OSS target and a PNM compute node; object IDs are allocated sequentially
  per file so the striping layout is deterministic and verifiable from the
  Go harness (`LustreClient.Create/Write/Read/Sync` mirror the C API).
  Production deployments run a real Lustre client on the NOMMU kernel;
  this module handles the firmware-side layout decisions that must match.

### Testbenches

All testbenches are self-checking (scoreboard counters, `errors` integers, $display PASS/FAIL).

| Testbench | Tests | Expected Output |
|-----------|-------|-----------------|
| `tb_fabric.v` | Spine, board, up-spine routing | `*** ALL TESTS PASSED ***` |
| `tb_load.v` | 500 packets, backpressure, checksums | `*** LOAD TEST PASSED (500 packets) ***` |
| `tb_doorbell.v` | 8 packets: 6 activations, 2 refusals, 2 corrupt_out | `*** DOORBELL TEST PASSED ***` |
| `tb_fp16_fma.v` | FP16 FMA 3-cycle pipeline | `*** FP16 FMA TEST PASSED ***` |
| `tb_bf16_fma.v` | BF16 FMA 3-cycle pipeline | `*** BF16 FMA TEST PASSED ***` |
| `tb_fp32_fma.v` | FP32 FMA 3-cycle pipeline | `*** FP32 FMA TEST PASSED ***` |
| `tb_fp64_fma.v` | FP64 FMA 3-cycle pipeline | `*** FP64 FMA TEST PASSED ***` |
| `tb_fp32_alu.v` | FP32 ALU division, MIN/MAX/CMP | `*** FP32 ALU TEST PASSED ***` |
| `tb_int8_mac.v` | INT8 2-cycle MAC | `*** INT8 MAC TEST PASSED ***` |
| `tb_fp16_mac_array.v` | FP16 systolic array | `*** FP16 MAC ARRAY TEST PASSED ***` |
| `tb_bf16_mac_array.v` | BF16 systolic array | `*** BF16 MAC ARRAY TEST PASSED ***` |
| `tb_moe_gating.v` | MoE softmax top-k | `*** MoE GATING TEST PASSED ***` |
| `tb_orchestrator_chip.v` | Router chip boot + dispatch | `*** ROUTER CHIP TEST PASSED ***` |
| `tb_bmc_orchestrator.v` | BMC/Orchestrator SoC: UART, PNM regs, boot_done | `*** BMC ROUTER CHIP TEST PASSED ***` |
| `tb_orchestrator_mcu.v` | MCU router: flit injection wire format | `*** MCU ROUTER CHIP TEST PASSED ***` |
| `tb_orchestrator_sbc.v` | SBC router: SRAM read-back, DRAM stub, PCIe PHY probe, NVMe register read, flit injection, boot_done | `*** SBC ROUTER CHIP TEST PASSED ***` |
| `tb_orchestrator_sbc_moe.v` | SBC+MoE router: gating SRAM write, flit injection | `*** SBC+MOE ROUTER CHIP TEST PASSED ***` |
| `tb_pi_bridge.v` | SPI-to-PNM bridge: register writes, read-back, status bytes | `*** PI BRIDGE TEST PASSED ***` |
| `tb_host_bmc.v` | Host↔BMC: SPI writes, flit injection, boot-done, dispatch readback | `*** HOST BMC COMM TEST PASSED ***` |
| `tb_dma_lpddr6.v` | Host DMA to LPCAMM2/LPDDR6: FIFO load, write, verify, read back | `*** DMA LPDDR6 TEST PASSED ***` |
| `tb_sodimm_lpddr.v` | Same DMA path across DDR4/DDR5 SODIMM + LPDDR6 CAMM2 timings | `*** SODIMM LPDDR TEST PASSED ***` |
| `tb_pcb_link.v` | PCB links: passthrough, exact delay, 200-packet stream, triple-link counter | `*** PCB LINK TEST PASSED ***` |
| `tb_sodimm_ctrl.v` | Banked DDR controller: row miss/hit/conflict latencies, tRAS enforcement, BE masking, refresh storm, DDR4 vs DDR5 sweep | `*** SODIMM CTRL TEST PASSED ***` |
| `tb_optical_link.v` | Optical links: idle latency (PROP_CYCLES+5), 200-word burst SOP/EOP alignment, 600-word flood zero loss, sparse gapped packets, async 100→80 MHz CDC with ready deassertion, bidirectional pair | `*** OPTICAL LINK TEST PASSED ***` |
| `tb_power_rails.v` | Power model: idle/active/wr-only draws, three-rail IR droop + UVLO margins, exact 11.5 mJ energy integral, brownout clamp on a bad-PDN instance, 512-node chassis wall (8.93 kW active / 1.33 kW idle), budget flag both polarities | `*** POWER RAILS TEST PASSED ***` |
| `tb_pcb_si_link.v` | Electrical link: loss table + 14 dB cap, exact-µV reflection step response, 20000-word zero-BER stream with live jitter/eye monitors, crosstalk eye closure (exact −50 mV kick), noisy-link error detection | `*** PCB SI LINK TEST PASSED ***` |
| `tb_nvme_ctrl.v` | NVMe controller: CAP/VS reads, enable, 8-block READ, 4-block WRITE, FLUSH, zero-NLB error, random backpressure DMA, 4KB transfer | `*** NVME CTRL TEST PASSED ***` |
| `tb_pcie_phy.v` | PCIe Gen5 PHY: ID reg, LTSSM link-up, CMD/STS, staging buf, MemWr/MemRd DMA, CPL round-trip, W1C, error, flush, recovery, LANE_STS (12 tests) | `*** PCIE PHY TEST PASSED ***` |
| `tb_lpddr5_phy.v` | LPDDR5 PHY: write/read basic, multi-address, telemetry, sideband | `*** LPDDR5 PHY TEST PASSED ***` |
| `tb_lpddr5x_phy.v` | LPDDR5X PHY: write/read basic, multi-address, telemetry | `*** LPDDR5X PHY TEST PASSED ***` |
| `tb_lpddr6_phy.v` | LPDDR6 PHY: write/read basic, multi-address, telemetry | `*** LPDDR6 PHY TEST PASSED ***` |
| `tb_rst_sync.v` | Reset synchronizer: async assert immediate, 2-cycle sync deassert, re-release recovery | `*** RST_SYNC TEST PASSED ***` |
| `tb_clk_gate.v` | Clock gate: off/on gating, glitch-free enable capture on falling edge, scan_en bypass | `*** CLK_GATE TEST PASSED ***` |

## Co-Simulation Harness (sim/)

### Architecture

The harness is a Go standard-library-only program that:
1. Generates stimulus (manifest: dest, kernel, weights, bias, payload, CRC, golden)
2. Generates Verilog topology (`pnm_top.v`) and testbench (`tb_pnm.v`)
3. Compiles Verilog slices in parallel `iverilog` processes
4. Runs them in parallel `vvp` processes
5. Verifies hardware results against the golden model

### Key Components

#### Core Types (`run.go`)

- `NodeID` - Physical coordinate: `{L, X, Y}`
- `Dims` - Chassis dimensions: `{Layers, Bx, By}`
- `StreamByte` - Wire byte with SOP/EOP/VC sideband
- `Flit(layer, dest, ctrl, payload, echo)` - Constructs wire-format flits
- VC class constants: `VC_BOARD_EGRESS=0`, `VC_SPINE_ASCENT=1`, `VC_SPINE_DESCENT=2`, `VC_ONBOARD_DELIVER=3`

#### Topology Generator (`gen_topology.go`)

Generates `pnm_top.v` from chassis dimensions. Each node gets:
- An `lxy_repeater` with a route bitmap parameter
- A `pe_tile_stub` with compute unit type and bias constant
- DMA ports for injection and delivery

#### Testbench Generator (`gen_tb.go`)

Generates `tb_pnm.v` for parallel vvp slices. Features:
- Injector task from `stimulus.hex` via $readmemh
- Per-node backpressure (ready 1 cycle in N)
- Delivery.log via $fwrite (including C verdict lines for stubs)
- Adaptive $finish after 200 quiet cycles

#### Virtual Execution Units (`virtual_units.go`)

`VirtualUnit.Consume()` implements the Go-side doorbell twin:
- Three-condition fire: byte count == LEN+6, CRC validates, DEST == LOCAL_MODULE
- Resident kernels: `echo`, `sum`, `accum`, `dot`
- Results checked against golden manifest

#### Discrete Event Simulator (`des.go`)

Activity-driven DES of the egress merge tree:
- Pipeline registers (HFRs, PE MAC pipes) separated by combinational gate clouds
- Three merge kinds: `mkYm` (Y-up), `mkXm` (X-up), `mkUp` (repeater upmerge)
- Cross-checks against RTL via `CrossCheckDES()`
- Shares no code with Verilog; reproduces delivery stream byte-for-byte

#### Model Compiler (`model_compiler.go`)

Five-stage AOT pipeline that transpiles HuggingFace models onto PNM chassis:

1. **Ingest** - Parse safetensors index + config.json, infer tensor shapes from ~20 naming patterns
2. **Partition** - Layer-to-physical mapping, expert round-robin, dense assignment, embedding sharding, KV cache reservation (80% of the post-weight budget, max 16K entries)
3. **Map** - Assign operations to kernel names and compute unit types by tensor role
4. **Route** - Compute 11-bit routing bitmaps and MoE expert map
5. **Emit** - Write .pnm program file and chassis schema

Key structs: `ModelCompiler`, `NodeAssignment`, `ComputeUnitType` (15 types), `TensorRef`

#### Safetensors Parser (`safetensors.go`)

Parses HuggingFace model format:
- `LoadSafetensorsIndex(dir)` - Parse weight_map from index JSON
- `LoadModelConfig(dir)` - Parse nested TextConfig
- `TensorShapeFor(name, cfg)` - Infer shapes from ~20 tensor name patterns
- `CollectTensors(idx, cfg)` - Merge index + config into full catalog

#### Host Driver (`driver.go`)

Orchestrates model loading and inference:
- `BuildWeightCommands()` - Deterministic weight upload sequence sorted L-X-Y
- `computeRouteBitmaps()` - Generate 11-bit routing bitmaps per node
- `computeMoeMap()` - Build expert-to-coordinate mapping

#### Firmware (`firmware.go`)

Models the central orchestrator chip:
- 5-phase boot: RESET -> POST_DISCOVERY -> ROUTING_TABLE -> WEIGHT_UPLOAD -> MOE_LOAD -> READY
- `PlanInference(token)` - Per-token dispatch: dense attention -> KV cache check -> MoE gating -> expert dispatch
- `VerifyWeightUpload(cmds)` / `VerifyDispatch(records)` - Runtime verification

#### LLM Client (`llm_client.go`)

End-to-end autoregressive inference:
- Tokenization (real BPE via `tokenizer.json` when present, else synthetic)
- Prefill + autoregressive generation
- Temperature/nucleus (top-p) sampling with numerical stability
- Per-inference statistics (tokens, dispatches, KV ops, CU utilization)

#### KV Cache (`kv_cache.go`)

Distributed KV cache with per-direction banks:
- 4 directional banks (X+, X-, Y+, Y-) per physical layer
- FIFO eviction at 80% capacity threshold
- Configurable eviction target (`EvictionMode`):
  - `EvictNone` — discard evicted entries (default, lossy)
  - `EvictDmaBmc` — DMA evicted entries to host BMC over spine (~500ns RTT)
  - `EvictNvme` — write evicted entries to NVMe via PCIe (persistent, high BW)
- Circular NVMe overflow region with configurable LBA range
- `EvictionStats` tracking: discard/DMA/NVMe write counts, bytes, errors

#### Deterministic RNG (`rng.go`)

Byte-exact clone of CPython's `random.Random`:
- MT19937 Mersenne Twister implementation
- Verified against CPython known outputs (`rng_test.go`)
- Same `--seed` reproduces identical stimulus across runs

#### Source Language Toolchains

| Compiler | Input | Output | Target CU |
|----------|-------|--------|-----------|
| `r_ir.go` | R (assignments, arithmetic, aggregations) | FP64 register-based IR | `fp64_fma` |
| `haskell_ir.go` | Haskell (functions, guards, do blocks) | FP64 register-based IR | `fp64_fma` |
| `hlsl_ir.go` | HLSL (float declarations, intrinsics) | FP32 ALU IR | `fp32_alu` |

IR is deliberately minimal: no loops, no branches, no dynamic allocation. Complex control flow is lowered to straight-line IR with explicit data dependencies.

### Scenarios

| Scenario | Description | What it checks |
|----------|-------------|----------------|
| `sweep` | One flit to every node | Exact closed-form latency |
| `vcsweep` | Sweep + pass-through on all 4 VC classes | Arbitrated egress tree adds no delay |
| `load` | 500 random flits with 100/50/25% backpressure | Lossless delivery with slow consumers |
| `hotspot` | MoE hot-expert traffic on corner node | No drops under concentrated load |
| `stress` | ~24 flits/node, ~3% corrupt CRC | Doorbell refuses all corrupt messages |
| `replay` | Stress twice, bit-identical logs | Deterministic replay (no hidden state) |

### CLI Tools

#### `cmd/pnm` - Co-Simulation Harness

```bash
go run ./cmd/pnm                         # 3x4x4 = 48 nodes, all 6 scenarios
go run ./cmd/pnm -l 8 -x 8 -y 8          # 512-node reference chassis
go run ./cmd/pnm --scenarios sweep stress --seed 1
go run ./cmd/pnm --groups 8              # force 8 parallel vvp slices
go run ./cmd/pnm --cpuprofile /tmp/pnm.cpu --memprofile /tmp/pnm.mem
```

#### `cmd/pnmc` - Program Compiler + Model Compiler + Driver

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

#### Compiler performance (512-node Gemma-4 reference chassis)

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

### .pnm Program Format

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

## C Firmware Port (fw/)

Direct C port of `firmware.go` for MCU targets (ARM Cortex-M/R, RISC-V).

### Key Features
- Static allocation only: no `malloc`, no dynamic memory, no OS dependency
- All buffers statically sized with `#define` constants
- Same 5-phase boot sequence and dispatch loop as Go firmware

### Key Constants
- `PNM_MAX_LAYERS=8`, `PNM_MAX_NODES=64`, `PNM_MAX_NODES_TOTAL=512`
- `PNM_MAX_EXPERTS=256`, `PNM_MAX_TOPK=16`, `PNM_MAX_MODEL_LAYERS=128`
- `PNM_KV_CACHE_DEPTH=4096`, `PNM_ROUTING_TABLE_SIZE=256`

### Files
- `pnm_fw.h` - Types, API, and constants
- `pnm_fw.c` - Boot sequence, dispatch loop, KV cache, verification

## Wire Format

Every fabric link carries byte-wide flits:

```
Byte 0: LAYER_ID            (stripped by lxy_repeater on match)
Byte 1: MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
Byte 2: CTRL = {vc_class[7:6], op[5:4], rsvd[3:0]}
Byte 3: LEN_LO
Byte 4: LEN_HI
Byte 5+: payload (LEN bytes)
Last 2: CRC_HI, CRC_LO
```

CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021) covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload].

## Build Commands

### Paper
```bash
python3 build.py            # submission/paper.docx + .pdf + .tex
python3 build.py --review   # submission/paper_review.pdf (11pt single-column)
```

### HDL Testbenches
```bash
cd HDL
iverilog -g2005 -o tb_fabric.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
iverilog -g2005 -o tb_load.out   hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v   && vvp tb_load.out
iverilog -g2005 -o tb_doorbell.out core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v && vvp tb_doorbell.out
# ... (see AGENTS.md for complete list)
```

### Static Lint
```bash
verilator --lint-only -Wno-MULTITOP hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v
```

### C Firmware
```bash
cd fw && gcc -Wall -Wextra -std=c11 -c pnm_fw.c -o pnm_fw.o
```

### Co-Simulation
```bash
cd sim && go test ./internal/pnm/
```
