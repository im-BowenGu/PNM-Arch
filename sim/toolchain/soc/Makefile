# =============================================================================
# SoC toolchain Makefile — NOMMU Linux/Redox userspace daemon
#
# Produces a statically-linked RV32 ELF that the boot ROM second-stage
# loader places in DRAM. Runs under Linux/Redox NOMMU (Flat Mode).
#
# Unlike the MCU toolchain:
#   - Links against musl-libc (NOMMU-compatible)
#   - malloc/mmap are available (DRAM-backed heap)
#   - Can open /dev/pnm for register access instead of hard-coded addresses
#   - Supports fork-less concurrency via vfork + posix_spawn
#
# Usage:
#   make              # build pnm_socd (daemon binary)
#   make clean
# =============================================================================

CROSS   ?= riscv64-unknown-linux-musl-
CC      := $(CROSS)gcc

ARCH     := -march=rv32ima -mabi=ilp32 -mcmodel=medany
OPT      := -O2
WARN     := -Wall -Wextra
CFLAGS   := $(ARCH) $(OPT) $(WARN) -std=c11 \
            -D_GNU_SOURCE -D__NOMMU__ \
            -ffunction-sections -fdata-sections
LDFLAGS  := $(ARCH) -static -Wl,--gc-sections \
            -T linker_soc.ld -Wl,-Map=pnm_socd.map

SRCS     := soc_start.c pnm_dev.c dispatch_soc.c main_soc.c
OBJS     := $(SRCS:.c=.o)
TARGET   := pnm_socd

.PHONY: all clean disasm

all: $(TARGET)

$(TARGET): $(OBJS) linker_soc.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)
	@echo "Built $(TARGET) ($(shell stat -c%s $@) bytes)"

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

disasm: $(TARGET)
	$(CROSS)objdump -d $< > $(TARGET).dis

clean:
	rm -f *.o $(TARGET) *.map *.dis
