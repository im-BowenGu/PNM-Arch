# fw-sel4 — seL4 microkernel root task for router_sbc

Builds a minimal seL4 root task for the `router_sbc` chip family.
seL4 is a formally-verified microkernel providing capability-based
access control and temporal isolation — a hardened alternative to
Linux for the router chip's control plane.

## Outputs (`build/`)

| Artifact | Description |
|----------|-------------|
| `kernel/` | seL4 kernel ELF for RV32IMA generic platform |
| `root_task/` | Root task ELF (maps UART + PNM, prints banner, idle) |

## Prerequisites

- CMake >= 3.18
- `riscv32-unknown-elf-gcc` cross compiler (available in `shell.nix`)
- seL4 source tree at `sel4/` or set `SEL4_DIR`

## Usage

```bash
# Full build (kernel + root task)
make

# seL4 kernel only
make kernel

# Root task only (requires kernel build first)
make root-task

make clean
```

## Boot flow on router_sbc

1. Boot ROM (64 KB) loads SPL from NVMe block 0.
2. SPL initializes LPDDR5, loads seL4 kernel into DRAM at `0x8000_0000`.
3. SPL jumps to seL4 kernel entry.
4. seL4 initializes capability space, maps device frames.
5. Root task starts:
   - Extracts untyped caps from boot info
   - Maps UART@`0x10000000` via device frame cap
   - Maps PNM@`0xF0000000` via device frame cap
   - Prints boot banner
   - Reads PNM STATUS (confirms `boot_done`)
   - Enters `seL4_Yield` idle loop

## Why seL4?

| Property | Benefit |
|----------|---------|
| Formal verification | Mathematically proven functional correctness |
| Capability-based access | Fine-grained DAC; each device mapped via untyped cap |
| Temporal isolation | Bounded execution time per thread; no priority inversion |
| Minimal TCB | ~10KLoC kernel vs Linux's ~30MLoC; fits in SRAM |
| Static allocation | No heap fragmentation; deterministic memory usage |

## Source layout

```
src/root_task/
  main.c           Root task entry point (UART + PNM mapping, banner, idle)
  CMakeLists.txt   Root task build configuration
Makefile           Top-level build orchestration
```

## Memory map

Same as fw-linux — see that README for the full SoC memory map.
seL4 manages its own page tables; the root task maps device frames
through capability delegation, not direct physical access.
