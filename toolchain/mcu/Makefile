# =============================================================================
# MCU toolchain Makefile — bare-metal firmware for orchestrator_mcu
#
# Produces a flat binary suitable for loading into the 8KB boot ROM of
# orchestrator_mcu.v. Static allocation only, no libc, no OS, no dynamic linking.
#
# Usage:
#   make              # build firmware.bin + firmware.hex
#   make clean
#   make disasm      # dump firmware.dis for debugging
#
# Cross-compiler: install riscv-none-elf-gcc (xPack) or use the Nix shell.
# Fallback: any RV32I-capable cross-compiler works (clang --target=riscv32).
# =============================================================================

CROSS   ?= riscv-none-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

ARCH     := -march=rv32i -mabi=ilp32 -mcmodel=medlow
OPT      := -Os
WARN     := -Wall -Wextra -Werror
CFLAGS   := $(ARCH) $(OPT) $(WARN) -std=c11 -ffreestanding -nostdlib \
            -fno-builtin -fno-stack-protector -ffunction-sections -fdata-sections
LDFLAGS  := $(ARCH) -nostdlib -static -Wl,--gc-sections \
            -T linker.ld -Wl,-Map=firmware.map

SRCS     := startup.c dispatch.c pnm_regs.c
OBJS     := $(SRCS:.c=.o)
TARGET   := firmware

.PHONY: all clean disasm

all: $(TARGET).bin $(TARGET).hex

$(TARGET).elf: $(OBJS) linker.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)
	$(SIZE) $@

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).hex: $(TARGET).bin
	xxd -p -c 4 $< | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/' > $@
	@echo "Hex image: $@ ($(shell stat -c%s $(TARGET).bin) bytes)"
	@echo "ROM budget: 8192 bytes"

disasm: $(TARGET).elf
	$(OBJDUMP) -d $< > firmware.dis

clean:
	rm -f *.o *.elf *.bin *.hex *.map *.dis
