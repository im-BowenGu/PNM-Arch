# fw/os/linux — Linux tinyconfig image + basic drivers for orchestrator_sbc
#
# Produces:
#   build/Image          — NOMMU RISC-V kernel (tinyconfig + PNM fragment)
#   build/init           — static freestanding init binary
#   build/initrd.cpio    — initramfs containing init
#   build/vmlinux.bin    — flat binary kernel for direct SRAM load
#
# The trimmed kernel is sized to execute from the orchestrator_sbc on-chip
# SRAM window (0x4000_0000, 16MB). DRAM (LPDDR5 stub) remains bulk data.
#
# This is the router chip's *software* (an OS image for the orchestrator SoC);
# the cross-compilation toolchains live in toolchain/.

CROSS_COMPILE ?= riscv32-unknown-linux-musl-
# make's built-in CC default ("cc") must not win over the cross compiler
ifeq ($(origin CC),default)
CC := $(CROSS_COMPILE)gcc
endif
KCFLAGS       := ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE)
KERNEL_DIR    ?= $(PWD)/linux
BUILD         := build
FW_DIR        := ../..

.PHONY: all clean image init initrd init.hex check

all: check image init initrd

check: $(BUILD)/init

# The init binary is freestanding: no libc, no start files. It links the
# local UART/PNM drivers, the shared NVMe driver from fw/, and a tiny _start
# stub (the kernel hands control to /init with the stack already set up).
# INIT_BASE is the flat-binary load address (the chip's SRAM window by
# default; override for a DRAM/QEMU run).
INIT_BASE ?= 0x40000000

# The 16550 register shift: 2 on the chip (HDL/uart.v decodes cpu_addr[7:2]),
# 1 on a host whose UART is byte aligned (QEMU's riscv virt machine).
UART_REG_SHIFT ?= 2

$(BUILD)/init: src/init.c src/drv_uart.c src/drv_pnm.c \
               src/drv_uart.h src/drv_pnm.h src/drv_nvme.h \
               $(FW_DIR)/pnm_nvme.c src/start.S src/div.S src/init.ld
	mkdir -p $(BUILD)
	$(CC) -Wall -Wextra -std=c11 -ffreestanding -nostdlib \
	      -march=rv32i -mabi=ilp32 \
	      -DPNM_UART_REG_SHIFT=$(UART_REG_SHIFT) \
	      -Isrc -I$(FW_DIR) -T src/init.ld -Wl,--defsym=__base=$(INIT_BASE) \
	      -o $@ src/start.S src/init.c src/drv_uart.c \
	      src/drv_pnm.c $(FW_DIR)/pnm_nvme.c src/div.S
	@echo "  CC      $< (base $(INIT_BASE))"

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

# init.hex: the linked init image as a word-per-line hex file, for the
# chip-accurate testbench (HDL/tb_linux_init.v) that runs it on rv32_core.v.
init.hex: $(BUILD)/init
	$(CROSS_COMPILE)objcopy -O binary --strip-all $< $(BUILD)/init.bin
	od -An -v -tx4 $(BUILD)/init.bin | tr -s ' ' '\n' | grep -v '^$$' > $@

initrd: $(BUILD)/init
	# the initramfs must hold /init at the archive root
	(cd $(BUILD) && echo init | cpio -o -H newc > initrd.cpio)

clean:
	rm -rf $(BUILD)
