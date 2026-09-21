# =============================================================================
# Pi host tooling Makefile — Raspberry Pi Compute Module host-side drivers
#
# Four implementations of the same pi_bridge (HDL/pi_bridge.v) wire protocol:
#
#   pnm_pi.py      Python 3 + spidev   CM0/CM1/CM3/CM4 (GPIO SPI)
#   pnm_pi.go      Go, stdlib only     CM0/CM1/CM3/CM4 (raw spidev ioctl)
#   pnm_pi.rs      Rust, no crates     CM0/CM1/CM3/CM4 (raw spidev ioctl)
#   pnm_pi_spi.c   C, no deps          CM0/CM1/CM3/CM4 (raw spidev ioctl)
#   pnm_pi_cm5.c   C                   CM5 (PCIe BAR0 userspace mapping)
#
# Usage:
#   make              # compile-check every C driver (host gcc)
#   make go           # build pnm_pi_go (native; set GOOS/GOARCH to cross)
#   make rust         # build pnm_pi_rs
#   make demo         # build both C demo binaries (aarch64 cross by default)
#   make host-check   # compile-check all C drivers with the local host gcc
#   make clean
#
# Override CROSS= for another cross toolchain, e.g.:
#   make CROSS=aarch64-none-linux-gnu-
# =============================================================================

CROSS   ?= aarch64-linux-gnu-
CC      := $(CROSS)gcc

OPT     := -O2
WARN    := -Wall -Wextra
CFLAGS  := $(OPT) $(WARN) -std=c11 -D_GNU_SOURCE

.PHONY: all go rust demo host-check clean

all: host-check

go: pnm_pi_go

pnm_pi_go: pnm_pi.go
	go build -o $@ $<

rust: pnm_pi_rs

pnm_pi_rs: pnm_pi.rs
	rustc -O --edition 2021 -o $@ $<

demo: pnm_pi_spi_demo pnm_pi_demo

pnm_pi_spi_demo: pnm_pi_spi.c
	$(CC) $(CFLAGS) -DPNM_PI_DEMO -o $@ $<

pnm_pi_demo: pnm_pi_cm5.c pnm_pi.h
	$(CC) $(CFLAGS) -DPNM_PI_DEMO -o $@ pnm_pi_cm5.c

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

host-check: pnm_pi_cm5.o pnm_pi_spi.o
	gcc $(WARN) -std=c11 -fsyntax-only pnm_pi_cm5.c pnm_pi_spi.c

clean:
	rm -f *.o pnm_pi_demo pnm_pi_spi_demo pnm_pi_go pnm_pi_rs
