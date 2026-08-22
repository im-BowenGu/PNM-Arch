# Bypassing the HBM Wall: TL;DR

**The problem:** GPU/HBM monoliths cost ~$375/GB (H100-class), are capacity-capped by interposer reticle limits, and spend most energy on data movement rather than compute.

**The solution:** A distributed spatial Processing-Near-Memory architecture that replaces HBM with commodity 192-bit LPDDR6 CAMM2 modules (~$16/GB, ~24x cheaper per byte), each paired with a mature-node (14/28 nm) DUV MAC ASIC on a rigid X/Y motherboard grid.

**Key numbers (512-node reference chassis):**

|| Metric | Value |
||--------|-------|
|| Nodes | 512 (8 layers x 8x8 grid) |
|| Aggregate memory | 64 TB |
|| Node-local bandwidth | ~131 TB/s |
|| FP64 throughput | ~197 TFLOPS |
|| Cost per GB | ~$16 (vs ~$375 for HBM) |
|| Chassis power | 8-10 kW |
|| Spine bandwidth | ~2 TB/s per direction |

**How it works:**

1. **Four kinds of hardware:** DRAM modules, MAC ASICs, stateless flit repeaters, and one central router chip (the only programmable silicon).
2. **Deterministic routing:** Single-spine tree with dimension-order on-board paths. Routing is O(1) coordinate arithmetic on [Layer ID | Module ID] headers. No runtime scheduling, no cache coherency, no OS overhead.
3. **Doorbell activation:** Hardware three-condition fire (byte count, CRC, destination match). Sub-microsecond activation with no software interrupt.
4. **AOT compilation:** A 5-stage compiler maps HuggingFace models onto the physical chassis. The output is a static dataflow graph where the address IS the coordinate and the doorbell IS the program counter.
5. **MoE inference:** Expert weights stay resident in LPDDR6 pools. Only tokens travel to experts via wormhole routing. The router chip evaluates gating networks and dispatches tokens at ~10^8-10^9 tokens/s.
6. **RISC-V BMC/Router SoC:** The central router chip is a Linux/Redox-compatible RISC-V SoC (RV32IMA core, UART, CLINT, PNM router engine) that handles topology discovery, weight upload, and dispatch.

**Target workloads:** MoE transformer inference, FP64 stencil computation for scientific HPC (climate modeling, CFD, seismic imaging), and large-scale numerical simulation.

**What the repo contains:**

- `Paper.MD` - The manuscript (Markdown with LaTeX-escape conventions)
- `HDL/` - Verilog-2005 fabric model + compute units + RISC-V BMC/Router SoC + testbenches (all passing)
- `sim/` - Go co-simulation harness (stdlib only): topology/tb generators, virtual execution units, inference client, model compiler, driver, firmware
- `sim/fw/` - C firmware port for MCU targets (ARM Cortex-M/R, RISC-V)
- `sim/examples/` - Synthetic test configs (Gemma-4, mini GLM-MoE, bias_add program)
- `build.py` - Build pipeline producing `submission/paper.docx`

**Verification:** All transport claims are machine-checked by the co-simulation harness against a cycle-exact Verilog model. Six scenarios (sweep, vcsweep, load, hotspot, stress, replay) verify byte-exact delivery, zero drops, doorbell accounting, kernel correctness, and deterministic replay.
