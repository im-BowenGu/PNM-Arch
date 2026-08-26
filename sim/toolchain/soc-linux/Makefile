# =============================================================================
# SoC Linux/seL4 toolchain — builds bootable RISC-V images for router_sbc
#
# Produces in build/:
#   Image          — stripped RV32 NOMMU Linux kernel (flat binary)
#   sel4-kernel    — seL4 microkernel ELF (alternative to Linux)
#   initramfs.cpio — minimal rootfs with pnm_socd + pnm_rustd
#   pnm_socd       — PNM C control daemon (statically linked musl)
#   pnm_rustd      — PNM Rust daemon (access control, workload mgmt)
#
# All artifacts land in build/ which is gitignored.
#
# Prerequisites (available in nix-shell):
#   riscv64-unknown-linux-musl-gcc  (cross compiler)
#   rustup + riscv32-unknown-none-elf target (for seL4 / Rust daemon)
#   bc, flex, bison                 (kernel build deps)
#
# Usage:
#   make linux       # download + configure + build Linux NOMMU kernel
#   make sel4       # clone + build seL4 microkernel
#   make daemon     # cross-compile pnm_socd (C)
#   make rustd      # cross-compile pnm_rustd (Rust)
#   make initramfs  # pack rootfs cpio archive
#   make all        # everything
#   make clean      # rm -rf build/
# =============================================================================

ARCH     := riscv
CROSS    ?= riscv64-unknown-linux-musl-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
STRIP    := $(CROSS)strip

BUILD    := build
KERNEL   := $(BUILD)/linux-6.6
SEL4DIR  := $(BUILD)/seL4
INITRAMFS := $(BUILD)/initramfs
OUT      := $(BUILD)

LINUX_VER := 6.6.30
LINUX_URL := https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(LINUX_VER).tar.xz
LINUX_TAR := $(BUILD)/linux-$(LINUX_VER).tar.xz

SEL4_URL  := https://github.com/seL4/seL4.git
RUST_TOOL := riscv32-unknown-none-elf

JOBS := $(shell nproc)

.PHONY: all clean linux sel4 daemon rustd initramfs config-linux

all: linux sel4 daemon rustd initramfs

# ── Linux kernel ─────────────────────────────────────────────────────

$(LINUX_TAR):
	mkdir -p $(BUILD)
	wget -q -O $@ $(LINUX_URL)

$(KERNEL): $(LINUX_TAR)
	tar xf $< -C $(BUILD)

config-linux: $(KERNEL)
	$(MAKE) -C $(KERNEL) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) \
	        defconfig
	# Strip down: NOMMU, no MMU features, minimal drivers, RV32
	scripts/kconfig/merge_config.sh -m $(KERNEL)/.config configs/pnm_rv32ima.config
	$(MAKE) -C $(KERNEL) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) olddefconfig

linux: $(KERNEL) config-linux
	$(MAKE) -C $(KERNEL) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) -j$(JOBS) Image
	$(STRIP) -o $(OUT)/Image $(KERNEL)/arch/riscv/boot/Image
	@echo "Linux kernel: $(OUT)/Image ($(shell stat -c%s $(OUT)/Image) bytes)"

# ── seL4 microkernel ────────────────────────────────────────────────

$(SEL4DIR):
	mkdir -p $(BUILD)
	git clone --depth 1 $(SEL4_URL) $@

sel4: $(SEL4DIR)
	rustup target add $(RUST_TOOL) 2>/dev/null || true
	cd $(SEL4DIR) && \
	mkdir -p build && cd build && \
	cmake -DCROSS_COMPILER_PREFIX=$(CROSS) \
	      -DCMAKE_TOOLCHAIN_FILE=../tools/cmake-toolchains/riscv32.cmake \
	      -DKernelArch=riscv32 -DKernelPlatform=generic \
	      -DCMAKE_BUILD_TYPE=Release .. && \
	$(MAKE) -j$(JOBS)
	$(OBJCOPY) -O binary $(SEL4DIR)/build/kernel.elf $(OUT)/sel4-kernel
	@echo "seL4 kernel: $(OUT)/sel4-kernel"

# ── Control daemon (C, musl) ─────────────────────────────────────────

daemon:
	$(MAKE) -C ../soc clean all
	cp ../soc/pnm_socd $(OUT)/pnm_socd

# ── Rust daemon (access control, workload management) ────────────────

rustd:
	cd rustd && cargo build --release --target $(RUST_TOOL) 2>/dev/null || \
	  (echo "Building Rust daemon (first build downloads crates)..." && \
	   cd rustd && cargo build --release --target $(RUST_TOOL))
	$(STRIP) -o $(OUT)/pnm_rustd rustd/target/$(RUST_TOOL)/release/pnm_rustd
	@echo "Rust daemon: $(OUT)/pnm_rustd"

# ── Initramfs ────────────────────────────────────────────────────────

initramfs: daemon rustd
	rm -rf $(INITRAMFS)
	mkdir -p $(INITRAMFS)/{bin,dev,proc,sys,tmp,etc}
	cp $(OUT)/pnm_socd $(INITRAMFS)/bin/
	cp $(OUT)/pnm_rustd $(INITRAMFS)/bin/
	# Minimal /init script
	echo '#!/bin/pnm_socd' > $(INITRAMFS)/init
	echo 'mount -t proc proc /proc' >> $(INITRAMFS)/init
	echo 'exec /bin/pnm_socd' >> $(INITRAMFS)/init
	chmod +x $(INITRAMFS)/init
	cd $(INITRAMFS) && find . | cpio -o -H newc > ../$(notdir $(INITRAMFS)).cpio
	@echo "Initramfs: $(OUT)/initramfs.cpio"

clean:
	rm -rf $(BUILD)
