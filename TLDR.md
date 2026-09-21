# Breaking the HBM wall: TL;DR

**The problem:** GPU/HBM monoliths cost ~$375/GB (H100-class), are capacity-capped by interposer reticle limits, and spend most energy on data movement rather than compute.

**The solution:** A distributed spatial Processing-Near-Memory architecture that replaces HBM with commodity 192-bit LPDDR6 CAMM2 modules (~$16/GB, ~24x cheaper per byte), each paired with a mature-node (14/28 nm) DUV MAC ASIC on a rigid X/Y motherboard grid.

**Key numbers (512-node reference chassis):**

|| Metric | Value |
||--------|-------|
|| Nodes | 512 (8 layers x 8x8 grid) |
|| Aggregate memory | 64 TB |
|| Aggregate bandwidth | ~131 TB/s (512 nodes × ~256 GB/s node-local) |
|| FP64 throughput | ~197 TFLOPS |
|| Cost per GB | ~$16 (vs ~$375 for HBM) |
|| Chassis power | 8-10 kW |
|| Spine bandwidth | ~2 TB/s per direction |

**How it works:**

1. **Four kinds of hardware:** DRAM modules, MAC ASICs, stateless flit repeaters, and one central orchestrator chip (the only programmable silicon).
2. **Deterministic routing:** Single-spine tree with dimension-order on-board paths. Routing is O(1) coordinate arithmetic on [Layer ID | Module ID] headers. No runtime scheduling, no cache coherency, no OS overhead.
3. **Doorbell activation:** Hardware three-condition fire (byte count, CRC, destination match). Sub-microsecond activation with no software interrupt.
4. **AOT compilation:** A 5-stage compiler maps HuggingFace models onto the physical chassis. The output is a static dataflow graph where the address IS the coordinate and the doorbell IS the program counter.
5. **MoE inference:** Expert weights stay resident in LPDDR6 pools. Only tokens travel to experts via wormhole routing. The orchestrator chip evaluates gating networks and issues ~10^8-10^9 fabric dispatches/s (~270 dispatches per token, so ~10^6 tokens/s end-to-end).
6. **RISC-V BMC/Orchestrator SoC:** The central orchestrator chip is a Linux/seL4-compatible RISC-V SoC (RV32IMA core, UART, CLINT, PNM orchestrator engine) that handles topology discovery, weight upload, and dispatch.

**Target workloads:** MoE transformer inference, FP64 stencil computation for scientific HPC (climate modeling, CFD, seismic imaging), and large-scale numerical simulation.

**What the repo contains:**

- `paper/Paper.MD` — The manuscript (Markdown with LaTeX-escape conventions)
- `paper/HDL/` — Routing fabric RTL + verification testbenches (the paper proofs)
- `paper/build.py` — Build pipeline producing `paper/submission/paper.docx`
- `HDL/` — Full Verilog-2005 fabric: routing gates, compute units, RISC-V SoCs, memory models, testbenches
- `sim/` — Go co-simulation harness (stdlib only): topology/tb generators, virtual execution units, inference client, model compiler, driver, firmware
- `fw/` — C firmware port for MCU targets (ARM Cortex-M/R, RISC-V)
- `pcb/` — Manufacturable PCB assembly (interconnect board, processor board, gating ASIC)
- `sim/examples/` — Synthetic test configs (Gemma-4, mini GLM-MoE, bias_add program)

**Verification:** All transport claims are machine-checked by the co-simulation harness against a cycle-exact Verilog model. Six scenarios (sweep, vcsweep, load, hotspot, stress, replay) verify byte-exact delivery, zero drops, doorbell accounting, kernel correctness, and deterministic replay.
