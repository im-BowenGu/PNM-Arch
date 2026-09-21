# fw-linux — Linux tinyconfig + bare-metal init for orchestrator_sbc

Produces a minimal bootable Linux image for the `orchestrator_sbc` chip family.
The trimmed kernel fits in the 16 MB on-chip SRAM window (`0x4000_0000`);
bulk data (model weights, KV cache) stays in LPDDR5 DRAM.

## Outputs (`build/`)

| Artifact | Description |
|----------|-------------|
| `Image` | NOMMU RISC-V flat kernel (tinyconfig + PNM fragment) |
| `vmlinux.bin` | Stripped flat binary for direct SRAM load |
| `init` | Static freestanding init binary (prints banner, probes NVMe) |
| `initrd.cpio` | initramfs containing `init` |

## Prerequisites

- `riscv64-unknown-linux-musl-gcc` cross compiler (available in `flake.nix`)
- Linux source tree (6.6.x) at `linux/` or set `KERNEL_DIR`

## Usage

```bash
# Full build (init + kernel + initramfs)
make all

# Init binary only (local gcc, compile check)
make check

# Kernel only (requires Linux source tree at linux/)
make image

# Create initramfs
make initrd

make clean
```

## Boot flow on orchestrator_sbc

1. Boot ROM (64 KB) loads SPL from NVMe block 0.
2. SPL initializes LPDDR5, copies `Image` to DRAM at `0x8000_0000`.
3. SPL loads `initrd.cpio` alongside the kernel.
4. Kernel boots NOMMU, mounts initramfs as rootfs.
5. `/init` runs the bare-metal init binary, which:
   - Prints banner over UART@`0x10000000` (115200 8N1)
   - Reads PNM STATUS at `0xF0000000` (confirms `boot_done`)
   - Probes NVMe controller at `0xD0000000` (CAP, VS, CSTS)
   - Enters `wfi` idle loop

## Memory map

| Region | Address | Size | Notes |
|--------|---------|------|-------|
| Boot ROM | `0x0000_0000` | 64 KB | SPL + reset vector |
| UART | `0x1000_0000` | 4 KB | 16550-compatible |
| SRAM | `0x4000_0000` | 16 MB | Kernel image + stack |
| DRAM | `0x8000_0000` | 1 GB | LPDDR5, heap + data |
| NVMe | `0xD000_0000` | 64 B | AXI-Lite register window |
| PNM | `0xF000_0000` | 64 B | Router chip register window |

## Source layout

```
src/
  init.c          Main entry point (banner + NVMe probe + wfi)
  drv_uart.h/.c   16550 UART driver (register-level)
  drv_pnm.h/.c    PNM register window accessors
  drv_nvme.h      NVMe re-exports (wraps pnm_nvme.h)
configs/
  pnm_tiny.config Kernel config fragment (NOMMU, 32I, no FPU)
```

The NVMe driver itself is `fw/pnm_nvme.c` (shared with MCU/SoC
toolchains), compiled and linked by the Makefile.
