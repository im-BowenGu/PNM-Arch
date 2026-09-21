# fw-linux — Linux tinyconfig image + basic drivers for orchestrator_sbc
#
# Produces:
#   build/Image          — NOMMU RISC-V kernel (tinyconfig + PNM fragment)
#   build/init           — static freestanding init binary
#   build/initrd.cpio    — initramfs containing init
#   build/vmlinux.bin    — flat binary kernel for direct SRAM load
#
# The trimmed kernel is sized to execute from the orchestrator_sbc on-chip
# SRAM window (0x4000_0000, 16MB). DRAM (LPDDR5 stub) remains bulk data.

CROSS_COMPILE ?= riscv64-unknown-linux-musl-
KCFLAGS       := ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE)
KERNEL_DIR    ?= $(PWD)/linux
BUILD         := build

.PHONY: all clean image init initrd check

all: check image init initrd

check: $(patsubst %.c,%,$(wildcard src/*.c))

%: %.c src/drv_uart.h src/drv_pnm.h src/drv_nvme.h
	mkdir -p $(BUILD)
	$(CC) -Wall -Wextra -std=c11 -ffreestanding -nostdlib \
	      -Isrc -I../fw -o $@ $< ../fw/pnm_nvme.c
	@echo "  CC      $<"

image: $(KERNEL_DIR)/Makefile configs/pnm_tiny.config
	cd $(KERNEL_DIR) && $(MAKE) $(KCFLAGS) tinyconfig
	cd $(KERNEL_DIR) && $(MAKE) $(KCFLAGS) merge_fragment || \
	    scripts/kconfig/merge_config.sh -m .config ../configs/pnm_tiny.config
	cd $(KERNEL_DIR) && $(MAKE) $(KCFLAGS) olddefconfig
	cd $(KERNEL_DIR) && $(MAKE) $(KCFLAGS) -j$$(nproc) vmlinux
	$(CROSS_COMPILE)objcopy -O binary $(KERNEL_DIR)/vmlinux $(BUILD)/vmlinux.bin
	cp $(KERNEL_DIR)/arch/riscv/boot/Image $(BUILD)/Image

$(KERNEL_DIR)/Makefile:
	@echo "ERROR: Linux source tree not found at $(KERNEL_DIR)."
	@echo "       Download linux-6.6.x and extract, or set KERNEL_DIR."
	@exit 1

initrd: init
	echo "$(BUILD)/init" | cpio -o -H newc > $(BUILD)/initrd.cpio

clean:
	rm -rf $(BUILD)
