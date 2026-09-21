# =============================================================================
# fw-sel4 — seL4 microkernel image for orchestrator_sbc
#
# Builds a minimal seL4 root task for the RV32IMA orchestrator_sbc chip.
# The root task maps the UART and PNM register windows, prints a
# boot banner, and enters a seL4_Yield idle loop.
#
# seL4 provides formal verification, capability-based access control,
# and temporal isolation — a hardened alternative to Linux for the
# router chip's control plane.
#
# Prerequisites:
#   - CMake >= 3.18
#   - seL4 source tree at sel4/ (or set SEL4_DIR)
#   - riscv32-unknown-elf-gcc toolchain (available in flake.nix)
#
# Usage:
#   make            # build everything (kernel + root task)
#   make kernel     # seL4 kernel only
#   make root-task  # root task ELF only
#   make clean
# =============================================================================

SEL4_DIR     ?= $(PWD)/sel4
BUILD        := build
ROOT_TASK    := root_task
CROSS        ?= riscv32-unknown-elf-
CROSS_CC     := $(CROSS)gcc
PLATFORM     := generic

# seL4 CMake configuration for RV32IMA, no MMU (seL4 manages page tables)
SEL4_CMAKE_FLAGS := \
	-DCROSS_COMPILER_PREFIX=$(CROSS) \
	-DCMAKE_TOOLCHAIN_FILE=$(SEL4_DIR)/cmake-toolchain-riscv32.cmake \
	-DKernelArch=riscv \
	-DKernelPlatform=$(PLATFORM) \
	-DKernelIsMCS=OFF \
	-DKernelOptimisation=-O2 \
	-DKernelVerificationBuild=OFF \
	-DCMAKE_BUILD_TYPE=Release \
	-DSIMULATION=OFF

.PHONY: all kernel root-task clean

all: root-task

kernel: $(SEL4_DIR)/CMakeLists.txt
	mkdir -p $(BUILD)/kernel
	cd $(BUILD)/kernel && cmake $(SEL4_CMAKE_FLAGS) $(SEL4_DIR)
	$(MAKE) -C $(BUILD)/kernel -j$$(nproc)

root-task: kernel src/root_task/main.c src/root_task/CMakeLists.txt
	mkdir -p $(BUILD)/root_task
	cd $(BUILD)/root_task && cmake \
		-DCROSS_COMPILER_PREFIX=$(CROSS) \
		-DCMAKE_TOOLCHAIN_FILE=$(SEL4_DIR)/cmake-toolchain-riscv32.cmake \
		-DKERNEL_DIR=$(BUILD)/kernel \
		-DROOT_TASK_SRC=$(CURDIR)/src/root_task \
		$(CURDIR)/src/root_task
	$(MAKE) -C $(BUILD)/root_task -j$$(nproc)
	@echo "Root task: $(BUILD)/root_task/$(ROOT_TASK).elf"
	@ls -la $(BUILD)/root_task/$(ROOT_TASK).elf 2>/dev/null || true

$(SEL4_DIR)/CMakeLists.txt:
	@echo "ERROR: seL4 source tree not found at $(SEL4_DIR)."
	@echo "       Clone https://github.com/seL4/seL4.git and checkout a stable branch."
	@echo "       Or set SEL4_DIR=/path/to/seL4."
	@exit 1

clean:
	rm -rf $(BUILD)
