# Repository Documentation

> Comprehensive documentation for the PNM Architecture paper repository.

## Overview

This repository contains the working artifacts behind the paper *Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing*. It includes the manuscript source, a Go-Verilog co-simulation harness, Verilog HDL for the routing fabric and compute units, a RISC-V BMC/router chip SoC, and a build pipeline that produces the DOCX submission.

## Repository Structure

```
Paper/
  Paper.MD              # Manuscript source (Markdown with LaTeX-escape conventions)
  build.py              # Build pipeline -> submission/paper.docx (+ .pdf, .tex)
  AGENTS.md             # Agent guidance for working in this repository
  shell.nix             # Nix shell with the full toolchain
  README.md             # Project overview
  HDL/                  # Verilog-2005 fabric model + compute units
  sim/                  # Co-simulation harness (Go, stdlib only)
  sim/fw/               # C firmware port for MCU targets
  sim/examples/         # Synthetic test configurations
  submission/           # Build artifacts (gitignored)
```

## Hardware Description Language (HDL/)

### Routing Fabric

The fabric is a byte-wide, Verilog-2005 model of the deterministic single-spine wormhole routing topology.

| Module | File | Description |
|--------|------|-------------|
| `hfr.v` | Hardware Flit Repeater | Stateless retimer; forwards flits one byte per cycle |
| `flit_gate.v` | Flit Gate | Combinational demux; compares header byte against parameter |
| `vc_merge.v` | VC Merge | 2-in/1-out round-robin arbiter for egress tree |
| `xyz_repeater.v` | XYZ Repeater | Layer gate; matches LAYER_ID, strips on match |
| `xy_turn.v` | XY Turn | X-dimension gate; matches X nibble of MODULE_ID |
| `node_eject.v` | Node Eject | Destination gate; matches full MODULE_ID |
| `pnm_defs.vh` | Definitions | Wire format constants, VC classes, CRC parameters |

### Compute Units

| Module | Type | Precision | Latency | Use Case |
|--------|------|-----------|---------|----------|
| `bf16_fma.v` | FMA | BF16 | 3 cycles | MoE experts, dense MLP |
| `fp16_fma.v` | FMA | FP16 | 3 cycles | FP16 models |
| `fp32_fma.v` | FMA | FP32 | 3 cycles | High-precision compute |
| `fp64_fma.v` | FMA | FP64 | 3 cycles | Double-precision scientific |
| `bf16_mac_array.v` | Systolic array | BF16 | variable | Attention QKV |
| `fp16_mac_array.v` | Systolic array | FP16 | variable | FP16 attention |
| `fp32_alu.v` | ALU | FP32 | 1-25 cycles | Layernorm (divider) |
| `int8_mac.v` | MAC | INT8 | 1 cycle | Quantized inference |
| `moe_gating.v` | MoE Gating | BF16 | variable | Top-k expert selection |

### Doorbell and CRC

| Module | File | Description |
|--------|------|-------------|
| `doorbell.v` | Doorbell | Three-condition fire: byte count, CRC validate, DEST match |
| `crc16.v` | CRC-16 | CCITT-FALSE (init 0xFFFF, poly 0x1021) |
| `pe_tile_stub.v` | PE Tile Stub | MAC stub with bias-add, CRC recompute, AXI-Stream interface |

### BMC/Router Chip (RISC-V SoC)

The central router chip is implemented as a RISC-V System-on-Chip for chassis management, topology discovery, MoE dispatch, and host PCIe.

**Why an SoC, not an MCU:** (1) OS compatibility — NOMMU Linux/Redox requires an RV32IMAFC-class core with sufficient SRAM; MCU silicon typically lacks both. (2) PCIe Gen5 endpoint termination requires dedicated PHY + controller blocks integrated into SoC silicon. (3) MoE gating evaluation at 10^8–10^9 tokens/s demands clock rates beyond typical MCU envelopes. (4) Source-routed routing tables for 512 nodes plus MoE expert maps exceed MCU on-chip SRAM. The current RTL implements RV32IMA as a proof of concept; production upgrades to RV32IMAFC for NOMMU Linux support. For source-language transpilation (R/Haskell/HLSL), the main thread runs on the router chip's CPU: the host compiles source to typed IR and ships it over PCIe, and the router's firmware lowers it onto the chassis (allocating registers, assigning kernels to nodes, computing routes) without round-tripping through the host.

| Module | File | Description |
|--------|------|-------------|
| `rv32_core.v` | RV32IMA CPU | Multi-cycle 5-stage FSM core: RV32I base + M extension + Zicsr |
| `uart.v` | UART | 16550-compatible, 8N1, configurable baud, interrupt output |
| `clint.v` | CLINT | Machine-mode timer (mtime/mtimecmp) + software interrupt (msip) |
| `bmc_router_top.v` | SoC Top | CPU + 64KB ROM + 64KB SRAM + UART + CLINT + PNM router engine |

