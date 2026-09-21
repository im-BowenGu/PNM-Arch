# SoC Linux/seL4 toolchain

Builds bootable RISC-V OS images for the `orchestrator_sbc` / `orchestrator_sbc_moe`
chips. The router's LPDDR5 DRAM window (512MB–1GB) is sized for a
NOMMU kernel plus CPython userland; this directory produces the actual
kernel binary, control daemon, and root filesystem to load into it.

## Layout

| Path | Purpose |
|------|---------|
| `Makefile` | Top-level build orchestration |
| `configs/pnm_rv32ima.config` | Kernel config fragments (NOMMU, no MMU, no FPU) |
| `soc-linux.sh` | One-shot build script |
| `build/` | **Gitignored** output directory |

## Outputs (`build/`)

| Artifact | Description |
|----------|-------------|
| `Image` | Stripped RV32 NOMMU Linux flat kernel |
| `sel4-kernel` | seL4 microkernel ELF (alternative to Linux) |
| `pnm_rustd` | PNM Rust daemon (access control, workload management) |
| `pnm_socd` | PNM control daemon (statically linked musl-libc) |
| `initramfs.cpio` | Minimal rootfs with `/init` that execs `pnm_socd` |

## Prerequisites

- `riscv64-unknown-linux-musl-gcc` cross compiler
- `bc`, `flex`, `bison` for the kernel build
- Rust stable (no external crates) with `riscv32-unknown-none-elf` target for seL4 / rustd
- All available in the repo's `flake.nix` (`nix develop`)

## Usage

```bash
./soc-linux.sh              # everything
./soc-linux.sh linux        # kernel only
./soc-linux.sh sel4        # seL4 only
./soc-linux.sh clean       # remove build/
```

## Boot flow on real silicon

1. Boot ROM (64KB in `orchestrator_sbc.v`) loads SPL from NVMe block 0.
2. SPL initializes LPDDR5 and copies `Image` into DRAM at 0x80000000.
3. SPL loads `initramfs.cpio` alongside the kernel.
4. Kernel boots NOMMU, mounts initramfs as rootfs.
5. `/init` runs `/bin/pnm_socd`, which mmaps `/dev/pnm` (the 0xF0000000
   register window) and starts dispatching PNM workloads.

## NVMe integration

The kernel config enables `CONFIG_BLK_DEV_NVME` mapped to the
`nvme_ctrl.v` register window at physical address 0xD0000000. The
`pnm_lustre` firmware module provides Lustre OSS striping over the same
device, so model weights persist across power cycles and KV cache
overflow lands on NVMe-backed swap.
