#!/bin/sh
# =============================================================================
# soc-linux.sh — one-shot builder for the PNM router_sbc OS image
#
# Downloads, configures, and builds:
#   1. Stripped RV32IMA NOMMU Linux kernel (6.6.x)
#   2. seL4 microkernel (alternative to Linux, needs Rust toolchain)
#   3. pnm_socd control daemon (statically linked musl, C)
#   4. pnm_rustd Rust daemon (access control, workload management)
#   5. Initramfs rootfs with both daemons as /init and service
#
# Usage:
#   ./soc-linux.sh              # everything
#   ./soc-linux.sh linux        # just the kernel
#   ./soc-linux.sh sel4        # just seL4
#   ./soc-linux.sh daemon      # just the C control daemon
#   ./soc-linux.sh rustd       # just the Rust daemon
#   ./soc-linux.sh initramfs   # just pack the rootfs
#
# Output goes to build/ (gitignored).
# =============================================================================

set -e
cd "$(dirname "$0")"

TARGET="${1:-all}"

run_make() {
    if command -v make >/dev/null 2>&1; then
        make "$@"
    else
        echo "ERROR: make not found" >&2
        exit 1
    fi
}

check_cross() {
    if ! command -v riscv64-unknown-linux-musl-gcc >/dev/null 2>&1; then
        echo "WARNING: riscv64-unknown-linux-musl-gcc not in PATH" >&2
        echo "  Install riscv-tools or use nix-shell." >&2
    fi
}

case "$TARGET" in
    all)
        check_cross
        run_make linux sel4 daemon rustd initramfs
        ;;
    linux)
        check_cross
        run_make linux
        ;;
    sel4)
        run_make sel4
        ;;
    daemon)
        check_cross
        run_make daemon
        ;;
    rustd)
        run_make rustd
        ;;
    initramfs)
        run_make initramfs
        ;;
    clean)
        run_make clean
        ;;
    *)
        echo "Usage: $0 [all|linux|sel4|daemon|rustd|initramfs|clean]"
        exit 1
        ;;
esac

echo "Build complete. Artifacts in build/:"
ls -la build/Image build/sel4-kernel build/pnm_socd build/pnm_rustd build/initramfs.cpio 2>/dev/null || true