Memory map: ROM@0x00000000, UART@0x10000000, CLINT@0x20000000, SRAM@0x80000000, PNM@0xF0000000.

### Testbenches

All testbenches are self-checking (scoreboard counters, `errors` integers, $display PASS/FAIL).

| Testbench | Tests | Expected Output |
|-----------|-------|-----------------|
| `tb_fabric.v` | Spine, board, up-spine routing | `*** ALL TESTS PASSED ***` |
| `tb_load.v` | 500 packets, backpressure, checksums | `*** LOAD TEST PASSED (500 packets) ***` |
| `tb_doorbell.v` | 8 packets: 6 activations, 2 refusals, 2 corrupt_out | `*** DOORBELL TEST PASSED ***` |
| `tb_fp16_fma.v` | FP16 FMA 3-cycle pipeline | `*** FP16 FMA TEST PASSED ***` |
| `tb_bf16_fma.v` | BF16 FMA 3-cycle pipeline | `*** BF16 FMA TEST PASSED ***` |
| `tb_fp32_fma.v` | FP32 FMA 3-cycle pipeline | `*** FP32 FMA TEST PASSED ***` |
| `tb_fp64_fma.v` | FP64 FMA 3-cycle pipeline | `*** FP64 FMA TEST PASSED ***` |
| `tb_fp32_alu.v` | FP32 ALU division, MIN/MAX/CMP | `*** FP32 ALU TEST PASSED ***` |
| `tb_int8_mac.v` | INT8 single-cycle MAC | `*** INT8 MAC TEST PASSED ***` |
| `tb_fp16_mac_array.v` | FP16 systolic array | `*** FP16 MAC ARRAY TEST PASSED ***` |
| `tb_bf16_mac_array.v` | BF16 systolic array | `*** BF16 MAC ARRAY TEST PASSED ***` |
| `tb_moe_gating.v` | MoE softmax top-k | `*** MoE GATING TEST PASSED ***` |
| `tb_router_chip.v` | Router chip boot + dispatch | `*** ROUTER CHIP TEST PASSED ***` |
| `tb_bmc_router.v` | BMC/Router SoC: UART, PNM regs, boot_done | `*** BMC ROUTER CHIP TEST PASSED ***` |

## Co-Simulation Harness (sim/)

### Architecture

The harness is a Go standard-library-only program that:
1. Generates stimulus (manifest: dest, kernel, weights, bias, payload, CRC, golden)
2. Generates Verilog topology (`pnm_top.v`) and testbench (`tb_pnm.v`)
3. Compiles Verilog slices in parallel `iverilog` processes
4. Runs them in parallel `vvp` processes
5. Verifies hardware results against the golden model

### Key Components

#### Core Types (`run.go`)

- `NodeID` - Physical coordinate: `{L, X, Y}`
- `Dims` - Chassis dimensions: `{Layers, Bx, By}`
- `StreamByte` - Wire byte with SOP/EOP/VC sideband
- `Flit(layer, dest, ctrl, payload, echo)` - Constructs wire-format flits
- VC class constants: `VC_BOARD_EGRESS=0`, `VC_SPINE_ASCENT=1`, `VC_SPINE_DESCENT=2`, `VC_ONBOARD_DELIVER=3`

#### Topology Generator (`gen_topology.go`)

Generates `pnm_top.v` from chassis dimensions. Each node gets:
- An `xyz_repeater` with a route bitmap parameter
- A `pe_tile_stub` with compute unit type and bias constant
- DMA ports for injection and delivery

#### Testbench Generator (`gen_tb.go`)

Generates `tb_pnm.v` for parallel vvp slices. Features:
- Injector task from `stimulus.hex` via $readmemh
- Per-node backpressure (ready 1 cycle in N)
- Delivery.log via $fwrite (including C verdict lines for stubs)
- Adaptive $finish after 200 quiet cycles

#### Virtual Execution Units (`virtual_units.go`)

`VirtualUnit.Consume()` implements the Go-side doorbell twin:
- Three-condition fire: byte count == LEN+6, CRC validates, DEST == LOCAL_MODULE
- Resident kernels: `echo`, `sum`, `accum`, `dot`
- Results checked against golden manifest

#### Discrete Event Simulator (`des.go`)

Activity-driven DES of the egress merge tree:
- Pipeline registers (HFRs, PE MAC pipes) separated by combinational gate clouds
- Three merge kinds: `mkYm` (Y-up), `mkXm` (X-up), `mkUp` (repeater upmerge)
- Cross-checks against RTL via `CrossCheckDES()`
- Shares no code with Verilog; reproduces delivery stream byte-for-byte

