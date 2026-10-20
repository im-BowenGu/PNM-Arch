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

# The daemon targets the RV32IMA (FPU-less) orchestrator core, so it must be
# built soft-float (-march=rv32ima -mabi=ilp32). The nixpkgs riscv32-musl
# triplet defaults to rv32gc/ilp32d (double-float) and cannot link such
# objects; the Nix flake therefore builds a static-only soft-float musl and
# exports its lib dir as PNM_MUSL_RV32IMA. When that variable is present the
# link uses the musl crt files and libc.a from it directly; otherwise the
# classic tripelt default is used (compile-only, or link if your distro's
# riscv32 musl happens to be soft-float).
CROSS   ?= $(shell command -v riscv32-unknown-linux-musl-gcc >/dev/null 2>&1 && echo riscv32-unknown-linux-musl- || echo riscv64-unknown-linux-musl-)
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

ifdef PNM_MUSL_RV32IMA
MUSL_CRT := -nostartfiles $(PNM_MUSL_RV32IMA)/lib/crt1.o $(PNM_MUSL_RV32IMA)/lib/crti.o
MUSL_LIB := $(PNM_MUSL_RV32IMA)/lib/libc.a $(PNM_MUSL_RV32IMA)/lib/crtn.o
$(TARGET): $(OBJS) linker_soc.ld
	$(CC) $(LDFLAGS) $(MUSL_CRT) -o $@ $(OBJS) $(MUSL_LIB)
	@echo "Built $@ ($$(stat -c%s $@) bytes, soft-float musl)"
else
$(TARGET): $(OBJS) linker_soc.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)
	@echo "Built $@ ($$(stat -c%s $@) bytes)"
endif

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

disasm: $(TARGET)
	$(CROSS)objdump -d $< > $(TARGET).dis

clean:
	rm -f *.o $(TARGET) *.map *.dis