#### Model Compiler (`model_compiler.go`)

Five-stage AOT pipeline that transpiles HuggingFace models onto PNM chassis:

1. **Ingest** - Parse safetensors index + config.json, infer tensor shapes from ~20 naming patterns
2. **Partition** - Layer-to-physical mapping, expert round-robin, dense assignment, embedding sharding, KV cache reservation (80% of 128GB, max 16K entries)
3. **Map** - Assign operations to kernel names and compute unit types by tensor role
4. **Route** - Compute 11-bit routing bitmaps and MoE expert map
5. **Emit** - Write .pnm program file and chassis schema

Key structs: `ModelCompiler`, `NodeAssignment`, `ComputeUnitType` (9 types), `TensorRef`

#### Safetensors Parser (`safetensors.go`)

Parses HuggingFace model format:
- `LoadSafetensorsIndex(dir)` - Parse weight_map from index JSON
- `LoadModelConfig(dir)` - Parse nested TextConfig
- `TensorShapeFor(name, cfg)` - Infer shapes from ~20 tensor name patterns
- `CollectTensors(idx, cfg)` - Merge index + config into full catalog

#### Host Driver (`driver.go`)

Orchestrates model loading and inference:
- `BuildWeightCommands()` - Deterministic weight upload sequence sorted L-X-Y
- `BuildWeightFlit(cmd)` - Construct wormhole flits from commands
- `PlanInference(token)` - Dispatch sequence for one token through all layers
- `computeRouteBitmaps()` - Generate 11-bit routing bitmaps per node
- `computeMoeMap()` - Build expert-to-coordinate mapping

#### Firmware (`firmware.go`)

Models the central router chip:
- 5-phase boot: RESET -> POST_DISCOVERY -> ROUTING_TABLE -> WEIGHT_UPLOAD -> MOE_LOAD -> READY
- `PlanInference(token)` - Per-token dispatch: dense attention -> KV cache check -> MoE gating -> expert dispatch
- `VerifyWeightUpload(cmds)` / `VerifyDispatch(records)` - Runtime verification

#### LLM Client (`llm_client.go`)

End-to-end autoregressive inference:
- Tokenization (whitespace + hash fallback)
- Prefill + autoregressive generation
- Temperature/nucleus (top-p) sampling with numerical stability
- Per-inference statistics (tokens, dispatches, KV ops, CU utilization)

#### KV Cache (`kv_cache.go`)

Distributed KV cache with per-direction banks:
- 4 directional banks (X+, X-, Y+, Y-) per physical layer
- FIFO eviction at 80% capacity threshold
- Offload to host DRAM via spine when threshold exceeded

#### Deterministic RNG (`rng.go`)

Byte-exact clone of CPython's `random.Random`:
- MT19937 Mersenne Twister implementation
- Verified against CPython known outputs (`rng_test.go`)
- Same `--seed` reproduces identical stimulus across runs

#### Source Language Toolchains

| Compiler | Input | Output | Target CU |
|----------|-------|--------|-----------|
| `r_ir.go` | R (assignments, arithmetic, aggregations) | FP64 register-based IR | `fp64_fma` |
| `haskell_ir.go` | Haskell (functions, guards, do blocks) | FP64 register-based IR | `fp64_fma` |
| `hlsl_ir.go` | HLSL (float declarations, intrinsics) | FP32 ALU IR | `fp32_alu` |

IR is deliberately minimal: no loops, no branches, no dynamic allocation. Complex control flow is lowered to straight-line IR with explicit data dependencies.

### Scenarios

| Scenario | Description | What it checks |
|----------|-------------|----------------|
| `sweep` | One flit to every node | Exact closed-form latency |
| `vcsweep` | Sweep + pass-through on all 4 VC classes | Arbitrated egress tree adds no delay |
| `load` | 500 random flits with 100/50/25% backpressure | Lossless delivery with slow consumers |
| `hotspot` | MoE hot-expert traffic on corner node | No drops under concentrated load |
| `stress` | ~24 flits/node, ~3% corrupt CRC | Doorbell refuses all corrupt messages |
| `replay` | Stress twice, bit-identical logs | Deterministic replay (no hidden state) |

### CLI Tools

#### `cmd/pnm` - Co-Simulation Harness

```bash
go run ./cmd/pnm                         # 3x4x4 = 48 nodes, all 6 scenarios
go run ./cmd/pnm -l 8 -x 8 -y 8          # 512-node reference chassis
go run ./cmd/pnm --scenarios sweep stress --seed 1
go run ./cmd/pnm --groups 8              # force 8 parallel vvp slices
go run ./cmd/pnm --cpuprofile /tmp/pnm.cpu --memprofile /tmp/pnm.mem
```

#### `cmd/pnmc` - Program Compiler + Model Compiler + Driver

```bash
go run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8   # compile + run a program
go run ./cmd/pnmc compile-model examples/gemma4_test -l 4 -x 4 -y 4   # model compiler
go run ./cmd/pnmc run-driver examples/gemma4_test -l 4 -x 4 -y 4      # driver + firmware
go run ./cmd/pnmc workload jacobi5 -l 1 -x 4 -y 4 -run                # workload simulation
go run ./cmd/pnmc workload matvec -l 4 -x 4 -y 4 -frag 16 -run        # matvec (16-element vectors)
go run ./cmd/pnmc workload reduction -l 4 -x 4 -y 4 -frag 32          # emit only
go run ./cmd/pnmc workload broadcast -l 4 -x 4 -y 4 -frag 64 -run     # broadcast fan-out
go run ./cmd/pnmc workload nbody -l 4 -x 2 -y 2 -frag 8 -run          # all-pairs saturation
go test ./internal/pnm/                  # all tests
```

Workload simulations exercise canonical HPC routing patterns against the gate-level fabric:

| Workload | Algorithm | Routing pattern |
|----------|-----------|----------------|
| `jacobi5` | 5-point Jacobi stencil | Intra-layer X→Y dimension-order (no spine) |
| `matvec` | Matrix-vector product, row-per-node | Spine descent for cross-layer rows |
| `reduction` | Reverse-path merge tree | Egress → Y-up → X-up → spine ascent |
| `broadcast` | Weight distribution from root | Spine descent + per-layer X→Y fan-out |
| `nbody` | All-pairs O(N²) interaction | All paths saturated (upper bound, ≤64 nodes) |

### .pnm Program Format

The .pnm format is a plain-text directive language:

```
# kernel <name> <dest_l> <dest_x> <dest_y> [weight_bytes...]
kernel sum 2 2 5
bias   7 2 2 5

# kernel with resident weights (hex)
kernel dot 7 7 7 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10
bias   3 7 7 7

# token <dest_l> <dest_x> <dest_y> <payload_hex...>
token 2 2 5   10 20 30 40 50 60 70 80 90 a0 b0 c0 d0 e0 f0 00
token 7 7 7   de ad be ef
```

## C Firmware Port (sim/fw/)

Direct C port of `firmware.go` for MCU targets (ARM Cortex-M/R, RISC-V).

### Key Features
- Static allocation only: no `malloc`, no dynamic memory, no OS dependency
- All buffers statically sized with `#define` constants
- Same 5-phase boot sequence and dispatch loop as Go firmware

### Key Constants
- `PNM_MAX_LAYERS=8`, `PNM_MAX_NODES=64`, `PNM_MAX_NODES_TOTAL=512`
- `PNM_MAX_EXPERTS=256`, `PNM_MAX_TOPK=16`, `PNM_MAX_MODEL_LAYERS=128`
- `PNM_KV_CACHE_DEPTH=4096`, `PNM_ROUTING_TABLE_SIZE=256`

### Files
- `pnm_fw.h` - Types, API, and constants
- `pnm_fw.c` - Boot sequence, dispatch loop, KV cache, verification

## Wire Format

Every fabric link carries byte-wide flits:

```
Byte 0: LAYER_ID            (stripped by xyz_repeater on match)
Byte 1: MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
Byte 2: CTRL = {vc_class[7:6], op[5:4], rsvd[3:0]}
Byte 3: LEN_LO
Byte 4: LEN_HI
Byte 5+: payload (LEN bytes)
Last 2: CRC_HI, CRC_LO
```

CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021) covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload].

## Build Commands

### Paper
```bash
python3 build.py            # submission/paper.docx + .pdf + .tex
python3 build.py --review   # submission/paper_review.pdf (11pt single-column)
```

### HDL Testbenches
```bash
cd HDL
iverilog -g2005 -o tb_fabric.out hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
iverilog -g2005 -o tb_load.out   hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v   && vvp tb_load.out
iverilog -g2005 -o tb_doorbell.out tb_doorbell.v pe_tile_stub.v doorbell.v crc16.v bf16_fma.v && vvp tb_doorbell.out
# ... (see AGENTS.md for complete list)
```

### Static Lint
```bash
verilator --lint-only -Wno-MULTITOP hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v
```

### C Firmware
```bash
cd sim/fw && gcc -Wall -Wextra -std=c11 -c pnm_fw.c -o pnm_fw.o
```

### Co-Simulation
```bash
cd sim && go test ./internal/pnm/
```
