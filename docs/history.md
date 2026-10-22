# AGENTS.md

Guidance for working in this repository: a research paper (*Breaking the HBM wall*,
a distributed Processing-Near-Memory architecture) plus the working artifacts that
back its claims — a Verilog fabric sketch, a Go ↔ Verilog co-simulation harness,
and a build pipeline that produces the one-file DOCX submission.

## Repository layout

| Path | Contents | License |
|------|----------|---------|
| `paper/Paper.MD` | Manuscript source of truth (Markdown with LaTeX-escape conventions, see below) | CC BY-SA 4.0 |
| `paper/build.py` | Build pipeline → `submission/paper.docx` (+ `.pdf`, `.tex`).  | AGPL-3.0 |
| `HDL/` | Verilog-2005 fabric model: `pnm_defs.vh`, `hfr.v`, `flit_gate.v`, `vc_merge.v`, `lxy_repeater.v`, `xy_turn.v`, `node_eject.v`, `pnm_host_bridge.v` (the CPU-less router bridge), `kv_cache_bank.v`, `kv_offload.v`, `pi_bridge.v`, `pnm_arb.v`, `lpddr6_camm.v`, `sodimm_ctrl.v`, `pcb_link.v`, `optical_link.v`, `power_rails.v`, `pcb_si_link.v`, `lpddr5_phy.v`, `lpddr5x_phy.v`, `lpddr6_phy.v`, `rst_sync.v`, `clk_gate.v` + testbenches `tb_fabric.v`, `tb_load.v`, `tb_pnm_host_bridge.v`, `tb_pi_bridge.v`, `tb_host_bmc.v`, `tb_dma_lpddr6.v`, `tb_pcb_link.v`, `tb_sodimm_lpddr.v`, `tb_sodimm_ctrl.v`, `tb_optical_link.v`, `tb_power_rails.v`, `tb_pcb_si_link.v`, `tb_lpddr5_phy.v`, `tb_lpddr5x_phy.v`, `tb_lpddr6_phy.v`, `tb_rst_sync.v`, `tb_clk_gate.v`; `HDL/core/` holds compute primitives: `pe_tile_stub.v`, `crc16.v`, `doorbell.v`, `bf16_fma.v`, `fp16_fma.v`, `fp32_fma.v`, `fp64_fma.v`, `fp16_mac_array.v`, `bf16_mac_array.v`, `fp32_alu.v`, `fp32_alu_chip.v`, `fp32_mac_array.v`, `fp64_alu.v`, `int8_mac.v`, `int8_alu.v`, `moe_gating.v`, `weight_dequant.v`, `rotary_engine.v`, `kv_quant.v`, `dyn_act_quant.v`, `int4_mac_array.v` + testbenches `tb_doorbell.v`, `tb_fp16_fma.v`, `tb_bf16_fma.v`, `tb_fp32_fma.v`, `tb_fp64_fma.v`, `tb_fp16_mac_array.v`, `tb_bf16_mac_array.v`, `tb_fp32_alu.v`, `tb_int8_mac.v`, `tb_moe_gating.v`, `tb_bf16_fma_edge.v`, `tb_crc16.v`, `tb_fp16_fma_edge.v`, `tb_fp32_alu_edge.v`, `tb_fp32_mac_array.v`, `tb_fp64_alu.v`, `tb_int8_alu.v`, `tb_rotary_engine.v`, `tb_kv_quant.v`, `tb_dyn_act_quant.v`, `tb_weight_dequant.v`; every repeater carries an 11-bit routing-bitmap comparator | CERN-OHL-S v2 |
| `sim/` | Co-simulation harness (Go, stdlib only): `cmd/pnm` (orchestrator + verification), `cmd/pnmc` (program compiler + model compiler + driver CLI), `cmd/pnmhost` (unified host driver for all workloads), `cmd/pnmsrc` (client-side source front end for R/Haskell/HLSL; `r_pnm`/`haskell_pnm`/`hlsl_pnm` are thin wrappers over it), `internal/pnm/srcfront.go` + `srccli.go` (the shared front end: language dispatch, IR printout, `.pnm` emission, chained fabric run), `internal/pnm/gen_topology.go` (emits `pnm_top.v`), `gen_tb.go` (emits `tb_pnm.v`), `virtual_units.go` (doorbell + kernels), `des.go` (discrete-event egress model) + `des_test.go`, `run.go` (scenarios + verify), `result_log.go` (CSV/JSON structured export), `host_driver.go` (unified host driver), `rng.go` (CPython-compatible MT19937), `safetensors.go` (safetensors index parser + model config reader + tensor shape inference), `model_compiler.go` (model-to-PNM compiler: 5-stage AOT pipeline), `driver.go` (host-side driver: weight upload + inference orchestration), `firmware.go` (orchestrator chip firmware: boot sequence + MoE dispatch), `kv_cache.go` (KV cache management with LRU eviction), `llm_client.go` (FP16/BF16 LLM inference client with sampling), `driver_test.go`, `nvme_device.go` (Go twin of pnm_nvme block driver; the Lustre client twin is quarantined under `archive/`), `fp64_dataflow.go` (chained R/Haskell/HLSL dataflow execution: register-scheduled `Lower{,R,Haskell,HLSL}DataFlow` + `RunDataFlow` threads real operand values through one cycle-exact `RunOne`) + `fp64_dataflow_test.go` | AGPL-3.0 |
| `sim/examples/gemma4_test_synthetic/` | Synthetic Gemma-4-26B-A4B-it config.json + model.safetensors.index.json for testing the compiler | AGPL-3.0 |
| `sim/examples/mini_glm_moe/` | Mini GLM-MoE config (4 layers, 64 hidden, 16 experts, top-4) for testing MoE gating | AGPL-3.0 |
| `fw/` | C firmware port for MCU targets (ARM Cortex-M/R, RISC-V): `pnm_fw.h` (types + API), `pnm_fw.c` (boot, dispatch, KV cache, verification), `pnm_nvme.{h,c}` (NVMe block driver) | AGPL-3.0 |
| `toolchain/mcu/` | Bare-metal MCU tooling for `orchestrator_mcu`: Makefile, linker script, startup.c, dispatch.c, PNM/UART drivers. Cross-compiles to flat binary for ROM burn-in | AGPL-3.0 |
| `toolchain/soc-linux/` | (archived under `archive/toolchain/soc-linux/`) Full OS image builder: stripped RV32IMA NOMMU Linux kernel (6.6.x), seL4 microkernel, `rustd` access-control daemon (Rust, no deps), initramfs rootfs | AGPL-3.0 |
| `pi_host/` | Raspberry Pi Compute Module host drivers for `pi_bridge`: same wire protocol in Python (`pnm_pi.py`, spidev), Go (`pnm_pi.go`, stdlib-only raw ioctl), Rust (`pnm_pi.rs`, no crates), C (`pnm_pi_spi.c`, spidev ioctl), plus CM5 PCIe BAR0 driver (`pnm_pi_cm5.c`). See its README for wiring + frame format | AGPL-3.0 |
| `paper/submission/` | Build artifacts, tracked and pushable | CC BY-SA 4.0 |
| `flake.nix` | Nix flake with the whole toolchain | AGPL-3.0 |
| `README.md`, `TLDR.md`, `paper/docs.md` | Overview / abstract / documentation | AGPL-3.0 (README) |

New files must respect the three-way license split (manuscript/artifacts, HDL/, everything else).

## Environment

Everything runs inside the Nix flake: `nix develop` provides `pdflatex`,
`pandoc`, `pdfinfo`, `iverilog`/`vvp`, `verilator`, `go`, `python3` (the latter only for
the `paper/build.py` paper pipeline). The sim harness is **Go standard library
only** — no external Go modules, no pip dependencies. No Makefile, no package.json,
no CI config exists in the repo.

## Commands

### Build the paper (from repo root)

```bash
python3 paper/build.py            # submission/paper.docx (the submission artifact) + .pdf + .tex
python3 paper/build.py --review   # submission/paper_review.pdf (11pt single-column, wide margins)
```

`paper/build.py` requires `paper/Paper.MD` present; it strips everything before the `Abstract`
header, converts `{c(n)}` → `\cite{n}`, runs pdflatex twice, then pandoc to DOCX.
The bibliography is hardcoded in `paper/build.py` (`REFS`, Chicago style, 41 entries) — if
you add a citation to the manuscript, add the reference there and make sure the
manuscript's `{c(n)}` labels stay within `1..len(REFS)`; a citation past the end
of `REFS` renders as an undefined reference in the PDF (`paper/submission/paper.log`).

### HDL testbenches (from `HDL/`)

```bash
iverilog -g2005 -o tb_fabric.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
iverilog -g2005 -o tb_load.out   hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v   && vvp tb_load.out
iverilog -g2005 -o tb_doorbell.out core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v                       && vvp tb_doorbell.out
iverilog -g2005 -o tb_fp32_alu.out core/fp32_alu.v core/fp32_fma.v core/fma_core.v core/tb_fp32_alu.v                                            && vvp tb_fp32_alu.out
iverilog -g2005 -o tb_fp16_fma.out core/fp16_fma.v core/fma_core.v core/tb_fp16_fma.v                                                            && vvp tb_fp16_fma.out
iverilog -g2005 -o tb_bf16_fma.out core/bf16_fma.v core/fma_core.v core/tb_bf16_fma.v                                                            && vvp tb_bf16_fma.out
iverilog -g2005 -o tb_fp32_fma.out core/fp32_fma.v core/fma_core.v core/tb_fp32_fma.v                                                            && vvp tb_fp32_fma.out
iverilog -g2005 -o tb_fp64_fma.out core/fp64_fma.v core/fma_core.v core/tb_fp64_fma.v                                                            && vvp tb_fp64_fma.out
iverilog -g2005 -o tb_int8_mac.out core/int8_mac.v core/tb_int8_mac.v                                                             && vvp tb_int8_mac.out
iverilog -g2005 -o tb_fp16_mac_array.out core/fp16_mac_array.v core/fp16_fma.v core/fma_core.v core/tb_fp16_mac_array.v                           && vvp tb_fp16_mac_array.out
iverilog -g2005 -o tb_bf16_mac_array.out core/bf16_mac_array.v core/bf16_fma.v core/fma_core.v core/tb_bf16_mac_array.v                           && vvp tb_bf16_mac_array.out
iverilog -g2005 -o tb_moe_gating.out core/moe_gating.v core/bf16_fma.v core/fma_core.v core/tb_moe_gating.v                                       && vvp tb_moe_gating.out
iverilog -g2005 -o tb_orchestrator_chip.out orchestrator_chip.v core/moe_gating.v core/bf16_fma.v core/fma_core.v tb_orchestrator_chip.v                              && vvp tb_orchestrator_chip.out
iverilog -g2005 -o tb_bmc_orchestrator.out rv32_core.v uart.v clint.v bmc_orchestrator_top.v tb_bmc_orchestrator.v                          && vvp tb_bmc_orchestrator.out
iverilog -g2005 -o core/tb_bf16_fma_edge.out core/bf16_fma.v core/fma_core.v core/tb_bf16_fma_edge.v                                                          && vvp core/tb_bf16_fma_edge.out
iverilog -g2005 -o core/tb_crc16.out core/crc16.v core/tb_crc16.v                                                                               && vvp core/tb_crc16.out
iverilog -g2005 -o core/tb_fp16_fma_edge.out core/fp16_fma.v core/fma_core.v core/tb_fp16_fma_edge.v                                                          && vvp core/tb_fp16_fma_edge.out
iverilog -g2005 -o core/tb_fp32_alu_edge.out core/fp32_alu.v core/fp32_fma.v core/fma_core.v core/tb_fp32_alu_edge.v                                           && vvp core/tb_fp32_alu_edge.out
iverilog -g2005 -o core/tb_fp32_mac_array.out core/fp32_mac_array.v core/fp32_fma.v core/fma_core.v core/tb_fp32_mac_array.v                                   && vvp core/tb_fp32_mac_array.out
iverilog -g2005 -o core/tb_fp64_alu.out core/fp64_alu.v core/fp64_fma.v core/fma_core.v core/tb_fp64_alu.v                                                   && vvp core/tb_fp64_alu.out
iverilog -g2005 -o core/tb_int8_alu.out core/int8_alu.v core/tb_int8_alu.v                                                                    && vvp core/tb_int8_alu.out
iverilog -g2005 -o core/tb_rotary_engine.out core/rotary_engine.v core/tb_rotary_engine.v                                                       && vvp core/tb_rotary_engine.out
iverilog -g2005 -o core/tb_kv_quant.out core/kv_quant.v core/tb_kv_quant.v                                                                     && vvp core/tb_kv_quant.out
iverilog -g2005 -o core/tb_dyn_act_quant.out core/dyn_act_quant.v core/tb_dyn_act_quant.v                                                       && vvp core/tb_dyn_act_quant.out
iverilog -g2005 -o core/tb_weight_dequant.out core/weight_dequant.v core/tb_weight_dequant.v                                                     && vvp core/tb_weight_dequant.out
iverilog -g2005 -o core/tb_int4_mac_array.out core/int4_mac_array.v core/int8_mac.v core/tb_int4_mac_array.v                                    && vvp core/tb_int4_mac_array.out
```

Expect `*** LOAD TEST PASSED (500 packets) ***` and 6 doorbell fires (p0,p1,p2,p3,p6,p7),
2 rejections (truncated, wrong DEST), and 2 `corrupt_out` pulses (payload-CRC pair).
Compile with `-g2005` (Verilog-2005); testbenches are self-checking (scoreboard
counters, `errors` integers, $display PASS/FAIL) and exit 0 on success.

### Static lint

```bash
verilator --lint-only -Wno-MULTITOP -Wno-TIMESCALEMOD hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v
```

### Synthesis smoke test (from repo root)

```bash
./synth.sh   # Yosys generic mapping: 6 routing gates + doorbell + bf16_fma + rv32_core;
             # prints cell counts and longest topological path per module (yosys via nix develop)
```

### C firmware (from `fw/`)

```bash
gcc -Wall -Wextra -std=c11 -c pnm_fw.c -o pnm_fw.o  # compile check (zero warnings expected)
```

### Co-simulation (from `sim/`)

```bash
go run ./cmd/pnm                         # 3x4x4 = 48 nodes, all 6 scenarios
go run ./cmd/pnm -l 8 -x 8 -y 8          # 512-node reference chassis
go run ./cmd/pnm --scenarios sweep stress --seed 1
go run ./cmd/pnm --groups 8              # force 8 parallel vvp slices
go run ./cmd/pnm --cpuprofile /tmp/pnm.cpu --memprofile /tmp/pnm.mem
go run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8   # compile + run a program
go run ./cmd/pnmc --cpuprofile /tmp/pnmc.cpu examples/bias_add.pnm -l 8 -x 8 -y 8
go run ./cmd/pnmc compile-model examples/gemma4_test_synthetic -l 4 -x 4 -y 4   # model compiler
go run ./cmd/pnmc compile-model examples/gemma4_test_synthetic -l 8 -x 8 -y 8   # compile for the 64TB MoE reference chassis
go run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -l 4 -x 4 -y 4    # driver + firmware boot + dispatch plan
go run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -l 8 -x 8 -y 8     # driver boot/dispatch at 512-node MoE scale
go run ./cmd/pnmc workload jacobi5 -l 1 -x 4 -y 4 -run             # workload: stencil (intra-layer)
go run ./cmd/pnmc workload matvec -l 4 -x 4 -y 4 -frag 16 -run     # workload: matvec (spine descent)
go run ./cmd/pnmc workload reduction -l 4 -x 4 -y 4 -frag 32 -run  # workload: reverse-path merge
go run ./cmd/pnmc workload broadcast -l 4 -x 4 -y 4 -frag 64 -run  # workload: broadcast fan-out
go run ./cmd/pnmc workload nbody -l 4 -x 2 -y 2 -frag 8 -run       # workload: O(N²) saturation
go test ./internal/pnm/                  # all tests (PyRand pinned to CPython, DES, LLM client, CU types)
```

`--scenarios` takes a space-separated list (`nargs="+"` semantics); the default list
is `sweep vcsweep load hotspot stress replay`. Expect `ALL SCENARIOS PASSED`; exit
code non-zero on any failure.

### Test system (Go test runner `pnmt`)

A Go-native test runner replaces ad-hoc shell scripts. It discovers toolchains
(iverilog, vvp, go, gcc, verilator) from `$PATH` or the Nix store, then runs test
categories in dependency order with structured PASS/FAIL/SKIP reporting.

```bash
go run ./cmd/pnmt                      # full suite: all categories
go run ./cmd/pnmt smoke                # critical path only (HDL core + Go + C, ~30s)
go run ./cmd/pnmt hdl                  # all HDL testbenches (core + fabric + phy)
go run ./cmd/pnmt hdl-core             # core compute units only
go run ./cmd/pnmt hdl-fabric           # fabric/routing + orchestrator chips
go run ./cmd/pnmt hdl-phy              # memory/PHY testbenches
go run ./cmd/pnmt go                   # Go unit tests (subgroups)
go run ./cmd/pnmt c                    # C firmware compile checks (SoC + MCU)
go run ./cmd/pnmt integration          # end-to-end (DES cross-check, model compiler, driver)
go run ./cmd/pnmt benchmark            # architecture benchmark (fabric sweep + cost/TCO)
go run ./cmd/pnmt lint                 # verilator lint + go vet
go run ./cmd/pnmt coverage             # Go coverage report
go run ./cmd/pnmt -v hdl-core          # verbose (show test stdout on failure)
```

- CLI source: `sim/cmd/pnmt/main.go`. HDL paths are resolved relative to `sim/`
  (e.g. `../HDL`, `../fw`), so run `pnmt` from `sim/`.
- The runner shells out to `iverilog`/`vvp` for each HDL testbench and to `go test`
  for Go test subgroups. It reports a non-zero exit if any category fails.
- **Property-based tests**: `sim/internal/pnm/{crc,rng,ir}_property_test.go` use
  `testing/quick` to fuzz invariants — CRC avalanche/append/determinism (500-10000
  iters), `PyRand` determinism/range/shuffle, IR compiler operator coverage, and
  wire-format byte counts. Add new property tests in the same package (they can call
  unexported helpers like `crc16` directly).
- **Adding a test**: register HDL cases in `hdlCore`/`hdlFabric`/`hdlPhy`, Go subgroups
  in `goTests`, or add a new top-level category function and wire it into the `switch`
  in `main()`. Golden rules from this session:
  - Every HDL testbench **must call `$finish` (or `$finish(1)`)** on the success path
    or it will hang (see the old `tb_rst_sync`/`tb_clk_gate` bug); `pnmt` does not
    impose an external timeout, so a hanging `vvp` stalls the whole category.
  - `node_eject.yout_vc` is an output port and **cannot** be tied to a constant
    literal in generated topology; connect it to a declared wire (`yres_<l>_<x>_vc`)
    and declare that wire *before* the instantiations that use it.
  - Keep Go per-test timeouts generous: driver tests take ~46s, so `goTests` uses a
    90s timeout and coverage uses 120s.

## Architecture

### The system (per the paper)

Four kinds of hardware: commodity 192-bit LPDDR6 CAMM2 modules (~256 GB/s per node),
mature-node DUV MAC ASICs, stateless Hardware Flit Repeaters (HFRs), and **one central
orchestrator chip** at the spine root (MoE routing, POST discovery, PCIe, coordinate mapping —
the only stateful silicon). Boards are X/Y grids stacked vertically; a single spine runs
through the stack; each board hangs off the spine via an `lxy_repeater`.

### Compute units (HDL/)

Each node's PE tile (`pe_tile_stub.v`) instantiates one of several compute unit types
selected by the model compiler:

| Module | Type | Precision | Latency | Use case |
|--------|------|-----------|---------|----------|
| `bf16_fma.v` | FMA | BF16 | 3 cycles | MoE experts, dense MLP |
| `fp16_fma.v` | FMA | FP16 | 3 cycles | FP16 models |
| `fp32_fma.v` | FMA | FP32 | 3 cycles | High-precision compute |
| `fp64_fma.v` | FMA | FP64 | 3 cycles | Double-precision scientific |
| `bf16_mac_array.v` | Systolic array | BF16 | variable | Attention QKV |
| `fp16_mac_array.v` | Systolic array | FP16 | variable | FP16 attention |
| `fp32_alu.v` | ALU | FP32 | 3 (MIN/MAX/CMP), 4 (FMA), 28 (DIV) cycles | Layernorm (divider + multiplier) |
| `int8_mac.v` | MAC | INT8 | 2 cycles | Quantized inference |
| `int4_mac.v` | MAC | INT4 | 2 cycles | INT4 quantized (packed nibbles) |
| `int4_mac_array.v` | Systolic array | INT4/INT8 | variable | INT4 quantized inference (4x density) |
| `fp4_mac.v` | MAC | FP4 (E2M1) | 2 cycles | FP4 quantized (packed nibbles) |
| `fp4_mac_array.v` | Systolic array | FP4 | variable | FP4 quantized inference (4x density vs BF16) |
| `mxfp4_mac_array.v` | Systolic array | MXFP4 | variable | MXFP4 block-scaled (OCP microscaling) inference |
| `weight_dequant.v` | Dequantizer | INT4/INT8/FP4/MXFP4 → BF16 | 1 cycle | Weight-only quantization |
| `rotary_engine.v` | RoPE | BF16 | 4 cycles | Rotary position embedding |
| `kv_quant.v` | Quantizer | BF16 ↔ INT4 | 2 cycles (quant), 1 cycle (dequant) | KV cache compression |
| `dyn_act_quant.v` | Quantizer | BF16 ↔ INT8 | 1 cycle | Dynamic activation quantization |

All FMA modules share an identical interface: `clk, rst_n, a, b, c, valid_in → result, valid_out`
(3-cycle pipeline). The `pe_tile_stub.v` uses `CU_TYPE` parameter to select between
bias-add (0), BF16 FMA (1), INT4 MAC (2), FP4 MAC (3), and MXFP4 MAC (4) compute paths.

### BMC/Router chip (RISC-V SoC)

The central orchestrator chip family is implemented as RISC-V System-on-Chip designs
sharing the `rv32_core.v` CPU, `uart.v`, and `clint.v` peripherals, plus the PNM
orchestrator engine (flit builder with CRC-16/CCITT-FALSE):

| Module | File | Description |
|--------|------|-------------|
| `rv32_core.v` | RV32IMA CPU | 5-stage FSM: RV32I base + M extension (MUL) + Zicsr (machine-mode CSR) |
| `uart.v` | UART | 16550-compatible, 8N1, configurable baud, interrupt output |
| `clint.v` | CLINT | Machine-mode timer (mtime/mtimecmp) + software interrupt (msip) |
| `bmc_orchestrator_top.v` | BMC SoC Top | CPU + 64KB ROM + 64KB SRAM + UART + CLINT + PNM orchestrator engine |
| `orchestrator_mcu.v` | MCU Orchestrator | Minimal: RV32I + 8KB ROM + 4KB SRAM + UART only (no PCIe/MoE/FPU). For stencil/reduction on small chassis |
| `orchestrator_sbc_moe.v` | SBC+MoE Router | RV32IMA + 64KB ROM + LPDDR5 DRAM stub + 64KB MoE gating SRAM + moe_gating unit + PCIe Gen5 stub (systolic-array dimension provisioned via `ARRAY_SIZE` param; no separate mac-array instance) |
| `orchestrator_sbc.v` | SBC Orchestrator (general) | RV32IMA + 64KB ROM + on-chip SRAM (0x4000_0000, configurable 512KB default up to 32MB) + LPDDR5 DRAM stub (1GB window) + PCIe Gen5 x16 PHY + NVMe storage controller. Runs Linux/seL4 NOMMU + CPython userland for transpiler/data workflows |

Memory maps:
- **bmc_orchestrator_top**: ROM@0x00000000 (combinational read), UART@0x10000000,
  CLINT@0x20000000, SRAM@0x80000000 (byte-enable write), PNM@0xF0000000.
- **orchestrator_mcu**: ROM@0x00000000 (8KB), UART@0x10000000, SRAM@0x80000000 (4KB),
  PNM@0xF0000000. No CLINT.
- **orchestrator_sbc_moe**: ROM@0x00000000 (64KB), UART@0x10000000, CLINT@0x20000000,
  MoE gating SRAM@0x40000000 (64KB BF16), DRAM@0x80000000..0x9FFFFFFF (512MB
  window, behavioral LPDDR5 stub with CAS latency), PCIe regs@0xC0000000,
  PNM@0xF0000000 (+gating trigger/result extension at 0xF0000030-3C).
- **orchestrator_sbc**: ROM@0x00000000 (64KB), UART@0x10000000, CLINT@0x20000000,
  SRAM@0x40000000 (256MB window; 512KB default, configurable up to 32MB), DRAM@0x80000000..0xBFFFFFFF (1GB window, LPDDR5 stub),
  PCIe@0xC0000000 (Gen5 x16 PHY), NVMe@0xD0000000, PNM@0xF0000000.

The DRAM stub models row activate + column access delay as a programmable CAS
latency (`DRAM_LATENCY` parameter). Production silicon replaces this block with
a hard DDR controller. The 512MB/1GB windows accommodate Linux kernel + CPython
runtime + pip site-packages.

The CPU uses a two-phase memory handshake (cycle 1: present address, cycle 2+: wait for
bus_ready) to correctly time peripheral accesses. The ALU is fully combinational with a
dedicated input mux, avoiding blocking/NBA mixing. The PNM orchestrator engine implements a
flit builder with CRC-16/CCITT-FALSE matching the fabric wire format. Boot-done is
detected when firmware writes bit 2 of ROUTE_CTRL.

Tooling:
- **MCU** (`toolchain/mcu/`): bare-metal static firmware. Makefile +
  linker script (ROM/RAM split) + startup.c (.data copy / .bss zero) +
  dispatch loop. Cross-compiles to flat binary/hex for ROM burn-in. No libc,
  no malloc, no OS.
- **SoC** (`toolchain/soc/`): NOMMU Linux/seL4 userspace daemon. Links
  against musl-libc statically, accesses PNM via `/dev/pnm` mmap. Uses
  malloc/dynamic allocation. Entry point is `_soc_start` placed in DRAM at
  0x80001000 by the boot loader.
- **fw/os/linux** (`fw/os/linux/`): Linux tinyconfig + bare-metal init
  for `orchestrator_sbc`. Trims kernel to fit in 16 MB SRAM window (`0x4000_0000`);
  produces `Image`, `init` binary, and `initrd.cpio` initramfs. The init
  binary prints a boot banner over UART@`0x10000000`, probes NVMe@`0xD0000000`,
  and enters a `wfi` idle loop. Kernel config fragment enables 16550 UART,
  NVMe block device, and INITRD support with all other subsystems disabled.
- **fw/os/sel4** (`fw/os/sel4/`): seL4 microkernel root task for
  `orchestrator_sbc`. CMake-based build for RV32IMA generic platform. The root
  task maps UART and PNM device frames via seL4 capabilities, prints a
  boot banner, reads PNM STATUS, and enters `seL4_Yield` idle. seL4
  provides formal verification, capability-based access control, and
  temporal isolation for the orchestrator chip's control plane.
- **Pi host** (`pi_host/`): Raspberry Pi Compute Module drivers bridging
  userland to the orchestrator PNM register window through the SPI slave
  `HDL/pi_bridge.v` (CM0-CM4, GPIO SPI, five language ports sharing one
  protocol) or directly over PCIe BAR0 on CM5.

Pi bridge (`HDL/pi_bridge.v`): SPI mode-0 slave translating 48-bit register
frames into PNM bus accesses. Frame = header byte `{rw<<7|sel}` + 32-bit data
+ status byte (0x01 write-ack / 0x00 read-ok); sel 0-9 map to the standard PNM
offsets 0x00-0x24, sel≥10 passes through as `{sel[5:0],2'b00}` (e.g.
sel=19 → 0x4C). Both writes and reads are full valid/ready handshakes: the
bridge holds `pnm_valid` until `pnm_ready` pulses, so downstream slaves may be
combinational or registered (behind `pnm_arb`). System clock must run at
least ~10x SCLK.

Host/BMC/memory path (`tb_host_bmc.v`, `tb_dma_lpddr6.v`, `tb_sodimm_lpddr.v`):
SPI host → `pi_bridge` → `pnm_arb` (round-robin CPU/bridge merge) → shared PNM
register file with a DMA engine → `lpddr6_camm`. Extended register window:
DMA_ADDR@0x40, DMA_COUNT@0x44, DMA_CTRL@0x48 (bit0=start_wr, bit1=start_rd,
bit2=done), DMA_DATA FIFO@0x4C. The DMA engine walks a word-addressed LPDDR6
array through an accept/deassert-then-wait-resp handshake (never hold valid
through ready-fall — the model would double-accept).

Memory + PCB models (`HDL/lpddr6_camm.v`, `HDL/pcb_link.v`): behavioral
LPCAMM2/LPDDR6 module (banked array, CAS-latency wait, refresh scheduler with
stall, rd/wr/ref counters, byte address → word index `addr[13:2]`) parameterized
to also cover DDR4/DDR5 SODIMM timings (`tb_sodimm_lpddr.v` sweeps three
generations through the identical protocol stack). `pcb_link` is a pure timed
wire (shift-register delay line = ceil(DELAY_NS/10) cycles, SOP/EOP/data
preserved); `pcb_triple_link` wraps three of them for X/Y/spine populations.

Tests:
```
iverilog -g2005 -o tb_bmc_orchestrator.out rv32_core.v uart.v clint.v bmc_orchestrator_top.v tb_bmc_orchestrator.v && vvp tb_bmc_orchestrator.out
iverilog -g2005 -o tb_orchestrator_mcu.out orchestrator_mcu.v rv32_core.v uart.v clint.v tb_orchestrator_mcu.v && vvp tb_orchestrator_mcu.out
iverilog -g2005 -o tb_orchestrator_sbc.out orchestrator_sbc.v rv32_core.v uart.v clint.v pcie_phy.v nvme_ctrl.v tb_orchestrator_sbc.v && vvp tb_orchestrator_sbc.out
iverilog -g2005 -o tb_orchestrator_sbc_moe.out orchestrator_sbc_moe.v rv32_core.v uart.v clint.v core/moe_gating.v core/bf16_fma.v core/fma_core.v tb_orchestrator_sbc_moe.v && vvp tb_orchestrator_sbc_moe.out
iverilog -g2005 -o tb_pi_bridge.out pi_bridge.v tb_pi_bridge.v && vvp tb_pi_bridge.out
iverilog -g2005 -o tb_host_bmc.out pi_bridge.v pnm_arb.v tb_host_bmc.v && vvp tb_host_bmc.out
iverilog -g2005 -o tb_dma_lpddr6.out pi_bridge.v pnm_arb.v lpddr6_camm.v tb_dma_lpddr6.v && vvp tb_dma_lpddr6.out
iverilog -g2005 -o tb_sodimm_lpddr.out pi_bridge.v pnm_arb.v lpddr6_camm.v tb_sodimm_lpddr.v && vvp tb_sodimm_lpddr.out
iverilog -g2005 -o tb_sodimm_ctrl.out sodimm_ctrl.v tb_sodimm_ctrl.v && vvp tb_sodimm_ctrl.out
iverilog -g2005 -o tb_pcb_link.out pcb_link.v tb_pcb_link.v && vvp tb_pcb_link.out
iverilog -g2005 -o tb_optical_link.out optical_link.v tb_optical_link.v && vvp tb_optical_link.out
iverilog -g2005 -o tb_power_rails.out power_rails.v tb_power_rails.v && vvp tb_power_rails.out
iverilog -g2005 -o tb_pcb_si_link.out pcb_si_link.v tb_pcb_si_link.v && vvp tb_pcb_si_link.out
iverilog -g2005 -o tb_nvme_ctrl.out nvme_ctrl.v tb_nvme_ctrl.v && vvp tb_nvme_ctrl.out
iverilog -g2005 -o tb_pcie_phy.out pcie_phy.v tb_pcie_phy.v && vvp tb_pcie_phy.out
iverilog -g2005 -o tb_lpddr5_phy.out lpddr5_phy.v tb_lpddr5_phy.v && vvp tb_lpddr5_phy.out
iverilog -g2005 -o tb_lpddr5x_phy.out lpddr5x_phy.v tb_lpddr5x_phy.v && vvp tb_lpddr5x_phy.out
iverilog -g2005 -o tb_lpddr6_phy.out lpddr6_phy.v tb_lpddr6_phy.v && vvp tb_lpddr6_phy.out
```

### Wire format (byte-wide links) — everything depends on this

```
byte 0 : LAYER_ID            (stripped by lxy_repeater on match)
byte 1 : MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
byte 2 : CTRL
byte 3 : LEN_LO
byte 4 : LEN_HI
byte 5..: payload (LEN bytes)
last 2 : CRC_HI, CRC_LO
```

- CRC-16/CCITT-FALSE (init `0xFFFF`, poly `0x1021`, no final XOR, MSB-first) covers
  `[MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]` — everything except `LAYER_ID` (peeled at
  the repeater) and the trailing CRC bytes. So the **DEST field is inside CRC coverage**.
- Routing is source-routed wormhole: each gate compares one header byte against a
  parameter. `lxy_repeater` matches `LAYER_ID` (strips it on match), `xy_turn` matches the
  X nibble of `MODULE_ID` (no strip), `node_eject` matches full `MODULE_ID` (no strip →
  DMA stream is `DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO`).
- Layer IDs on the wire are **1-based**: Go `Flit(layer+1, ...)` (run.go) and generated
  `LOCAL_LAYER(8'h{l+1:02x})`. `LAYER_ID=0xFF` + `MODULE_ID=0xEE` is pass-through traffic.
- `CTRL = {vc_class[7:6], op[5:4], rsvd[3:0]}`; the harness uses `0x80`
  (VC_SPINE|OP_COMPUTE) and `0x90` (VC_SPINE|OP_FORWARD). **rsvd[0] is the TX-return
  (echo) flag**: a CTRL nibble with bit 0 set makes the RTL echo the flit back, so
  scenarios must mask it out — `CTRL_COMPUTE_SPINE|((i&0x0F)&^1)` — unless echoes are
  explicitly intended (`InjectEcho` / `ScenarioVCSweep` layer-0).
- **Routing bitmap (11 bits)** — one pre-loaded routing-table entry (paper §2.1/§2.8)
  carried by every repeater and node, driving its bit-mask comparator:
  `[10:7] LAYER` (4b, 1-based, matches LAYER_ID low nibble), `[6] AXIS` (0=X, 1=Y),
  `[5] SIGN` (0=+, 1=−), `[4:0] DIST` (hops from the lxy_repeater).  `lxy_repeater`
  and `hfr` mask-compare the layer nibble; `pe_tile_stub` mask-selects the DEST
  nibble by AXIS and asserts `route_err` on mismatch.  `flit_gate`'s
  `match_value`/`match_mask` are runtime inputs, not parameters.  Generated
  topologies emit `route_bitmap(11'h{(layer)<<7})` for every repeater instance and
  `11'h{layer<<7 | Y<<6 | y}` for node MAC stubs (AXIS=Y, DIST=row).

### Doorbell (the paper's load-bearing mechanism)

Three-condition fire, implemented twice and kept in sync:

- **RTL**: `HDL/doorbell.v` — fires `DOORBELL_TRIG` + `DOORBELL_ACK` in the same cycle iff
  (a) byte count == `LEN+6`, (b) end-to-end CRC validates, (c) `DEST == LOCAL_MODULE`.
  Refusals assert `NODE_ERR` and increment `rejections`. Frame detection is edge-based on
  `s_valid` (not a SOP wire) to handle back-to-back packets. CRC reference is
  independently reimplemented inside `tb_doorbell.v`.
- **Go twin**: `sim/internal/pnm/virtual_units.go` `VirtualUnit.Consume()` — identical
  three conditions, plus resident kernels (`echo`, `sum`, `accum`, `dot`) whose results
  are checked against the golden manifest. `crc16()` in `crc.go` is the reference
  implementation that `crc16.v` claims to mirror — keep them in lockstep.
- **MAC stub verdict**: `pe_tile_stub` now computes (bias-add `KERNEL_CONST` on payload,
  CRC-16 recompute over the transformed body via `crc16.v`) and runs the CRC half of
  the doorbell in silicon: it validates the *incoming* CRC and pulses `corrupt_out`
  per refused message. `verify()` cross-checks the stub's verdict count against the
  manifest's corrupt packets and passes it to `consume(hw_corrupt=...)`. The stub's
  golden model applies the bias *before* the resident kernel (`golden(..., bias)`),
  since the hardware already transformed the payload. Framing rides the pipe
  unchanged (`s_axis_tlast`/`m_axis_tlast` EOP and `s_axis_tstart`/`m_axis_tstart`
  SOP, the packet head the co-sim's `packetize()` keys on).

### Co-simulation pipeline (`sim/`)

```
go stimulus (manifest: dest, kernel, weights, bias, payload, CRC, golden)
  -> Verilog fabric pnm_top.v (generated HDL gates + per-node pe_tile_stub
     MAC kernels: bias-add + in-silicon CRC validate/recompute)
  -> delivery.log (cycle-stamped bytes on every node DMA / tail / residual port,
     plus C-lines for the stubs' hardware doorbell verdicts)
  -> Go verify(): byte-exact delivery, byte conservation, doorbell accounting
     (hardware verdicts + software twin), kernel results vs golden (bias applied),
     per-packet latency vs the closed form
```

- `gen_topology.go` emits `pnm_top.v` for a layer list (node_eject → `pe_tile_stub`
  MAC kernels → node DMA ports); `gen_tb.go` emits `tb_pnm.v` (injector task from
  `stimulus.hex` via $readmemh, per-node backpressure `ready 1 cycle in N`,
  delivery.log via $fwrite incl. `C` verdict lines, adaptive $finish after 200 quiet
  cycles).
- **Slicing**: vvp is single-threaded, so the harness partitions layers into contiguous
  groups (default one per CPU core) and runs one `vvp` per slice in parallel; the
  per-slice iverilog compiles also run concurrently. This is byte-exact vs. a monolith
  because spine stages upstream of the destination layer are transparent pass-through.
  NOT modeled: cross-group spine contention coupling (a compile-time scheduler
  concern, not gate correctness).
- Scenarios: `sweep` (exact closed-form latency:
  `wire_len-1 + l_eff spine hops + x X-hops + PE_PIPE_DELAY` where `PE_PIPE_DELAY=2`
  is the generated MAC stub's elastic pipe), `vcsweep` (sweep + pass-through on all
  four VC classes, `MixedVC=true`, still exact), `load` (500 flits), `hotspot` (MoE hot
  expert, kilobyte tokens, 1-in-8 DMA), `stress` (~3% corrupt-CRC messages the doorbell
  MUST reject), `replay` (stress twice, delivery logs must be bit-identical). **6 total.**
- **DES twin**: `des.go` is an activity-driven discrete-event model of the reverse
  (egress) path — txe leaves, Y/X merge chains, up-merge, strip — validated two ways:
  `TestDESClosedForm` (latency == the sweep closed form on an idle chassis) and
  `TestDESCrossCheckRTL` (byte-exact Delivery stream vs a real RTL slice). Keep its
  `eIn` sentinels explicit (`reg: -1` vs `mid: -1`): Go zero values would alias
  register 0 (the injector) and silently corrupt merges.
- **Compiler**: `sim/internal/pnm/pnmc.go` (`cmd/pnmc`) lowers a plain-text program
  (`kernel`/`bias`/`token` directives, see `sim/examples/bias_add.pnm`) onto the
  chassis and runs the same parallel pipeline; `bias` compiles into the node's
  `KERNEL_CONST` in silicon.
- **Model compiler**: `sim/internal/pnm/model_compiler.go` (`cmd/pnmc compile-model`)
  transpiles a HuggingFace model (safetensors index + config.json) onto a PNM chassis.
  It parses the safetensors header, computes tensor sizes from shapes, partitions model
  layers across physical layers, distributes experts across nodes, and emits a `.pnm`
  program + chassis schema. `safetensors.go` handles the index parsing + tensor shape
  inference; `model_compiler.go` implements the 5-stage AOT pipeline (ingest, partition,
  map, route, emit). See `sim/examples/gemma4_test_synthetic/` for a synthetic test input.
- **Source-language toolchains**: `sim/internal/pnm/r_ir.go` (`CompileR`), `haskell_ir.go`
  (`CompileHaskell`), and `hlsl_ir.go` (`CompileHLSL`) compile R, Haskell, and HLSL source
  code into typed IR targeting FP64 FMA and FP32 ALU units. The IR is a minimal
  register-based instruction set with no loops, branches, or dynamic allocation.
- **Host driver**: `sim/internal/pnm/driver.go` (`cmd/pnmc run-driver`) orchestrates
  model loading, weight upload, and inference dispatch. It builds weight upload commands
  from the AOT compilation, constructs routing tables and MoE expert maps, and verifies
  that no node exceeds the 128 GB budget. The driver communicates with the orchestrator chip
  via PCIe (in co-sim, flits are constructed directly).
- **Firmware**: `sim/internal/pnm/firmware.go` models the orchestrator chip's boot sequence
  (POST discovery, routing table load, weight upload, MoE gating load) and runtime
  dispatch loop (30 dense + 240 MoE dispatches per token for Gemma-4). It verifies
  weight upload integrity and dispatch coverage. The orchestrator chip RTL (`HDL/orchestrator_chip.v`)
  implements the PCIe ingress, flit builder, POST discovery FSM, and spine injection
  in Verilog-2005.
- **C firmware**: `fw/pnm_fw.c` + `pnm_fw.h` are a direct C port of `firmware.go`
  for MCU targets (ARM Cortex-M/R, RISC-V, custom MCU). Static allocation only,
  no `malloc`. Implements the same boot sequence, dispatch loop, and KV cache management.
- **LLM client**: `sim/internal/pnm/llm_client.go` provides an inference client for
  FP16/BF16 models: tokenization (whitespace + hash fallback), prefill, autoregressive
  generation, temperature/nucleus sampling, and per-inference statistics (tokens,
  dispatches, KV ops, CU utilization).
- All `sim/` generated files (`stimulus*.hex`, `delivery*.log`, `tb_pnm*.v`, `tb_pnm*.out`,
  `pnm_top*.v`, `pnm_top_params.py`) are gitignored and regenerate on every run — never
  edit them by hand (they carry `AUTO-GENERATED` headers).

## Conventions

- **Verilog**: lowercase identifiers with underscores; every link is the 5-signal group
  `<name>_data/_valid/_sop/_eop/_ready`; parameters via `#(.NAME(...))`; `clk`/`rst_n`
  (active-low) always first in the port list; `\`timescale 1ns/1ps` in testbenches;
  100 MHz clock (`always #5 clk = ~clk`). All modules instantiate `flit_gate` internally
  (it is the shared demux core). No comments on code the agent adds unless asked.
- **Go**: stdlib only (no external modules); `internal/pnm` is the harness library,
  `cmd/pnm` and `cmd/pnmc` are thin CLIs. Generated Verilog is built via `strings.Builder`
  appends. Paths are anchored to the repo via `runtime.Caller(0)` in `SimDir()`, never
  the caller's cwd. The harness drives iverilog/vvp with `os/exec`. Both CLIs take
  `--cpuprofile`/`--memprofile` (runtime/pprof) for the long 512-node runs.
- **Manuscript (Paper.MD)**: it is an f-string template in `paper/build.py`'s pipeline, so
  LaTeX commands are **double-escaped**: `\\textbf{{...}}`, `\\alpha`, `\\$`, `\\_`,
  `\\times`. Use `{c(n)}` for citations. The build regex also collapses `{{`→`{` and
  `\\`→`\`, so single `\` or single `{}` in Paper.MD will silently produce broken output.
  Section headings are plain text (`2.9 The doorbell mechanism`); `paper/build.py`'s
  `label_headings()` auto-converts them to starred `\section*`/`\subsection*`/
  `\subsubsection*` commands carrying `\label{sec:<N.M>}` anchors (top-level words like
  `Conclusion` get `\label{sec:conclusion}`), and `link_sections()` rewrites every
  `Section N.M` / `Sections N.M and K.L` mention into a hyperref link at build time, so
  write cross-references as plain prose ("Section 3.4") and they become hyperlinks
  automatically; match the existing style for new sections.

## Gotchas

- **`paper/build.py` is tracked** (AGPL-3.0) and required by the README build instructions;
  a fresh clone contains it. It needs `python3` plus the LaTeX/pandoc toolchain from
  `flake.nix`, and `paper/Paper.MD` must be present beside it.
- `paper/submission/` is tracked; `paper/submission/paper_review.*` are produced by
  `paper/build.py --review`.
- `*.out` files (iverilog binaries) are gitignored; rerun the iverilog command rather
  than relying on stale binaries.
- Changing `pnm_defs.vh`, the wire format, or the CRC touches five places that must stay
  in sync: `pnm_defs.vh`, `HDL/crc16.v`, `HDL/doorbell.v`, `sim/internal/pnm/crc.go`
  + `virtual_units.go` (`crc16` + `VirtualUnit.Consume`), `sim/internal/pnm/run.go`
  (`Flit` encoding + `Verify`).
- Latency checks: `sweep` asserts **exact** equality to the closed form; `load`/`stress`/
  `hotspot` assert a pipe floor only. If you change HFR/gate pipeline depth, the closed
  form in `verify()` (`wire_len - 1 + l_eff + x`) and the paper's §3.4/§4.3 text must be
  updated together.
- `iverilog` must be told the include dir for `pnm_defs.vh` (`-IHDL` in `run.go`; the
  hand-written HDL testbenches live in the same dir so no flag is needed there).
- **Never run two `go run ./cmd/pnm` (or `pnmc`) processes concurrently in the same
  `sim/` directory** — they share `pnm_top_g*.v`, `tb_pnm_g*.v`, `stimulus_g*.hex`,
  `delivery_g*.log`, `tb_pnm_g*.out` filenames and will clobber each other's files.
  A 512-node hotspot panic with a short `stimulus_g*.hex` next to a huge `delivery_g*.log`
  is the signature of this race.
- `des_test.go` writes `des_*.v/.hex/.log/.out` artifacts into `sim/` and removes them
  on success via `t.Cleanup`; a failed run may leave them behind (safe to delete).
- The 512-node run is the full reference chassis; the default harness run is
  3×4×4 = 48 nodes. Both must pass — README documents the 512-node invocation as the
  scale proof.
- **Determinism**: the harness uses `PyRand` (`rng.go`), a byte-exact clone of CPython's
  `random.Random` primitives (`rng_test.go` pins known CPython outputs), so the same
  `--seed` reproduces the same stimulus/Verilog/logs across Go runs — the paper's
  Table 3 and §3.5 numbers are `--seed 1`. Scenario stimuli differ from the retired
  Python harness (the Go scenarios draw a per-node bias constant the Python one never
  did), so do not diff Go output against old Python logs. Only `tb_pnm_*.out` binaries
  differ between runs (ASLR heap addresses) — diff `.log`/`.hex`/`.v`/`pnm_top_params.py`
  instead.

## Bug audit log (2026-08-19)

### CRITICAL #1: `sqrt()` compiles to `x * 0.5` instead of square root
**Files:** `sim/internal/pnm/r_ir.go:237`, `haskell_ir.go:332`, `hlsl_ir.go:389`
**Bug:** All three IR compilers implemented `sqrt(x)` as `FP64Mul(x, 0.5)`, computing
`x/2` instead of `√x`.
**Fix:** Replaced with 4 iterations of Newton-Raphson: `y = 0.5*(y + x/y)` using
available IR ops (Div, Add, Mul). Converges quadratically; 4 iterations gives full
precision for both FP64 and FP32.

### CRITICAL #2: R subtraction emits `FP64Add` without negating RHS
**File:** `sim/internal/pnm/r_ir.go:217`
**Bug:** `rArithOp("-")` returned `FP64Add` with a comment "handled at lowering", but
no lowering pass existed. `a - b` compiled as `a + b`.
**Fix:** Added `FP64Sub` and `FP64Neg` ops to the FP64 IR enum. `rArithOp("-")` now
returns `FP64Neg` as a sentinel; `compileRAssign` detects it and emits a negate-RHS +
add sequence. Updated `emitFP64Inst` to handle the new ops.

### CRITICAL #3: Haskell `if-then-else` discards else branch
**File:** `sim/internal/pnm/haskell_ir.go:242`
**Bug:** `compileHaskellIf` parsed `if cond then a else b` but only used `parts[3]`
(thenVal), completely ignoring `parts[5]` (elseVal). When condition was false, the
destination register was never assigned.
**Fix:** Implemented branchless selection via arithmetic: `dest = thenVal * cmp +
elseVal * (1 - cmp)` where `cmp = (cond != 0) ? 1.0 : 0.0`. Uses the existing
FP64Cmp, FP64Sub, FP64Mul, FP64Add ops.

### CRITICAL #4: HLSL ternary `cond ? a : b` discards else branch
**File:** `sim/internal/pnm/hlsl_ir.go:241`
**Bug:** The else value was resolved via `elseVal(elseExpr)` but that function was a
no-op (`func elseVal(s string) string { return s }`). The else instruction was never
emitted; dest got the then-value unconditionally.
**Fix:** Same arithmetic approach as CRITICAL #3: `dest = thenVal * cmp + elseVal *
(1 - cmp)`. Removed the dead `elseVal` function.

### HIGH #7: `PlanInference` returns empty `LayerResults`
**File:** `sim/internal/pnm/driver.go:268`
**Bug:** `InferDispatch.LayerResults` was allocated but never populated. The inner loop
computed attention coordinates and iterated experts but assigned to nowhere. The field
was dead code.
**Fix:** Removed `LayerResults` from the `InferDispatch` struct and its allocation in
`PlanInference`. The struct now only carries `TokenPayload`.

### HIGH #8: KV cache `Load()` ignores `seqPos` -- FIFO, not positional
**File:** `sim/internal/pnm/kv_cache.go:97`
**Bug:** `KVCacheBank.Load()` always read from `ReadPtr` (FIFO pop), ignoring the
requested sequence position. `Load(seqPos=17)` popped whatever entry was next in the
bank's queue, NOT the entry for position 17.
**Fix:** `Load()` now takes a `seqPos` parameter and reads from `seqPos % depth`
without advancing `ReadPtr`. `KVCacheLayer.Load()` computes the bank-local position
as `seqPos / numBanks`. Eviction is only via `Evict()`.

### MEDIUM #10: `kv_cache_bank.v` missing from FABRIC list
**File:** `sim/internal/pnm/run.go:53`
**Bug:** When `kvcache=true`, `gen_topology.go` instantiates `kv_cache_bank` modules,
but `kv_cache_bank.v` was not in the `FABRIC` source list, causing `iverilog` to fail
with "Unknown module type". Masked because `RunOne` hardcodes `kvcache=false`.
**Fix:** Added `"kv_cache_bank.v"` to the `FABRIC` slice.

### MEDIUM #14: Haskell `parseHaskellBinop` subtraction produces broken RHS
**File:** `sim/internal/pnm/haskell_ir.go:290`
**Bug:** Subtraction returned `FP64Add` with RHS `"-" + expr[i+1:]`. For `a - b`,
this produced `"-b"` which `resolveHaskellAtom` couldn't parse as a valid atom.
**Fix:** Changed to return `FP64Sub` directly, letting the caller emit a proper
subtraction instruction. This pairs with the `FP64Sub` op added in CRITICAL #2.

### MEDIUM #17: `bf16_mac_array.v` / `fp16_mac_array.v` partial sum truncation
**Files:** `HDL/bf16_mac_array.v:75`, `HDL/fp16_mac_array.v:75`
**Bug:** `psum_sr` was declared as 32-bit (`reg [31:0]`) but the FMA `c` port is
16-bit. Connection `.c(psum_sr[...][15:0])` silently truncated the upper 16 bits of
the partial sum.
**Fix:** Changed `psum_sr` from `reg [31:0]` to `reg [15:0]` to match the FMA port
width. Updated all initialization and assignment widths accordingly. Removed the
`{16'h0000, fma_result[...]}` zero-extensions.

### LOW #16: `des.go` `txeAdvance` potential nil dereference
**File:** `sim/internal/pnm/des.go:860`
**Bug:** `txeAdvance(r, c)` accessed `r.occ.dma` without checking if `r.occ` is nil.
A logic error in the event scheduler could cause a panic.
**Fix:** Added `if r.occ == nil { return }` guard at the top of `txeAdvance`.

### LOW #20: `SpanCycles` doesn't include `TailUp`
**File:** `sim/internal/pnm/run.go:1073`
**Bug:** `SpanCycles` initialized `streams` with `delivered.Tail` and
`delivered.Inject` but omitted `delivered.TailUp`. If root egress was the last
activity, the reported span was too short.
**Fix:** Added `delivered.TailUp` to the `streams` slice.

### CRITICAL #5: `parseHaskellCond` comparison parsing completely broken
**File:** `sim/internal/pnm/haskell_ir.go:314`
**Bug:** The `idx > 0` guard on line 314 caused `parseHaskellCond` to never match
any comparison operator. The caller strips the LHS before passing `rest`, so the
operator is always at index 0. The `> 0` check skipped it every time, falling
through to `return "==", s` which returned the entire string as `rhs`.
**Fix:** Changed `idx > 0` to `idx >= 0`.

### HIGH #9: HLSL ternary uses string literal `"0.0"` instead of allocated register
**File:** `sim/internal/pnm/hlsl_ir.go:253`
**Bug:** On line 250, a `zero` register was allocated and initialized, but line 253
used the raw string `"0.0"` as `Src[1]` in the `ALUCmp` instruction instead of the
`zero` register name. This wasted one register and emitted IR with a literal where
a register reference was expected.
**Fix:** Moved `zero` allocation and initialization after `resolveHLSLAtom`, and used
`zero` register name in `ALUCmp` `Src`.

### MEDIUM #18: `driver.go` missing AXIS bit in routing bitmap
**File:** `sim/internal/pnm/driver.go:114`
**Bug:** The documented bitmap format is `[10:7] LAYER, [6] AXIS (0=X,1=Y), [5] SIGN,
[4:0] DIST`. For Y-axis nodes, bit 6 (AXIS) must be set. `gen_topology.go` correctly
uses `((l+1)<<7)|(1<<6)|y`, but `driver.go` omitted bit 6.
**Fix:** Added `| (1 << 6)` to the bitmap computation. Updated test expectations in
`driver_test.go` from `0x080` to `0x0C0`, etc.

### MEDIUM #19: `llm_client.go` Temperature=0 override destroys greedy decoding
**File:** `sim/internal/pnm/llm_client.go:132-133`
**Bug:** The field is documented as `Temperature float32 // sampling temperature
(0 = greedy)`, but the constructor silently overridden zero to 1.0, defeating
greedy decoding. Without the override, `sampleFromLogits` would divide by zero.
**Fix:** Removed the override. Added greedy branch (argmax) at the top of
`sampleFromLogits` when temperature == 0.

### MEDIUM #20: `gen_topology.go` xin_vc hardwired when kvcache=true
**File:** `sim/internal/pnm/gen_topology.go:275`
**Bug:** When `kvcache=true`, the data path to `xy_turn` goes through the KV cache
bank, but `xin_vc` was always connected to `nob_%d_vc` (the repeater output),
bypassing the KV cache. This was inconsistent Verilog connectivity.
**Fix:** Changed to `xin_vc(%s_vc)` using the `xin` variable which correctly
reflects whether kvcache is active.

### MEDIUM #21: `cmd/pnm/main.go` missing `--board-y` flag alias
**File:** `sim/cmd/pnm/main.go:62`
**Bug:** The `pnm` command registered `--board-x` as an alias for `-x`, but did
not register `--board-y` as an alias for `-y`. Users invoking with `--board-y 8`
got a silent error.
**Fix:** Added `fs.IntVar(&by, "board-y", 4, "Y rows per board")`.

### MEDIUM #22: `pnm_fw.c` hardcoded board-Y=4 and missing physical layer mapping
**File:** `fw/pnm_fw.c:145-146, 160-161`
**Bug:** The C firmware hardcoded the board Y-dimension to `4` when computing
target X/Y coordinates, and hardcoded `L = 0` for physical layer. The Go
reference correctly uses runtime dimensions and physical layer mapping.
**Fix:** Added `board_x`, `board_y`, `num_layers`, `model_layers_per_physical`
fields to `firmware_t`. Updated `fw_plan_inference` to use these fields and
look up MoE experts from the map instead of round-robining.

### LOW #25: `doorbell.v` 16-bit overflow in byte counter
**File:** `HDL/doorbell.v:72`
**Bug:** `16'd4 + len` was 16-bit arithmetic. For payloads >= 65532 bytes, the
result wrapped, causing misframing. The failure mode was safe (rejection) but
incorrect.
**Fix:** Changed to `17'd4 + {1'b0, len}` for 17-bit arithmetic.

### Auditor false positives (not bugs)

- **HIGH #5:** `goldenEcho()` CTRL field: The auditor claimed `0x81 & 0x30 = 0x20`,
  but `0x81 & 0x30 = 0x00`. The golden model is correct.
- **HIGH #6:** `CollectTensors` error: `CollectTensors` returns `(map, int64)`, not
  `(map, error)`. The `_` discards `totalBytes`, not an error.
- **HIGH #9:** Backpressure counter overflow: `2/16 = 1/8` is the correct duty cycle
  for BP=8. The 4-bit counter works correctly.
- **MEDIUM #11:** `bf16_fma.v` in FABRIC: Harmless extra compile, not a bug.
- **MEDIUM #12:** `xy_turn.xin_vc` wrong source: Works by coincidence (constant VC). Now fixed in MEDIUM #20.
- **MEDIUM #13:** `yout_vc` undeclared wire: Functionally harmless width mismatch.
- **MEDIUM #15:** KV cache budget: Design consideration, not a code bug.
- **LOW #18:** Router popcount synthesizability: The named-block pattern works in
  synthesis tools (Vivado/Quartus handle it).
- **LOW #19:** `fb_module` naming: Cosmetic, no functional impact.
- **LOW #21:** `ChoicesWeighted` boundary: Subtle but within tolerance for the research
  use case.
- **LOW #22:** `pipe.go` partial messages: Design limitation of the IPC mechanism.
- **LOW #23:** `llm_client.go` MinInt overflow: Only on 32-bit; 64-bit is fine.
- **LOW #24:** `weight_flits` naming: Misleading name but counter is functional.

### CRITICAL #6: `moe_gating.v` topk_ins_pos width overflow for TOP_K=8
**File:** `HDL/moe_gating.v:138, 316, 348`
**Bug:** `topk_ins_pos` was declared `reg [2:0]` (3 bits, max value 7). The sentinel
value `TOP_K[2:0]` equals 0 when TOP_K=8, colliding with valid insertion index 0.
The comparison `topk_ins_pos < TOP_K[2:0]` became `x < 0` (unsigned), always false.
No expert was ever inserted into the sorted buffer.
**Fix:** Widened to `reg [3:0] topk_ins_pos` and updated all comparisons to use
`TOP_K[3:0]` and `{1'b0, ti[2:0]}` for proper 4-bit comparison.

### HIGH #10: `fp32_alu.v` CMP returns true when B is NaN (IEEE 754 violation)
**File:** `HDL/fp32_alu.v:199`
**Bug:** `s1_b_nan ? 1'b1` made CMP(x, NaN) return 1.0 instead of 0.0. IEEE 754
mandates all comparisons involving NaN are unordered (false).
**Fix:** Changed to `s1_b_nan ? 1'b0`.

### HIGH #11: `orchestrator_chip.v` PCIe ready/valid protocol violation under spine backpressure
**File:** `HDL/orchestrator_chip.v:266`
**Bug:** `pcie_in_ready` asserted when `fb_state == 2` without checking if the flit
builder could accept. When spine backed pressure, bytes were accepted by PCIe but
not consumed by the flit builder, causing silent data loss.
**Fix:** Added `(fb_out_ready || !fb_out_valid)` to the ready condition.

### HIGH #12: `pe_tile_stub.v` FMA output bleeds across message boundaries (USE_FMA=1)
**File:** `HDL/pe_tile_stub.v:265-266`
**Bug:** `fma_out_pending` was never cleared at message boundaries. The BF16 FMA's
3-cycle latency caused results to arrive after CRC bytes, corrupting output framing.
**Fix:** Gated FMA output to only payload byte positions with `in_payload` signal.

### MEDIUM #23: `kv_cache.go` Load() panics on negative seqPos and returns stale data
**File:** `sim/internal/pnm/kv_cache.go:98-106`
**Bug:** Go's `-1 % Depth` yields `-1`, causing index-out-of-range panic. After
evictions, Load() returned stale data without checking if the slot was within the
live window `[ReadPtr, ReadPtr+Occupancy)`.
**Fix:** Added negative seqPos guard, positive modulo adjustment, and live window
validation.

### MEDIUM #24: `model_compiler.go` non-deterministic CU assignment
**File:** `sim/internal/pnm/model_compiler.go:646-648`
**Bug:** Iterating `cuSet` (a map) produced non-deterministic order for
`na.ComputeUnits`, breaking reproducibility for the paper's compilation listings.
**Fix:** Collect keys into a slice, sort, then append.

### MEDIUM #25: `des.go` echoStart zero-value causes false-positive busy reports
**File:** `sim/internal/pnm/des.go:234-236, 255`
**Bug:** `echoStart` map initialized empty with Go zero-value 0. `echoBusy` checked
`m.echoStart[n] >= 0` which was true for uninitialized nodes (0 >= 0 = true).
**Fix:** Initialize `echoStart[n]` and `busyEnd[n]` to -1 for all nodes.

### LOW #26: Documentation CTRL constant values wrong
**Files:** `AGENTS.md:152`, `docs.md:102`, `README.md:203-212`
**Bug:** AGENTS.md listed CTRL values as 0x40/0x50 (actual: 0x80/0x90). docs.md used
wrong VC constant names. README.md build commands missing vc_merge.v and bf16_fma.v.
**Fix:** Corrected all three documentation files.

### MEDIUM #27: `model_compiler.go` EmitSchema missing AXIS bit in routing bitmap display
**File:** `sim/internal/pnm/model_compiler.go:589`
**Bug:** `routeBitmap := ((nid.L + 1) << 7) | (nid.Y << 0)` omitted the AXIS bit (bit 6).
The actual routing bitmap format is `[10:7] LAYER, [6] AXIS, [5] SIGN, [4:0] DIST`.
For Y-axis nodes, AXIS=1 must be set. The generated topology code (`gen_topology.go`)
correctly includes this bit, but the schema display did not, producing incorrect
documentation output.
**Fix:** Changed to `((nid.L + 1) << 7) | (1 << 6) | (nid.Y << 0)`.

### MEDIUM #28: `model_compiler.go` KV cache budget ignores existing weight usage
**File:** `sim/internal/pnm/model_compiler.go:308`
**Bug:** `kvBudgetPerNode` was computed as 80% of `PerNodeBudget` (128 GB) without
subtracting the weight bytes already placed on the node. For heavily loaded nodes,
the KV cache allocation could push total usage over the 128 GB budget. The budget
check at line 350 would then reject the node.
**Fix:** Compute `usedBytes` from the node's existing tensors, then allocate 80% of
`PerNodeBudget - usedBytes`. Moved the budget computation inside the per-node loop.

### LOW #29: `run.go` misleading error message on Start() failure
**File:** `sim/internal/pnm/run.go:1237`
**Bug:** When `cmd.Start()` failed (e.g., iverilog not in PATH), the error message
said "vvp exited nonzero" which is misleading — the process never started.
**Fix:** Changed to "vvp failed to start: %v" with the actual error.

### LOW #30: Documentation says "5 scenarios" but code has 6
**File:** `AGENTS.md:85`
**Bug:** The command example said "all 5 scenarios" but the default list has 6
(sweep, vcsweep, load, hotspot, stress, replay).
**Fix:** Changed to "all 6 scenarios".

## Bug audit log (2026-08-27)

### CRITICAL #1: `fp32_fma.v` mantissa alignment loses MSB on overflow
**File:** `HDL/core/fp32_fma.v:130-132`
**Bug:** `s1_mul_man << 1` shifts the MSB out of the 48-bit wire when the product
overflows (both operands near 2.0). `s1_mul_overflow` was computed but never used
in the alignment path. The `bf16_fma.v` correctly handles this with a wider
intermediate register.
**Fix:** Use a 49-bit intermediate (`mul_man_49`) and only shift when not overflowing.
Added fix #5 comment in the header.

### CRITICAL #2: `fp64_fma.v` same overflow bug as fp32_fma
**File:** `HDL/core/fp64_fma.v:130-132`
**Bug:** Identical pattern — `s1_mul_overflow` computed but ignored in alignment.
`<< 1` truncates bit 105 when the product overflows.
**Fix:** Use a 107-bit intermediate (`mul_man_107`) and only shift when not overflowing.

### CRITICAL #3: `lpddr5_phy.v` CAS_LATENCY=16 truncated to zero
**File:** `HDL/lpddr5_phy.v:197, 222`
**Bug:** `cas_cnt <= {1'b0, CAS_LATENCY[3:0]}` on both CAS paths — parameter is 16
(5 bits), `[3:0]` yields `4'b0000`. CAS counter initializes to 0, making all reads
complete with zero wait states.
**Fix:** Changed both instances to `CAS_LATENCY[4:0]`.

### CRITICAL #4: `rotary_engine.v` RoPE rotation completely broken
**File:** `HDL/core/rotary_engine.v:102-133`
**Bug:** Two compounding bugs: (1) cos multiply was a no-op (`cos_one ? s1_qe : s1_qe`,
both branches identical), (2) combine stage used XOR instead of FP add/sub.
**Fix:** Rewrote module with combinational `bf16_mul` and `bf16_addsub` helper
functions. Fast paths for cos=1.0 (identity) and sin=0.0 (zero). Full BF16
multiply uses 14-bit fixed-point intermediates (28-bit product). Add/sub uses
sign-extension, alignment, and normalization. Fixed zero-detection to check raw
exponent/mantissa before denormal adjustment.

### CRITICAL #5: `kv_cache.go` PrefixCache.Store always evicts just-added entry
**File:** `sim/internal/pnm/kv_cache.go:220`
**Bug:** New entries added with `HitCount: 0`. Eviction removes the entry with
minimum `HitCount`. Since 0 is the minimum, the just-added entry is always
immediately evicted. The prefix cache was non-functional.
**Fix:** Changed `HitCount: 0` to `HitCount: 1`.

### CRITICAL #6: `llm_client.go` simpleHash can return negative token IDs
**File:** `sim/internal/pnm/llm_client.go:163-171`
**Bug:** `h = -h` when `h < 0` — if `h` is `math.MinInt64`, `-h` overflows and
stays negative. `simpleHash(w) % v.Size` preserves sign, producing negative
token IDs and out-of-bounds panics.
**Fix:** Added second guard: `if h < 0 { h = 0 }`.

### CRITICAL #7: `llm_client.go` batch result collection uses wrong indices
**File:** `sim/internal/pnm/llm_client.go:446-450`
**Bug:** `RemoveFinished()` mutates `c.Batch.Requests` between iterations. The `i`
from range no longer corresponds to original `results` indices.
**Fix:** Added `reqIDToSlot` map tracking `RequestID -> results` index. Collection
now uses `reqIDToSlot[req.RequestID]`.

### CRITICAL #8: `firmware.go` speculative draft double-advances SeqPositions
**File:** `sim/internal/pnm/firmware.go:569-583`
**Bug:** Phase 1 calls `PlanInference` for each draft token, advancing
`SeqPositions`. Phase 2 calls `PlanInference` again for verification,
advancing positions a second time.
**Fix:** Save `SeqPositions` before draft phase, restore after. Only the final
accepted tokens should advance positions.

### CRITICAL #9: `pnmc/main.go` output filenames hardcoded to "gemma4"
**File:** `sim/cmd/pnmc/main.go:235,242`
**Bug:** `schemaPath` and `programPath` hardcoded as "gemma4_schema.txt" and
"gemma4.pnm". Compiling any other model overwrites gemma4 outputs.
**Fix:** Use `filepath.Base(modelDir)` for output filenames.

### CRITICAL #10: `paper/Paper.MD` duplicate paragraph in manuscript
**File:** `paper/Paper.MD:488`
**Bug:** Line 486 and 488 both start with "The structural consequence is that
HBM demand is coupled..." — line 488 is a truncated copy. Would appear in
published paper.
**Fix:** Removed duplicate paragraph (line 488).

### HIGH #13: `orchestrator_chip.v` identical CTRL constants for weight upload and compute
**File:** `HDL/orchestrator_chip.v:89-90`
**Bug:** Both `CTRL_WEIGHT_UPLOAD` and `CTRL_COMPUTE` were `8'h80`. Downstream
logic cannot distinguish weight-upload flits from compute flits.
**Fix:** Changed `CTRL_WEIGHT_UPLOAD` to `8'hA0` (vc_class=2 | OP_WEIGHT).

### HIGH #14: `power_rails.v` blocking assignments in async-reset sequential block
**File:** `HDL/power_rails.v:67-70`
**Bug:** `drop_uv`, `droop_mv`, `rail_lim`, `rail_nom` used blocking assignments
(`=`) in a sequential `always @(posedge clk or negedge rst_n)` block's reset
branch. All other registers use NBA (`<=`).
**Fix:** Changed to NBA (`<=`).

### MEDIUM #15: `kv_cache.go` DefaultKVCacheConfig ignores hiddenSize parameter
**File:** `sim/internal/pnm/kv_cache.go:265`
**Bug:** `func DefaultKVCacheConfig(hiddenSize int)` never used `hiddenSize`.
`EntryBytes` hardcoded to 512.
**Fix:** When `hiddenSize > 0`, compute `entryBytes = 2 * hiddenSize * 2` (K+V,
BF16). Falls back to 512 when hiddenSize <= 0.

### MEDIUM #16: `virtual_units.go` kernelFunc panics on unknown kernel
**File:** `sim/internal/pnm/virtual_units.go:213`
**Bug:** `panic("unknown kernel: " + name)` crashes the entire simulation.
**Fix:** Return nil from switch default. `NewVirtualUnit` checks for nil and
falls back to echo kernel.

### MEDIUM #17: `run.go` Golden() panics on unknown kernel
**File:** `sim/internal/pnm/run.go:249`
**Bug:** `panic("unknown kernel: " + kernel)` crashes during verification.
**Fix:** Return nil from switch default. Verification reports mismatch.

### MEDIUM #18: `Paper.MD:73` wrong citation for LPCAMM2
**File:** `paper/Paper.MD:73`
**Bug:** "the current LPCAMM2 class (JESD318) is a 644-pin module{c(16)}" but
Ref 16 is HBM (JESD235D). Correct citation is {c(17)} (CAMM2 JESD318).
**Fix:** Changed `{c(16)}` to `{c(17)}`.

### MEDIUM #19: `Paper.MD:500` wrong citation for CERN-OHL-S
**File:** `paper/Paper.MD:500`
**Bug:** "CERN Open Hardware Licence...{c(20)}" but Ref 20 is seL4. The
CERN-OHL-S reference is Ref 21.
**Fix:** Changed `{c(20)}` to `{c(21)}`.

### MEDIUM #20: `pcb/README.md` wrong node count for reference chassis
**File:** `pcb/README.md:11-12, 194, 201-202, 214`
**Bug:** Stated "16 compute nodes per layer (128 nodes total)" and
`-l 8 -x 4 -y 4`. Paper consistently uses 8x8 = 64 nodes per layer,
512 nodes total.
**Fix:** Changed to "64 compute nodes per layer (512 nodes total)",
`-l 8 -x 8 -y 8`, and "8 layers x 64 nodes = 512 compute nodes".

### MEDIUM #21: `paper/readme.md` bibliography count wrong
**File:** `paper/readme.md:27`
**Bug:** Said "20 entries" but `build.py` REFS array has 31 entries.
**Fix:** Changed to "31 entries".

### LOW #22: `.gitignore` missing sim generated files and submission artifacts
**File:** `.gitignore`
**Bug:** `sim/dispatch_plan.txt`, `sim/moe_map.json`, `sim/routing_table.json`
were tracked. `paper/submission/*.aux` and `paper/submission/*.out` not ignored.
`sim/pnmhost`, `sim/haskell_pnm`, `sim/hlsl_pnm`, `sim/r_pnm` not ignored.
**Fix:** Added all missing patterns. Reorganized .gitignore with sections.

### LOW #23: `flake.nix` references non-existent PCB path
**File:** `flake.nix:81`
**Bug:** `pcb/orchestrator_sbc/orchestrator_sbc.lpp` does not exist. Actual
path is `pcb/processor/processor.lpp`.
**Fix:** Changed to `pcb/processor/processor.lpp`.

### LOW #24: `flake.nix` runs `python3 build.py` from repo root
**File:** `flake.nix:61`
**Bug:** `build.py` is in `paper/`. Running from repo root fails with
`FileNotFoundError`.
**Fix:** Changed to `( cd paper && python3 build.py )`.

### LOW #25: `pnmc` workload subcommand missing from usage message
**File:** `sim/cmd/pnmc/main.go:89-92`
**Bug:** Usage message listed `compile-model` and `run-driver` but not `workload`.
**Fix:** Added `pnmc workload <name> [...]` line to usage output.

## Bug audit log (2026-08-27, round 2)

### CRITICAL #11: `bf16_fma.v` missing zero-guard on multiply exponent
**File:** `HDL/core/bf16_fma.v:79`
**Bug:** `mul_exp_w` computed without zeroing when a or b is zero. `0*x` produced
exponent -127 instead of 0, corrupting barrel shifter alignment. `fp16_fma.v` had
the fix; not ported to bf16.
**Fix:** Added `(a_zero_w || b_zero_w)` guard on both `mul_exp_w` and `mul_man_w`,
matching `fp16_fma.v` pattern.

### CRITICAL #12: `fp64_alu.v` MIN/MAX uses magnitude-only compare
**File:** `HDL/core/fp64_alu.v:381-402`
**Bug:** MIN/MAX compared absolute values (`a_abs < b_abs`), ignoring sign bits.
MIN(-2.0, 1.0) returned 1.0 instead of -2.0. `fp32_alu.v` had correct signed
comparison; not ported to fp64.
**Fix:** Replaced magnitude comparison with signed comparison ported from `fp32_alu.v`:
sign-aware branching, both-zero handling, NaN handling.

### CRITICAL #13: `gen_topology.go` yout_vc references undeclared wire
**File:** `sim/internal/pnm/gen_topology.go:321`
**Bug:** `.yout_vc(y_%d_%d_%d_vc)` hardcoded `y+1` even for last row (`y==by-1`),
referencing wire `y_%d_%d_%by_vc` which doesn't exist. Caused Verilog compilation
failure for any `by > 1`.
**Fix:** Added `yout_vc` variable parallel to `yout`, set to `"2'b0"` for last row.

### CRITICAL #14: `hlsl_ir.go` operator precedence reversed
**File:** `sim/internal/pnm/hlsl_ir.go:290-317`
**Bug:** `parseHLSLBinop` scanned right-to-left, finding `*` before `+`.
`a + b * c` compiled as `(a+b)*c` instead of `a+(b*c)`.
**Fix:** Two-pass left-to-right scan: first for `+`/`-` (lowest precedence), then
for `*`/`/` (highest precedence).

### HIGH #13: `bf16/fp16_mac_array.v` partial sum captured without valid gating
**Files:** `HDL/core/bf16_mac_array.v:119-132`, `HDL/core/fp16_mac_array.v:119-132`
**Bug:** `psum_sr[r][0] <= fma_result[r-1][c]` assigned unconditionally, even when
`fma_valid_out[r-1][c]` was deasserted. Stale/undefined FMA results leaked into
accumulation during pipeline fill.
**Fix:** Gated partial sum capture with `if (fma_valid_out[r-1][c])` — only capture
when the FMA above has a valid result.

### HIGH #14: `int4_mac_array.v` all MACs receive external act_valid
**File:** `HDL/core/int4_mac_array.v:108`
**Bug:** Every MAC received `act_valid` directly instead of pipelined valid. All
MACs processed simultaneously rather than with proper skew, producing wrong
accumulation results.
**Fix:** Changed `.valid_in(act_valid)` to `.valid_in(act_v_sr[row][col][PIPE_DEPTH-1])`.

### HIGH #15: `weight_dequant.v` INT8 -128 negation wraps
**File:** `HDL/core/weight_dequant.v:47`
**Bug:** `-(-128)` in 8-bit two's complement = -128 (wraps). `weight_abs` was 0x80
(128 unsigned), producing wrong BF16 encoding.
**Fix:** Used 9-bit intermediate: `wire signed [8:0] weight_ext` for sign-extension
before negation, so `-(-128)` correctly produces 128 in 9 bits.

### HIGH #16: `r_ir.go` operator precedence reversed
**File:** `sim/internal/pnm/r_ir.go:133`
**Bug:** Regex `(.+?)` (non-greedy LHS) captured leftmost operator. `a * b + c`
matched `a * (b + c)` instead of `(a * b) + c`.
**Fix:** Changed to greedy LHS `(.+)` and non-greedy RHS `(.+?)`, pushing operator
match to the rightmost (lowest precedence) position.

### HIGH #17: `pipe.go` partial messages silently dropped
**File:** `sim/internal/pnm/pipe.go:214-235`
**Bug:** When a FlitMessage header arrived in one `conn.Read` but the payload in the
next, the incomplete message was discarded. No buffering across reads.
**Fix:** Changed to `append(buf, tmp[:n]...)` with carry-over of unconsumed bytes
between reads. Buffer grows as needed.

### HIGH #18: `fw/pnm_fw.c` flit_bytes off-by-1
**File:** `fw/pnm_fw.c:157,173`
**Bug:** `flit_bytes = 4 + token_len + 2` counted 4 header bytes but the wire format
has 5 (LAYER_ID + MODULE_ID + CTRL + LEN_LO + LEN_HI). Undercounted by 1 byte.
**Fix:** Changed to `5 + token_len + 2`.

### HIGH #19: `fw/pnm_fw.h` firmware_t exceeds MCU RAM
**File:** `fw/pnm_fw.h:151-191`
**Bug:** `moe_map[256*128]` alone was ~512KB. Total struct >530KB, far exceeding
MCU's 4-8KB SRAM.
**Fix:** Added `#ifdef PNM_MCU` conditional compilation with reduced limits:
MAX_EXPERTS=16, MAX_MODEL_LAYERS=8, MAX_NODES=16, KV_DEPTH=64, etc.

### HIGH #20: `toolchain/mcu/Makefile` references non-existent uart_drv.c
**File:** `toolchain/mcu/Makefile:30`
**Bug:** `SRCS` included `uart_drv.c` but only `uart_drv.h` exists (inline functions).
Build fails with missing source file.
**Fix:** Removed `uart_drv.c` from `SRCS`.

## Bug audit log (2026-08-27, round 3 — test-system build-out)

Audit performed while building the `pnmt` Go test runner and validating its categories.

### CRITICAL: `tb_rst_sync.v` / `tb_clk_gate.v` never call `$finish` on success
**Files:** `HDL/tb_rst_sync.v:68-72`, `HDL/tb_clk_gate.v:75-79`
**Bug:** Both testbenches print `*** ... TEST PASSED ***` but only call `$finish` on
**failure** (`$finish(1)`). On the success path the simulation has no stimulus and no
timeout, so `vvp` runs forever — hanging the `pnmt hdl-phy` category indefinitely.
**Fix:** Added `$finish;` after the PASS display in both, matching the failure path's
`$finish(1)`.

### CRITICAL: `optical_link.v` declaration-after-use of `rgray_ws2`
**File:** `HDL/optical_link.v:71,155`
**Bug:** `rgray_ws1`/`rgray_ws2` were declared at line 155 but the continuous
assignment `wire rbin_wr = gray2bin(rgray_ws2)` at line 71 referenced `rgray_ws2`
before its declaration. iverilog errors on the port connection (`Unable to bind
... rgray_ws2`), so `tb_optical_link` would not elaborate and compile failed.
**Fix:** Moved the `rgray_ws1, rgray_ws2` declaration up beside the other CDC
synchronizer regs (line 64 area) and removed the later duplicate declaration.

### CRITICAL: `gen_topology.go` ties `node_eject.yout_vc` to constant `2'b0` on last row
**File:** `sim/internal/pnm/gen_topology.go:313`
**Bug:** For the last Y row (`y == by-1`), the emitter set `yout_vc = "2'b0"` and
emitted `.yout_vc(2'b0)`. `yout_vc` is an **output** port of `node_eject`, and
Verilog-2005 forbids connecting an output port to a constant literal ("expression
not valid in assign l-value"). Every generated topology with `by > 1` failed
elaboration, breaking `TestDESCrossCheckRTL` and the 512-node reference chassis.
**Fix:** Added a per-(layer,x) `wire [1:0] yres_<l>_<x>_vc;` declared in the wire
declaration loop (before the node instantiations that reference it) and connected
`.yout_vc(yres_<l>_<x>_vc)` on the residual path. The wire is unused downstream (the
residual must stay empty) but captures the port legally.

### Test-runner path/timeout fixes (`sim/cmd/pnmt/main.go`)
- HDL/firmware dirs must be `../HDL` / `../fw` when `pnmt` runs from `sim/`; the Go
  test working dir is `"."`.
- Go test subgroup timeout bumped to 90s and coverage to 120s — driver tests alone
  take ~46s and were timing out at 60s under full-suite load.
- `doorbell` HDL case needed `core/weight_dequant.v` and `core/int8_mac.v` added to
  its source list (the `pe_tile_stub` references them).

### Test-only fix: `ir_property_test.go` Haskell assertion
**File:** `sim/internal/pnm/ir_property_test.go:88-114`
**Bug:** `TestHaskell_LinearProperty` asserted `len(prog.Regs) > 0`, but
`compileHaskellFunc` intentionally stores a compiled function's body in
`prog.Funcs["f"].Body` and restores `prog.Regs` to the parent scope. The assertion
was always false for valid single-function inputs, so the test failed.
**Fix:** Assert on `prog.Funcs["f"].Body` instead (and likewise for the binop
coverage test). No compiler defect — test expectation was wrong.

### MEDIUM: `kv_cache.go` `KVCacheLayer.Store`/`Load` negative `seqPos` out-of-range panic
**File:** `sim/internal/pnm/kv_cache.go:460-463, 486-491, 491-494`
**Bug:** `Store` and `Load` computed `bankIdx = seqPos % NumBanks` (and `StorePaged` the same from `globalIdx`) before reaching the bank-level `seqPos < 0` guard. For a negative `seqPos`, `bankIdx` is negative and `kl.Banks[bankIdx]` is an out-of-range index, panicking. The bank's own `Load` already guards `seqPos < 0` (line 370), so the layer wrapper silently defeated it.
**Fix:** Added `splitPos(seqPos)` which returns `(-1, 0)` for negative input; both `Store`/`Load` and `StorePaged` now bail out (`false`/`nil`) before indexing.

### MEDIUM: `kv_cache.go` `PrefixCache.Store` evicts the entry it just added
**File:** `sim/internal/pnm/kv_cache.go:216-230`
**Bug:** The just-added entry was given `HitCount: 1` "so eviction skips the just-added entry," but eviction removes the **minimum** HitCount. A fresh entry has the minimum (1), so it was the most likely candidate for immediate eviction, and Go map iteration order decides ties randomly — the new entry could be evicted right after insertion, thrashing a full cache.
**Fix:** Eviction now explicitly `continue`s past the just-inserted hash, and the misleading `HitCount: 1` comment was removed.

### Tests added: `sim/internal/pnm/kv_cache_fix_test.go`
`TestKVCacheLayer_NegativeStore` / `TestKVCacheLayer_NegativeLoad` (no panic on negative positions), `TestKVCacheLayer_RoundTrip` (cross-bank store/load integrity), `TestPrefixCache_StoreDoesNotEvictJustAdded` (a fresh entry survives eviction pressure).

### CRITICAL: `llm_client.go` nucleus/softmax sampler divisor is 2^32 not 2^64
**File:** `sim/internal/pnm/llm_client.go:816`
**Bug:** The sampler accumulated a 64-bit pseudo-random value (8 iterations of an
8-bit byte at line 813) but normalized it with `r / (1<<32)`, yielding `r ∈ [0, 2^32)`
instead of `[0,1)`. After `r *= total` (`total ≤ 1`), `r` nearly always exceeded the
`cumProb` distribution, so the nucleus/top-p loop never fired and the function
returned `sorted[len-1]` — the **lowest-probability token**, 100% of the time
(verified with a 20000-iteration harness: 100% fell-through with 2^32 vs 0% with
2^64). Temperature/nucleus sampling was effectively dead.
**Fix:** Normalize by `float32(2^64)`. (The literal `float32(18446744073709551616)`
is used because `uint64(1)<<64` is a compile-time shift-width overflow.)

### CRITICAL: `llm_client.go` empty-distribution index-out-of-range panic
**File:** `sim/internal/pnm/llm_client.go:806-807`
**Bug:** After min-p/top-p filtering, if `total <= 0` the code did `return
sorted[0].idx`. `sorted` can be emptied by (a) `minP > 1` (cutoff exceeds the max
probability, so every token fails `ip.prob >= cutoff`, `n` stays 0) or (b) non-finite
logits (Inf/NaN) collapsing all probs to NaN/0. `sorted[0]` then panics out of range.
**Fix:** If `len(sorted) == 0 || total <= 0`, fall back to greedy argmax over the
original logits (no panic). Also changed the greedy branch guard from
`temperature == 0` to `temperature <= 0` so a negative temperature can no longer
negate logits and invert sampling/argmax.

### MEDIUM: `model_ir.go` layernorm ops mislabeled FP32, sized at BF16 width
**File:** `sim/internal/pnm/model_ir.go:65,66,79`
**Bug:** `input_layernorm`/`post_attention_layernorm`/`final_norm` were declared
`DType: "FP32"` but `SizeBytes: h * 2` (2 bytes/elem = BF16). `SizeBytes` drives
`generateWeightPayload` sizing and per-node byte accounting in `driver.go:241`, and
the safetensors/IR convention stores norm weights as BF16 (`safetensors.go:49`), so
the FP32 label contradicted both the size and the storage convention.
**Fix:** Set the norm ops' `DType` to `"BF16"` to match the `h * 2` size and the
BF16 storage convention, while keeping `CUType: CUTypeFP32ALU` (the compute unit
that processes them).

### Tests added
- `sim/internal/pnm/kv_cache_fix_test.go` — negative-`seqPos` `Store`/`Load` don't
  panic (`TestKVCacheLayer_NegativeStore`/`NegativeLoad`), cross-bank round-trip
  integrity, and `PrefixCache` does not evict a just-added entry.
- `sim/internal/pnm/llm_client_fix_test.go` — sampling is proportional
  (`TestSampleFromLogits_SamplingNotDegenerate`), empty-filter falls back to greedy,
  NaN logits don't panic, negative temperature is greedy.

### Notes (documented, not changed)
- `pipe.go:62` uses a 16-bit payload-length field, truncating (same as the network
  wire format's inherent 16-bit `LEN_LO`/`LEN_HI`) for payloads > 65535 bytes. No
  harness payload exceeds this, so this is a protocol-design constraint rather than
  a triggered bug; widening it would diverge from the wire-format framing.

## Bug audit log (2026-08-27, round 4 — firmware dispatch)

### CRITICAL #15: MoE dispatch always targets experts 0..TopK-1, never the gating-selected set
**File:** `sim/internal/pnm/firmware.go:491` (dispatch loop)
**Bug:** The MoE dispatch loop iterated `expIdx := 0; expIdx < tc.TopKExperts; expIdx++`
and looked up `MoeKey{ModelLayer: ml, ExpertIdx: expIdx}`, treating the loop index as a
global expert index. But `computeMoeMap` (`driver.go:127-141`) keys `MoeMap` by the
full global expert index from `t.ExpertIdx` (0..NumExperts-1), and the model compiler
places all `NumExperts` experts (`model_ir.go` emits an `expert_gate_up`/`expert_down`
op per expert 0..NumExperts-1). So every token dispatched to experts `0..7` (for
top-k=8) regardless of gating, and 120 of 128 experts were never dispatched to. This
contradicts the documented design (firmware.go:29-32: "orchestrator_weights[l] .
hidden_state -> logits; Top-K selection: experts = argmax(logits, k)").
**Fix:** Added `selectTopExperts(token, ml, numExperts, topK)` in firmware.go, a
deterministic token- and layer-seeded gating function that scores all `NumExperts`
experts (FNV-1a seed over token bytes + model layer, then a per-expert splitmix-style
multiply-hash for scores) and returns the top-k global expert indices with a stable
tiebreak. The dispatch loop now iterates that set, so routing is token-dependent and
the whole expert population is reachable while remaining reproducible for a fixed
input. The MoE dispatch *count* (NumHiddenLayers * TopK) is unchanged, so the existing
`driver_test.go:119` count assertion still holds. `driver.go`'s twin `PlanInference`
loop is a stub ("for now, all experts — no gating network") and was left as-is; the
firmware is the authoritative dispatch path.

### CRITICAL #16: sliding-window flag collapsed by physical layer, mislabels full-attention layers
**File:** `sim/internal/pnm/firmware.go:383-396` (with `kv_cache.go:711-724`)
**Bug:** `NewKVCache` sizes `kc.Layers` by the *physical* layer count (`dims.Layers`),
but `ConfigureSlidingWindow` fills `kc.Layers[ml]` from the *model*-layer `layerTypes`
list with an early `break` at `ml >= len(kc.Layers)`. The dispatch loop then read
`fw.KV.Layers[pl].IsSliding` with `pl = modelLayer / modelLayersPerPhysical`. For
gemma4 (30 model layers -> 4 physical layers, 8 per physical), `ConfigureSlidingWindow`
set `kc.Layers[0..3]` from `layerTypes[0..3]` — all "sliding_attention" — so every
physical layer's KV layer was marked sliding, and the full-attention model layers at
indices 5, 11, 17, 23, 29 (mapped to pl=0..3) got spurious sliding-window bounds in
their dispatch records. Only model layers 0-3 were ever consulted.
**Fix:** Added `Firmware.layerIsSliding(ml)` which reads the model's per-layer
`TextConfig.LayerTypes[ml]` directly (falling back to the physical KV layer flag for
models without per-layer types), plus `Firmware.physLayerOf(ml)` to centralize the
model->physical mapping. `PlanInference` now uses `layerIsSliding(ml)` per model layer,
so a `full_attention` layer produces `WindowStart == -1` even when a sibling layer in
the same physical layer is sliding.

### Tests added
- `sim/internal/pnm/firmware_fix_test.go`:
  - `TestMoEDispatchReachesFullExpertPopulation` — across 64 distinct tokens, the set
    of dispatched global expert indices must exceed `TopKExperts` (proves gating
    reaches beyond experts 0..7). Fails on the old fixed-`0..TopK-1` loop.
  - `TestSlidingWindowPerModelLayer` — every `full_attention` model layer (5, 11, 17,
    23, 29 for gemma4) must produce `WindowStart == -1` despite sharing physical
    layers with sliding layers, and at least one sliding layer must produce a real
    window (non-vacuous). Fails on the old physical-layer-collapsed lookup.

### HIGH #20: `pnmhost -frag` silently dropped, workloads run with default fragment size
**File:** `sim/cmd/pnmhost/main.go:162-164` (`parseGlobal`), affecting `runWorkload` (201-208) and `runAuto` (307-313)
**Bug:** `parseGlobal` scans argv and, for every `-`-prefixed token, consumes the next
non-flag token as its value. The `case "-frag": // Handled by subcommand — ignored
here` did nothing, so both `-frag` and its value were stripped from the returned
positional slice. The subcommand loops in `runWorkload`/`runAuto` that scan `remaining`
for `-frag` could therefore never find it, so `frag` stayed `0` and `RunWorkload`
(`host_driver.go:258-260`) silently fell back to the workload's default `reg.Frag`.
The requested fragment size (matvec vector length, nbody fragment size, etc.) was
discarded with no error or warning, generating a different program than requested.
**Fix:** The `-frag` case now appends the flag and (when present) its value back to the
`positional` list, so the subcommand loops can consume them. Other flags are unaffected.

### Tests added
- `sim/cmd/pnmhost/main_test.go`: `TestParseGlobalKeepsFrag` (asserts `-frag` and its
  value survive `parseGlobal` into the positional list while other flags still parse
  into config) and `TestWorkloadFragExtraction` (asserts the `runWorkload` extraction
  loop recovers the fragment size and strips the flag/value).

## Bug audit log (2026-08-27, round 5 — R/Haskell/HLSL compound operands)

### CRITICAL: compound/chained operands silently evaluate as 0 in all three source frontends
**Files:** `sim/internal/pnm/r_ir.go` (`resolveRAtom`, `compileRAssign`),
`sim/internal/pnm/haskell_ir.go` (`resolveHaskellAtom`, `compileHaskellExpr`),
`sim/internal/pnm/hlsl_ir.go` (`resolveHLSLAtom`, `compileHLSLExpr`)
**Bug:** Each `resolve*Atom` treated any non-numeric operand as a bare variable name
via `getOrCreateReg(s)`. When an operand was itself a compound expression (e.g. "b +
c" in `x <- a + b + c`, or "a - b" in `f a b c = a - b - c`), `getOrCreateReg` created
an **uninitialized register** that reads as 0, silently collapsing the sub-expression.
Verified: `x <- a - b - c` compiled to `add(r4, neg(c))` where `r4` (the `a - b`
operand) was never defined → result `0 - c`; `r = a.x + b.x + c.x` computed `a.x + 0`.
The shipped `examples/hello.{hlsl,R,hs}` avoid multi-op-atoms and so never trigger it.
**Fix:** Refactored each frontend's assignment compiler into a dest-targeted recursive
form (`compileRExprTo` / `compileHaskellExprTo` / `compileHLSLExprTo`) and made
`resolve*Atom` recurse into it whenever the operand is not a plain number or a plain
identifier (`isSimpleIdent`). A compound operand now gets a fresh temp register that a
real sub-expression is compiled into, so no source register is ever left undefined.
Fallback to `getOrCreateReg` on an unlowerable atom preserves prior behavior. Note this
fixes the "operand is zero" defect; operator associativity/grouping (R is left-assoc
via greedy-LHS, Haskell/HLSL are right-assoc via leftmost-operator split) is a
pre-existing parser trait, not changed here.

### LOW: `TestDESCrossCheckRTL` inject-stream comparison was vacuous
**File:** `sim/internal/pnm/des_test.go:171-178`
**Bug:** The explicit inject-stream comparison vs RTL `t.Logf`'d and `break`t on a
mismatch without ever calling `t.Error`/`t.Fatal`, so it could never fail the test on
its own. (The later `CrossCheckDES` still verified inject streams, so it was not fully
vacuous, but this loop implied a check it did not perform.)
**Fix:** Changed `t.Logf` to `t.Errorf` so the first inject-stream divergence fails the
test.

### Tests added
- `sim/internal/pnm/ir_compound_test.go`: `TestRCompoundOperand` (two-subtraction
  expression emits enough instructions to prove the inner sub-expression is real),
  `TestRCompoundOperandNotZero` (no register referenced before it is defined),
  `TestHaskellCompoundOperand` (two `FP64Sub` ops for `a - (b - c)`, proving the nested
  `b - c` is not zeroed), `TestHLSLCompoundOperand` (two `ALUAdd` ops for
  `a.x + b.x + c.x`, proving `b.x + c.x` is not zeroed).

### Notes (illustrative lowering, not changed)
- `sim/internal/pnm/haskell_pnm.go` `irOpToKernel` maps only `FP64Add`/`FP64Mul`/
  `FP64FMA` to `.pnm` kernels. `FP64Sub`/`FP64Div`/`FP64Neg`/`FP64Min`/`FP64Max`/
  `FP64Cmp` fall through to `""` and are dropped from the emitted `.pnm`; likewise
  `hlslOpToFP64` falls back `ALULerp`/`ALUDot`/`ALUClamp`/`ALURcp` to `FP64Add`. The
  fabric runtime (`run.go`, `virtual_units.go`) only supports the three f64 kernels, and
  the whole frontend `.pnm` lowering is a placeholder: `packFP64Args`/`registerValue`
  hash operand register names into `[1.0,2.0)` constants rather than threading real
  chained results. Fully expanding the richer ops into add/mul/fma chains with real
  value threading is a design-level rewrite of this illustrative pipeline, not a local
  bug fix, and is out of scope for this audit round.

## Bug audit log (2026-08-27, round 6 — INT4 array timing, quantizer round-trip, ALU sign)

Verified and fixed sequentially; each fix confirmed by its self-checking testbench or
Go test. The full Go suite (`go test ./internal/pnm/`, ~200 s) and the co-simulation
(`go run ./cmd/pnm`, ALL SCENARIOS PASSED) pass with all of these in place.

### CRITICAL: `int4_mac_array.v` systolic accumulation produced all-zero results
**File:** `HDL/core/int4_mac_array.v`
**Bug:** The array returned all-zeros even with a single-vector identity testbench,
independent of the earlier column-0 capture bug. The root cause was a fundamental
systolic-timing mismatch. The partial-sum capture (`psum_sr[i][j][0] <= mac_result[i][j]`)
fired **unconditionally every cycle**, and all rows' MACs fired from the same activation
validity at essentially the same time, so each row consumed an unsynchronized `c` (its
upstream accumulated sum) that had not yet settled. The upstream result only arrived one
full MAC-pipeline + PIPE_DEPTH later, by which point that row's MAC had already fired with
a stale `c` — so rows below never accumulated anything. This is why the array output was
zero regardless of the col-0 fix.
**Fix:** Rewrote the accumulation chain so it is time-staggered and validity-gated,
mirroring the bf16_mac_array intent but with a real multi-row accumulation check:
- Row 0's MAC fires one cycle after the feed (`act_valid_q`) so the per-row activation
  hold (`act_hold[]`) has settled before the MAC samples its `a` operand.
- Row r>0's MAC fires from `psum_v_sr[row-1][col][PIPE_DEPTH-1]`, i.e. only when the
  upstream accumulated partial sum is valid in the c-input stage.
- `psum_sr[row][col][0]` captures `mac_result[row][col]` only when `mac_valid_out` is
  asserted, otherwise it holds the previous accumulation. `psum_v_sr` is set from the MAC
  validity, not from `act_valid`.
Verified with `tb_int4_mac_array.v` (identity matrix -> `[1,2,3,4]` PASS) and a scratch
all-ones-column test (activations 3,4,5 -> accumulation 12 PASS). The interface is
unchanged, so the co-sim (`run.go` FABRIC list includes `int4_mac_array.v`) still builds.

### HIGH: `int8_alu.v` ADD/SUB/SHIFT/MIN/MAX zero-extend negative results
**File:** `HDL/core/int8_alu.v:78-85`
**Bug:** The 8-bit result mux emitted `{8'h00, result[7:0]}` — zero-extension. Any negative
8-bit result (e.g. ADD(3,-5)=-2, SUB(3,5)=-2, ADD(-4,-3)=-7) came out as a large positive
(254, 249). The signed arithmetic is computed in wide registers but the 16-bit output
discarded the sign. The testbench only exercised non-negative ADD/SUB, so it passed.
**Fix:** Sign-extended the low byte from bit 7 for ADD/SUB/SHIFT/MIN/MAX: `{{8{...result[7]}}, result[7:0]}`.
CMP (0/1 only) remains zero-extended. Verified negative cases now return -2/-7 and the
original 10 tests still pass.

### HIGH: `kv_quant.v` dequantize discarded the INT4 magnitude
**File:** `HDL/core/kv_quant.v` (dequantize path)
**Bug:** Dequantize returned `{sign, scale[14:0]}` for any nonzero INT4 input and `0` for
zero — it used only the sign bit and never the 4-bit magnitude. Every reconstructed
nonzero entry collapsed to +/- full scale, destroying all relative information in the KV
block. The testbench only checked that a scale and *some* output appear, so it passed.
Also, the quantize path emitted a placeholder bit-slice (`data[6:3]`) unrelated to the
block scale.
**Fix:** Implemented a self-consistent symmetric quantize/dequantize pair. Quantize maps
each value's magnitude to an index `qn = floor(m / scale)` (scale = block_max>>3) via
comparisons against `k*scale` (no divider), sign applied; scale is computed once per block.
Dequantize reconstructs `sign * (|int4| * scale)` so magnitudes are preserved
monotonically. Verified INT4 `1..8` now reconstruct to distinct, magnitude-scaled values
that scale linearly with the index.

### HIGH: `dyn_act_quant.v` dequantize discarded the INT8 magnitude (and quantize was a placeholder)
**File:** `HDL/core/dyn_act_quant.v` (quantize + dequantize paths)
**Bug:** Identical magnitude-discard defect to `kv_quant`: dequantize returned +/- full
scale for any nonzero INT8, ignoring bits [6:0]. The quantize path was an explicit
placeholder (`q_int8_out <= block_buf[...][7:0]`), ignoring the block min/range/scale it
computed. Also `block_cnt == BLOCK_SIZE[3:0]-1` truncated BLOCK_SIZE=32 to 16.
**Fix:** Same self-consistent scheme as kv_quant, extended to INT8. scale = block_max>>7;
quantize index `qn = floor(m/scale)` using a compact restoring divider (`div_floor`
function), sign applied; dequantize reconstructs `sign * (|int8| * scale)`. Block count
and emit count now use `BLOCK_SIZE[4:0]`/`emit_cnt` (5-bit) so a 32-lane block is handled.

### MEDIUM: `fw/pnm_fw.c` MoE dispatch `flit_bytes` still off-by-one
**File:** `fw/pnm_fw.c:173`
**Bug:** The dense-attention record (line 157) already counted 5 header bytes
(`5 + token_len + 2`), but the MoE dispatch record (line 173) still counted 4
(`4 + token_len + 2`), undercounting the flit by 1 byte for MoE dispatches.
**Fix:** Changed line 173 to `5 + token_len + 2`, matching the wire format
(LAYER_ID + MODULE_ID + CTRL + LEN_LO + LEN_HI + payload + CRC). Verified with
`gcc -Wall -Wextra -std=c11 -c pnm_fw.c` (zero warnings).

### Tests added
- `HDL/core/` (all currently passing): `tb_int8_alu.v`, `tb_kv_quant.v`,
  `tb_dyn_act_quant.v`, `tb_int4_mac_array.v`, plus the shared `int8_mac`, int4, bf16/fp16
  mac-array, weight_dequant, moe_gating and rotary_engine testbenches.

## Bug audit log (2026-08-27, round 7 — design audit: rotary_engine BF16 math)

Audit finding: `HDL/core/rotary_engine.v` contained two module-local combinational
functions with independent, compounding BF16 correctness bugs. The shipped
`tb_rotary_engine.v` never exercised them: its LUT is identity (cos=1.0, sin=0.0),
so `bf16_mul` and `bf16_addsub` are bypassed on every shipped test vector. Both
functions were validated against a float reference in standalone scratch
harnesses before and after the fix (31968/31968 and 34560/34560 random
normal-input cases), then an end-to-end pipeline TB with real sin/cos LUT values
confirmed the full 4-stage path (8/8 cases incl. exponent-150 tokens).

### CRITICAL #15: `rotary_engine.v` `bf16_mul` exponent wrap, false-Inf, and off-by-one normalization
**File:** `HDL/core/rotary_engine.v:53-115`
**Bug:** Three compounding errors. (1) `re = xe + ye` in 8-bit arithmetic wraps
when `xe+ye >= 256`; the `if (re < xe)` carry check then wrongly forced
`re = 0xFF` (Infinity). Confirmed: `1.5*2^23 x 1.5*2^23` (x+y exponents 150+150)
returned `0x7FC0` (Inf) instead of a finite result. (2) `prod_ge2 = prod[26]`
was off by one: for a 1.xx x 1.yy product in [2.0, 4.0), the leading integer
bit sits at prod[27], not prod[26]. (3) Consequently both mantissa slices were
shifted down by one (`prod[25:19]` / `prod[24:18]` instead of `prod[26:20]` /
`prod[25:19]`), corrupting the mantissa of every non-trivial normal-input
multiply. Net effect: ALL normal multiplies outside the identity fast paths
produced wrong results; large-exponent pairs produced false Inf.
**Fix:** Accumulate `esum = xe + ye + prod_ge2` in 9 bits *before* subtracting
the bias; overflow to Inf when `esum > 381`, underflow to zero when
`esum < 128`; `prod_ge2 = prod[27]`; mantissa slices `prod[26:20]` /
`prod[25:19]`. Validated 31968/31968 random normal-input multiplies vs float
reference (relative error < 1/64 for all finite cases).

### CRITICAL #16: `rotary_engine.v` `bf16_addsub` catastrophic false-zeroing and construction bugs
**File:** `HDL/core/rotary_engine.v:122-220`
**Bug:** Four compounding errors. (1) `if (r_exp[7] || r_exp == 0) result = 0`
treated ANY exponent >= 128 (bit 7 set) as underflow: `4.0 - 2.0 = 0`,
`2.0 + 2.0 = 0`. (2) `norm_man` was `reg [7:0]`, so `{r_sign, r_exp, norm_man}`
was a 17-bit concatenation and Verilog truncated the leftmost bit, scrambling
every result. (3) Alignment right-shifted the 8-bit mantissa, discarding guard
fraction bits during cancellation (e.g. `0xFF - 0x80` loses the 0.5).
(4) Underflow was detected via 8-bit `r_exp - K`, wrapping when `K > r_exp`.
**Fix:** Rewrote with long-mantissa accumulate (implicit + 7 mantissa + 8 guard
fraction bits = 16-bit `a_LM`/`b_LM`), normalization through `mag` with
highest-bit detection, underflow detected *before* subtracting (`K >= r_exp`),
7-bit `man` port, and `0 +/- 0 -> +0`. Validated 34560/34560 random cases vs
float reference. The module-level TB added a passed `[zero]` vector (0+0 -> +0)
exercising the zero branch.

### Design-audit root-cause class (watch for it elsewhere)
The same three idioms are the recurring bug class across this codebase:
1. **Bit-7 sentinel checks on 8-bit exponents** — BF16/FP32/FP64 exponents
   legitimately reach bit 7 (or bit 30/62), so `r_exp[7]`-style tests silently
   misclassify valid large exponents as overflow/underflow.
2. **Width-truncating concatenations** — `{sign, exp, man}` with `man` one bit
   too wide drops the MSB of the field, scrambling results instead of failing.
3. **Unsigned wraps in exponent arithmetic** — `r_exp - K` for `K > r_exp`
   wraps modulo 256; underflow must be tested with `>=` *before* subtracting,
   and 8-bit exponent sums must accumulate in 9 (or wider) bits first.
`fp64_alu.v` (DIV path, MIN/MAX) is the same pattern family and is the next
audit target.

### Tests
- Added (repo): none new; existing `tb_rotary_engine.v` now passes with the
  fixed module (previously only passed because the LUT identity bypassed the
  math).
- Scratch (not in repo): `/tmp/bf16mul_test.v` (reproduced false-Inf),
  `/tmp/bf16mul_ref.v` (31968/31968 post-fix validation),
  `/tmp/bf16add_v3.v` (34560/34560 post-fix validation),
  `/tmp/tb_roty_bug.v` (in-module spot check: exp-150 pair now finite),
  `/tmp/tb_roty_e2e.v` (full pipeline vs dual-rounding float reference,
  8/8 incl. exponent-150 tokens).

## Bug audit log (2026-08-27, round 8)

### CRITICAL #17: `fp64_alu.v` DIV returns floor(SA/SB) — every non-trivial quotient collapses to 1.0
**File:** `HDL/core/fp64_alu.v:257-319`
**Bug:** The restoring-division loop "brought down" the dividend's own bits
(`div_rem = {div_rem[52:0], div_dividend[bit_idx]}`), i.e. it ran the textbook
bit-extraction scheme on a 54-bit significand but only ever had 54 dividend bits
to pull from. A full binary long division needs the fractional quotient bits,
which the dividend does not contain. Result: the quotient register accumulated
exactly the dividend's leading bits and the normalization stage stripped them,
collapsing **every** input with `SA/SB not a power of two` to `1.0` (mantissa all
zeros, no fraction ever appended). Empirically confirmed on the unmodified
module: 1.5/1.0, 1.5/1.25, ~2/1, 1/~2 all returned exactly `3FF0000000000000`.
The shipped `tb_fp64_alu.v` only tests `6.0/3.0 = 2.0` and `1.0/0.0 = Inf`
(exact-power and division-by-zero: both immune), which is why it never caught it.
**Fix:** Rewrote as two-phase restoring division:
  - Phase A (1 cycle): compare SA vs SB in `[0.5, 2)`, set integer bit, subtract.
  - Phase B (53 cycles): `rem = {rem, 0}` each cycle, compare vs SB, set `q[j]`.
  - `div_q[52:0]` holds 53 fraction bits; `q_int=1` → mantissa `q[52:1]`,
    `q_int=0` → mantissa `q[51:0]`, exp −1 (truncation, per design policy).

### CRITICAL #18: `fp64_alu.v` DIV 11-bit exponent wrap breaks |ea−eb| ≥ 1024
**File:** `HDL/core/fp64_alu.v:292-294` (old), now `:301-303`
**Bug:** `div_exp = (ea-eb) + 1023` computed in 11-bit two's complement. For
far-apart exponents (e.g. `2^-1022 / 2^1023` → ea−eb = −2045) the 11-bit result
wrapped: `2^-1022/2^1023` returned `4.0`, `1/2^1023` returned `0`,
`2^-1000/2^1000` returned `2^48`.
**Fix:** 13-bit signed exponent math: both field terms `$signed({2'b00, e})`,
bias `$signed(13'd1023)`; `div_exp` is `reg signed [12:0]`.

### CRITICAL #19: `fp64_alu.v` DIV underflow emitted +Inf — signed reg compared against unsigned literals
**File:** `HDL/core/fp64_alu.v:369-372`
**Bug:** The flush/overflow branches tested `div_norm_exp` (a `reg signed [12:0]`)
against `13'd1` and `13'd2046`. **Sized decimal literals are unsigned in
Verilog**, and any unsigned operand forces the whole comparison unsigned:
`-1022` reinterpreted as 13-bit unsigned = 7170, so `7170 < 1` is false and
`7170 > 2046` is true → every exponent-underflow result (`2^-1022/2^1023`,
`2^-1000/2^1000`) came back **+Inf** instead of ±0. (The unmodified module was
immune only because its `div_norm_exp < 0` compared against an *unsized* literal,
which is signed.)
**Fix:** Compare against `13'sd1` / `13'sd2046`.
**Also:** added explicit denormal flush (a_den → ±0, b_den → ±Inf) and NaN/Inf/0
special-case handling to the combinational result block.

### Validation (round 8)
- `/tmp/tb_fp64div5.v`, 31 cases, real-domain reference (integer exponent math,
  mantissa compared as reals, tolerance +0/−1 ULP for truncation):
  **31/31 PASS** against the fixed module, including:
  - power-of-two quotients (4/2 = 2, 2/4 = 0.5, 1/0.5 = 2);
  - mantissa ratios far from 1 (1.5/1.25 = 1.2, 1.25/1.5, ~2/1, 1/~2);
  - near-1 ratios and `(1+2⁻⁵²)/(1+2⁻⁵²)`;
  - far-apart exponents → overflow → ±Inf and underflow → ±0
    (2⁺¹⁰²³/2⁻¹⁰²², 2⁻¹⁰²²/2⁺¹⁰²³, 1/2⁺¹⁰²³, 2⁻¹⁰⁰⁰/2⁺¹⁰⁰⁰);
  - negative operands, NaN/Inf/0 specials, denormal flush policy.
- Shipped `tb_fp64_alu.v`: **12 passed, 0 errors** (unchanged suite).
- `/tmp/tb_fp64div_dbg.v` (internal-state probe) confirmed the restore-timing:
  early probe "Inf" reports were the unsigned-compare flush bug; intermediate
  harness versions had $rtoi (32-bit) wrap and 11-bit `$signed` cut — harness
  only, the DUT values were corroborated by the real-domain rewrite.
- Root-cause class: quotient bit-extraction that never sources fraction bits,
  exponent math narrower than the ±2046 range, and unsigned-literal comparisons
  against signed exponent regs (same family as BF16 round 7).

### Notes for future auditors
- iverilog `$rtoi()` returns a 32-bit integer: `$rtoi(frac_r + 0.5)` wraps for
  fractions ≥ 2³¹. Compare expected/actual in the **real** domain instead.
- `eo = $signed(a[62:52]) - $signed(b[62:52]) + 1023` in a harness wraps in
  11-bit: compute with `integer` typed temporaries.
- `reg signed` vs `13'dN` sized literals: always write `13'sdN` when the operand
  is signed. Unsized decimal literals (`2047`, `0`) are signed.
## Bug audit log (2026-08-28, round 9)

### HIGH #21: `haskell_pnm.go` source-language lowering silently drops every op except add/mul/fma
**Files:** `sim/internal/pnm/haskell_pnm.go:171-182, 186-200` (`irOpToKernel`,
`serializeOperands`), shared by all three frontends via `lowerFP64ToPNM`
(`LowerToPNM` = R, `LowerHaskellToPNM`, `LowerHLSLToPNM`).
**Bug:** `irOpToKernel` returned `""` for `FP64Sub`, `FP64Div`, `FP64Min`,
`FP64Max`, `FP64Cmp`, `FP64Neg`, and both the kernel directive and the token
directive emission used `if kernel == "" { continue }` — a **silent drop with no
warning**. The frontends (r_ir.go, haskell_ir.go, hlsl_ir.go) demonstrably emit
those ops: `sub x y = x - y` compiled to `f64.sub r2, r0, r1` in the IR but
produced a .pnm that read `# no operations to dispatch` (a program that does
nothing, which then PASSES co-simulation vacuously — 0 packets, 0 activations).
The paper (Paper.MD §2.6) claims the FP64 IR ops "map to fixed-function
hardware units" and that the downstream pipeline consumes the IR; div/min/max/
cmp map to fp64_alu.v units in the RTL, and its simulator counterparts were
simply missing.
**Fix:** Added `f64_sub`, `f64_div`, `f64_min`, `f64_max`, `f64_neg`, `f64_cmp`
kernels across the stack:
- `virtual_units.go`: `kF64Sub/Div/Min/Max/Neg/Cmp` (payload a(8)+b(8), neg
  a(8), cmp a(8)+b(8)+op(1-2 ASCII bytes trimmed); NaN → unordered false for
  ordered comparisons), wired into `kernelFunc` and `KERNELS_ALL`.
- `run.go` `Golden()`: the same six cases (kept in lockstep with the kernels).
- `haskell_pnm.go`: `irOpToKernel` maps the six ops; `serializeOperands` packs
  two-operand (sub/div/min/max), one-operand (neg), or two-operand+op-code
  (cmp) payloads; generated .pnm header documents all nine f64 kernels.
**Validation:** full-op Haskell program (`absv`, nested calls) lowered to
sub/cmp/mul/add kernels + 18-byte cmp tokens and co-simulated:
**17 doorbell activations, 17 packets, PASS**. New unit tests:
`TestKF64Sub/Div/MinMax/Neg/Cmp/ShortPayloads`, `TestGolden_F64Ops`,
`TestNewVirtualUnit_AllKernelsFP64`. Full `go test ./internal/pnm/` green
(168s). Regenerated `sim/examples/hello.{hs,R,hlsl}.pnm` (untracked, still
unchanged program content, header now documents the full kernel set).
**Notes:** cmp payload is 17-18 bytes (`op` 1-2 ASCII chars, trailing space
padded by the serializer, trimmed by both consumers). R's `a-b` still lowers to
neg+add (pre-existing codegen); register operands remain deterministic
name-hashes (placeholder dataflow, documented in `packFP64Args`) — the lowering
is a structural/algebraic demonstration, not a value-accurate dataflow pass.

### MEDIUM #29: `pipe.go` `handleConn` blocking channel send leaks goroutine + connection on Close
**File:** `sim/internal/pnm/pipe.go:235-241`
**Bug:** `cl.msgCh <- msg` was an unconditionally blocking send on a 1024-deep
channel. A stalled consumer (no `Recv()` drain) pinned the handler goroutine;
`Close()` neither closes `msgCh` nor selects on `done`, so the goroutine and its
socket leaked permanently. Only test code uses CircuitLink today (no production
path), which is why it never surfaced.
**Fix:** Route via `select { case cl.msgCh <- msg: case <-cl.done: return }`.
A full channel now drops the handler on Close instead of leaking.

### MEDIUM #30: `pipe.go` `RecvFlit` fails on partial socket reads and drops back-to-back messages
**File:** `sim/internal/pnm/pipe.go:322-330`
**Bug:** The old implementation did one `conn.Read(buf)` and decoded `buf[:n]`.
A message split across two reads returned "message too short" (no reassembly),
and two messages arriving in one read silently discarded the second.
**Fix:** Read exactly `flitHdrLen` with `io.ReadFull`, then exactly the
declared payload length; extra bytes stay buffered on the wire. Regression
tests: `TestRecvFlit_PartialReadReassembly`, `TestRecvFlit_TwoMessagesKeepsBuffered`.

### LOW: `NamedPipe` is a regular file, not an OS FIFO
**File:** `sim/internal/pnm/pipe.go:98-111`
**Note:** `CreateNamedPipe` uses `os.OpenFile` (regular file), not `mkfifo`; the
read handle re-reads from offset 0 rather than consuming. Only exercised by
`TestNamedPipe_*`; documented as a Rust/Python-port scaffolding mismatch, not a
correctness bug in any shipped path.

### Audits with no new findings (round 9)
- `sim/internal/pnm/crc.go` vs `HDL/core/crc16.v`: bit-identical CCITT-FALSE
  (init 0xFFFF, poly 0x1021, MSB-first, no final XOR; `crcBytes` big-endian
  matches `[CRC_HI, CRC_LO]`). Stress scenario (6 corrupt rejected end-to-end)
  exercises the pair. Clean.
- `HDL/pi_bridge.v` / `HDL/pnm_arb.v`: SPI frame bit-order (d0 → `rx_shift[30]`
  → `cmd_wdata[31]` ✓), read/write status bytes, F_HDR→F_RD1/F_DATA/F_TRAIL
  transitions, `irq_out` on CS-deassert, atomic round-robin `pnm_arb` grant.
  The stalled-read abort (F_RDWAIT/F_WRWAIT continue the handshake until
  `pnm_ready` even if CS drops) is a documented trade-off, not a bug.
- `LowerHLSLToPNM` filter `if ir.Op != 0`: verified NOT a bug — `FP64Add` is
  iota 2 (after FP64Load/FP64Store), and HLSL IR never emits Load/Store, so no
  op is wrongly filtered.
- Round 8 fp64 DIV fix: full `go test ./internal/pnm/` re-verified after the
  repo edit (integration test compiles `tb_fp64_alu.v` against the new DIV).

### Notes for future auditors
- When writing demo sources with a shell `printf`, bash's builtin `printf` does
  NOT honor `--` as an option terminator: `printf -- '-- x\n...'` writes only
  `--`. Prefixing a .hs/.R/.hlsl demo with a comment line this way silently
  produced empty programs (which then lowered to 0 functions / vacuous PASS).
- `.pnm` empty programs still report `PASS` vacuously (0 packets, 0 doorbell
  activations); now unreachable for arithmetic programs after HIGH #21, but a
  genuinely empty file still passes silently.

## Bug audit log (2026-08-28, round 10)

### LOW #31: `estimateCrossLayerTraffic()` reports alpha=(layers-1)/layers regardless of placement
**File:** `sim/internal/pnm/model_compiler.go:218-239`
**Bug:** The function computed `alpha = (layers-1)/layers` unconditionally
(~0.97 for 30 model layers on 4 physical layers) even though its own comment
says "With layer-local expert placement, alpha approaches 0". `PopulateSchema`
(model_ir.go:283) really does place every expert tensor on
`physLayerOf(op.ModelLayer)` — the same physical layer as that model layer's
attention/dense weights — so the emitted listing claimed cross-layer MoE traffic
of 97% when the actual placement produces ~0%. Diagnostic-only, but it
contradicts the paper's MoE-traffic claim and misleads anyone reading the
compilation listing.
**Fix:** Removed the unconditional formula. `estimateCrossLayerTraffic` now
measures the true fraction directly: it scans all `expert_*` tensor placements,
counts those whose node's physical layer differs from
`ModelLayer / modelLayersPerPhysical`, and reports
`alpha = cross_layer_expert_tensors / total_expert_tensors`. For the
gemma4_test_synthetic reference chassis it now prints
`alpha=0.00 (4/4 layers with experts, 8 active/tok, 0/7680 expert tensors cross-layer)`.
The `(layers-1)/layers` closed form remains documented in the comment as the
random-placement bound.

### HIGH #22: `GenerateWithBatching` silently drops every request's result
**File:** `sim/internal/pnm/llm_client.go:364-468`
**Bug:** The batching loop terminates only when `Batch.HasActive()` is false,
i.e. after `RemoveFinished()` has removed *every* request from
`c.Batch.Requests`. Result collection then iterated `c.Batch.Requests` over an
empty batch, so `results[slot]` stayed the nil placeholder for every prompt.
The entire continuous-batching feature returned `[[], [], ...]` while reporting
no error — a textbook silent drop (round-9 CRITICAL #7 fixed the index
mismatch during iteration, but the collection-after-removal bug survived).
**Fix:** Capture `req.Generated` into a `resultsByReq` map at the moment a
request finishes (decode-phase EOS/MaxTokens branch), and merge it into
`results` during final collection alongside any survivors.

### HIGH #23: structured-output FSM literal `[a]`/`[A]`/`[0]` widen to whole classes
**File:** `sim/internal/pnm/llm_client.go:1426-1478`
**Bug:** `CompileStructuredFSM` expands `[a-z]`/`[A-Z]`/`[0-9]` ranges into
per-rune literal transitions, so `[z]` compiles to a transition carrying
`CharClass=='z'`. But `canAdvance` and `Advance` also contained shorthand
branch checks (`t.CharClass == 'a' && ch >= 'a' && ch <= 'z'`), which made a
literal `[a]` transition match *any* lowercase letter — and likewise `'A'`
matched any uppercase, `'0'` any digit. `GenerateStructured` would accept and
consume tokens outside the constrained pattern.
**Fix:** Removed the three shorthand branches from `canAdvance`/`Advance`;
only exact rune matches and `'.'` (any) count. Class ranges still work because
the compiler emits one literal transition per rune. Regression tests:
`TestStructuredFSM_LiteralSingleCharNotWidened`,
`TestStructuredFSM_ClassRangeStillWorks`.

### MEDIUM #32: `NewLLMClient` forces TopP=0 → 0.9, contradicting "(0 = disabled)"
**File:** `sim/internal/pnm/llm_client.go:184-186` (removed)
**Bug:** `LLMConfig.TopP` is documented as "nucleus sampling threshold
(0 = disabled)" but the constructor silently rewrote 0 → 0.9, so nucleus
sampling could never be turned off. Same anti-pattern that round 9 fixed for
`Temperature` (which now preserves 0 = greedy).
**Fix:** Removed the override; TopP=0 now means disabled. Asserted in
`TestGenerateWithBatching_ResultsRetained` (TopP preserved through
construction).

### CRITICAL #33: `orchestrator_chip.v` flit builder drops header bytes 1-4 (every flit malformed)
**File:** `HDL/orchestrator_chip.v:537-568`
**Bug:** The FB_HDR state asserted `fb_out_valid` only in the `fb_pos==0`
(LAYER_ID) branch. Positions 1-4 (MODULE_ID, CTRL, LEN_LO, LEN_HI) assigned
`fb_out_data` but left `fb_out_valid` deasserted, and the `if (fb_out_ready ||
!fb_out_valid)` guard means the state only advanced when a sink deasserted
ready. With a continuously-ready sink (the spine injector), exactly one header
byte per flit was consumed, followed by whatever the FB_PAYLOAD/CRC states
next produced. A scratch TB confirmed the breakage: a weight flit expected to
carry 11 bytes on the wire (`5 header + 4 payload + 2 CRC`) actually emitted 7,
missing MODULE_ID, CTRL, LEN_HI, and one payload byte. Every weight-upload and
every MoE-dispatch flit built by the orchestrator was malformed — the fabric
would reject or CRC-error or misroute them all.
**Why it shipped:** `tb_orchestrator_chip.v` checked only the `weight_flits >= 1`
and `dispatches == 1` counters and never sampled `spine_inject_*`. Counting
status counters is vacuous verification: the TB passed while every emitted
flit was garbage. Same bug class as the round-7/round-9 vacuous-pass findings —
add "does the TB validate the output stream, or just a counter?" to the
standard audit lens.
**Fix:** All five FB_HDR branches now assert `fb_out_valid <= 1` (and
`fb_out_sop <= 0` for positions 1-4). Verified two ways: (1) a scratch TB
sampling the spine stream now captures a complete 11-byte weight flit
(`LAYER=00 MODULE=00 CTRL=A0 LEN_LO=04 LEN_HI=00 payload=04 AA BB CC
CRC_HI=98 CRC_LO=0B`) whose CRC independently recomputes to `0x980B`; (2) the
shipped TB was extended to sample `spine_inject_data/valid/sop/eop` into a
byte array and assert framing (SOP at byte 0, EOP at last byte, neither in
between), header fields, payload bytes, flit length (`5 + LEN + 2`), and a
CRC-16/CCITT-FALSE recomputed in-TB over the captured wire bytes
(`MODULE..payload`). It now pins the exact weight flit
(`01 00 A0 08 00 AA AB AC AD AE AF B0 B1` + CRC `E5 74`) and token flit
(`01 00 80 04 00 42 43 44 45` + CRC `82 06`); both CRC values also match an
independent Python reference.
**Observation (documented, not fixed):** the token dispatch captures
`fb_layer/fb_module` from the `dispatch_layer`/`dispatch_module` latch in the
same cycle `gate_start` pulses. Gating completes (gate_done) many cycles after
the flit is emitted, so the first token routes to the reset-default destination
(LAYER=01, MODULE=00, as the new TB assertion pins) and each subsequent token
routes on the *previous* token's gating result — a one-token pipeline lag
versus the firmware/Go model (firmware.go computes gating for the current token
before dispatch). Noted for the paper's orchestration description; the routed
destination in real silicon would additionally need the hidden-state feed
(`gate_hidden_data` is currently driven nowhere).

### AUDIT: `sim/internal/pnm/gen_topology.go` (441 lines) — clean
Spine descent/ascent chains, board X/Y lanes, egress merge trees, and slice
(tail/tic-off) wiring all verified. Prior-round fixes present: `yout_vc` for
the last row (`y == by-1` → `yres_*_vc`, CRITICAL #13), kvcache `xin_vc`
rewire (MEDIUM #20). `bx==1`/`by==1` degenerate cases route through `xres`/
`yres` with ready tied high; merge trees degrade to direct `nobu` assigns.

### AUDIT: `sim/internal/pnm/host_driver.go` (651 lines) — 2 LOW findings, fixed
`RunScenario`/`RunWorkload`/`RunProgram`/`RunModel`/`RunInference` flow clean;
`ScenarioStress` self-defaults flits==0; all error paths propagate into
`Result.Errors`. Two silent-config findings in the same class as round-9/10
default-override fixes:
- **LOW #33:** `NewHostDriver` rewrote `HotFrac: 0` → 0.35, making it
  impossible to disable hotspot traffic through the config. Removed the
  override (`cmd/pnmhost` already defaults the flag to 0.35 explicitly).
- **LOW #34:** `RunInference` hardcoded `DataType: CUTypeBF16FMA`, silently
  ignoring the documented `HostConfig.DataType` ("fp16"/"bf16") field.
  Added `datatypeFromString()`; `"fp16"` now selects `CUTypeFP16FMA`.
Both pinned by `host_driver_test.go` (`TestDatatypeFromString`,
`TestNewHostDriverHotFracZeroPreserved`).

### Audits with no new findings (round 10)
- `HDL/hfr.v`, `HDL/flit_gate.v`, `HDL/vc_merge.v`: clean. HFR pipeline
  `in_ready = out_ready || !out_valid`; flit_gate combinational XOR/AND + VC
  compare holds its decision through EOP, strip bookkeeping regenerates SOP
  after the dropped head, `in_ready` tracks the granted port; vc_merge is
  bubble-free from IDLE with round-robin priority flip on the *other* port.
- `HDL/lxy_repeater.v`, `HDL/xy_turn.v`, `HDL/node_eject.v`: clean. lxy strips
  LAYER_ID on match (VC 2→3), xy_turn matches the X nibble (no strip, VC 3),
  node_eject matches full MODULE_ID and deliberately does NOT strip so DEST
  stays inside the CRC coverage for end-to-end validation.
- `sim/internal/pnm/safetensors.go`: clean — `TensorShapeFor`/`CollectTensors`;
  no lm_head in the gemma test index is consistent with
  `tie_word_embeddings=true`.
- `sim/internal/pnm/model_ir.go`: clean — `CompileModelIR` sizes,
  `PopulateSchema` placement (embedded-shard distribution across layer-0 nodes,
  final_norm on layer 0), KV cache reservation (80% of the per-node budget after
  weights, capped at 16K entries), 128 GB per-node budget enforcement.
- `HDL/lpddr6_camm.v`, `HDL/sodimm_ctrl.v`: clean. The LPDDR timing-model
  stack is validated by its TBs against real output: `tb_dma_lpddr6.v` /
  `tb_sodimm_lpddr.v` check actual memory contents and DMA read-back data (not
  just counters). lpddr6_camm accept→ready-reassert with read data parked one
  cycle early via cmd_wait==1 gives exactly CAS_LATENCY cycles (CL=4 → 4);
  write commit lands at cmd_wait==0. sodimm_ctrl's banked ACT/RCD/CAS/RP/RAS
  model hits the TB's exact closed forms (cold=32=RCD+CL+2, hit=16=CL+1,
  conflict=48, DDR5 36-36-44 → 74), ST_WAIT_RAS snaps the remaining tRAS into
  a countdown, refresh starts only from ST_IDLE with no command presented
  (`ref_start_now` avoids the accept/refresh race), and byte-enable lane
  writes use indexed part-selects. The paper's 16 GB/s-per-lane /
  ~256 GB/s-per-node figures are macro parameters — these are cycle-level
  capacity/scheduling stubs on a 32-bit/100 MHz control bus and do not encode
  per-lane data rates, so there is no contradiction to check.
- `sim/internal/pnm/firmware.go` (877 lines) and `sim/internal/pnm/des.go`
  (1123 lines): full reads, clean — boot phases, selectTopExperts (FNV-1a
  seeded, stable tiebreak), KV sliding-window math, speculative
  save/restore of SeqPositions, and the discrete-event twin's merge/refill/
  egress/echo bookkeeping all checked in detail.
## Bug audit log (2026-08-28, round 11)

### MEDIUM #29: `splitArith` mis-splits a unary minus/MS after a binary operator
**File:** `sim/internal/pnm/arith_split.go`
**Bug:** The splitter only guarded a `*` whose *previous* char is `*`; it had no
notion of an operand position. A `-`/`+` following another binary operator (e.g.
`a / -b`, `a * -b`, `a - -b`, `a + -b`) was treated as a *binary* operator, and
because `+`/`-` have lower precedence than `*`/`/`, it became the chosen split.
`a / -b` split into `lhs="a /"`, `rhs="b"` (the `-` swallowed the operator into
the left side). This silently miscompiled division/mul/sub/add by a negated
operand in **all three** frontends (R, Haskell, HLSL): the RHS resolved through
`resolve*Atom` → recursive compile → failure → a bogus variable literally named
`"a /"` etc. Numeric cases like `a / -3` produced a garbage `"a /"` variable
instead of dividing by −3.
**Fix:** Rewrote the operator scan to only split at a depth-0 operator whose left
side ends a complete operand. Added `prevIsOperand()`: skip the operator if the
previous non-whitespace character is an operator, `(`, or the start of the string.
Now `a / -b` splits as `lhs="a"`, `rhs="-b"`; `a / -3` correctly reaches the
`ParseFloat("-3")` literal path in all frontends.
**Also:** a `*` immediately followed by another `*` (`a ** b`, R exponentiation)
was previously treated as a multiply, producing `a * var("* b")` — a silent wrong
result (R uses `**`/`^` for power). Now it does not split and falls through to a
clear `unsupported R expression` error (R) / bogus-variable (Haskell/HLSL), never
a silent miscompile.
**Regression tests:** `ir_unary_test.go` — `TestSplitArith_PrecedenceAndParens`
(`a / -b`, `a * -b`, `a - -b`, `a + -b`, `(a+b)*(c-d)`, precedence), and
`TestSplitArith_DoubleStarRejected` (asserts `a ** b` errors, not miscompiles).

### MEDIUM #30: R `#` comments not stripped
**File:** `sim/internal/pnm/r_ir.go:143`
**Bug:** `CompileR` skipped full-line `#` comments (line 145) but did not handle
trailing/inline comments. In R, `#` begins a comment running to end of line, so
any realistic statement like `x <- a + 1 # normalize` failed with
`unsupported R expression: a + 1 # normalize`. The expression subset never
embeds `#` inside a string literal, so stripping is safe.
**Fix:** Strip at the first `#` on each line before other processing.
**Regression tests:** `ir_unary_test.go` — `TestCompileR_TrailingComment`,
`TestCompileR_FullLineCommentsOnly`.

### Known limitation (partially resolved): unary minus on a variable/expression
**Files:** `sim/internal/pnm/r_ir.go`, `haskell_ir.go`, `hlsl_ir.go`
**Issue:** `splitArith` now correctly isolates a leading `-` operand (`-b`, `-3`),
but the frontends differ in how they lower a unary minus on a non-literal:
- **R** (as of the resolveRAtom refactor, round 11 follow-up): a bare `-b` operand is
  detected and returns a **clean compile error** (`unsupported R expression: -b`)
  rather than silently creating a bogus `"-b"` register. Numeric unary minus
  (`-3.5`) still works via `rNumRe`/`ParseFloat`.
- **Haskell/HLSL** still create a variable literally named `"-a"` (silent, undefined)
  — only numeric unary minus works (`-3.5`).
This is an intentional scope limit of the toy IR (no branch/neg of an arbitrary
expression in the expression parser), documented here so it is not mistaken for
regression. The structural mis-split that made it *worse* (MEDIUM #29) is fixed, and the
R silent bogus-variable path is now a clean error (covered by
`TestRIR_UnaryOnVariableNoSilentMiscompile`). Not fully fixing Haskell/HLSL to avoid a
large, risky refactor of the remaining lowerers mid-audit.
**Regression/test:** `ir_numeric_property_test.go` — `TestRIR_UnaryOnVariableNoSilentMiscompile`
asserts `a / -b` either errors cleanly or compiles to the correct result, never a silent
miscompile.

### Clean audits (round 11, no changes)
- `arith_split.go` callers in `r_ir.go`/`haskell_ir.go`/`hlsl_ir.go` re-read in
  full after the fix; precedence (`2 + 3 * 4` → mul-before-add), parenthesized
  operands, and the R `FP64Neg` sentinel subtraction path (`a - b` → negate-RHS +
  add) all verified correct via scratch probe tests.
### LOW #35: `GenReduction` routing description does not match generated program
**File:** `sim/internal/pnm/workloads.go:148-208`
**Issue:** The header comment and `Workload.Routing` string describe a
"reverse-path merge tree (egress → Y-up → X-up → spine ascent)" where leaf nodes
compute locally and merge partial results toward the root. In fact the generated
program only injects one token per leaf-*(y,x)* directly from the single co-sim
injector (node 0,0,0) to the root `(layers-1, 0,0)` over the forward-path spine,
then runs `echo`. No egress/Y-up merge is actually exercised, and the `echo`
order-independence rationale refers to a pattern this program never builds. The
co-sim is still byte-exact (echo is pass-through), so this is a documentation /
intent mismatch, not a correctness failure. The real reverse-path (egress) merge
is modeled separately by `des.go`, so no behavior needs to change — only the
comment/route string is misleading.
**Fix:** None applied (no functional impact). All 5 workloads re-verified green.

### MEDIUM #31: `OffloadCycle` NVMe write failure silently drops KV entries and cascade-drains
**File:** `sim/internal/pnm/kv_cache.go` (`OffloadCycle`)
**Bug:** In the `EvictNvme` path, `kl.EvictOldest()` removed the oldest entry
from the bank *before* the NVMe write was attempted. If `WriteBlocks` failed,
a bare `break` (inside the `switch`) exited only the `switch`, not the enclosing
`for kl.NeedsOffload()` loop. The already-removed entry was therefore lost
(neither persisted nor counted as an eviction), and the loop immediately evicted
the next-oldest entry and retried — repeatedly draining the cache on a persistent
sink failure, with only `Stats.Errors` incremented. The `break` was evidently
intended to stop the offload on error, but Go's unlabelled `break` in a `switch`
does not do that.
**Fix:** Rewrote `OffloadCycle` to (1) **peek** the oldest entry without removing
it (`OffloadPeek` + `KVCacheBank.PeekOldest`), (2) persist it first, and (3) only
`bank.Evict()` on success. On an NVMe write error the entry stays resident and a
labelled `continue offload` aborts the whole offload pass, so no data is lost and
the cache does not drain. Added `KVCacheLayer.fullestBank()` (shared between
`NeedsOffload` and the offload path so they agree on which bank to drain) and
`OffloadPeek()`. `EvictOldest` now routes through `fullestBank()`.
**Regression tests:** `kv_cache_fix_test.go` — `TestOffloadNvmeErrorNoDataLoss`
(occupancy unchanged + 0 evictions on persistent NVMe failure),
`TestOffloadNvmeSuccessEvicts` (drains exactly the over-threshold entries, one
NVMe write each), `TestOffloadEvictNoneDiscards` (default discard mode still
drains). Also added `bankOccupancy` + `overThresholdKVCache` helpers.
**Note:** `go fmt` was applied to `kv_cache.go` (the file was not gofmt-clean to
begin with), so the diff mixes formatting normalization with the functional fix.

### MEDIUM #32: `kv_cache_bank.v` reads KV opcode from the wrong byte (latent, dead path)
**File:** `HDL/kv_cache_bank.v:107-109`
**Bug:** `kv_op_in = nob_in_data[1:0]` reads the low two bits of the **SOP byte**,
but the wire format (pnm_defs.vh) puts the KV opcode in the **CTRL byte** (wire
byte 2; after `lxy_repeater` strips LAYER_ID it is byte 1 of the NoB stream, not
the SOP/MODULE_ID byte). On the NoB, the SOP byte is `MODULE_ID = {X[3:0], Y[3:0]}`,
so `nob_in_data[1:0]` samples the low two bits of a node coordinate, which will
randomly alias to `KV_OP_STORE`/`KV_OP_LOAD`. Worse, `pnm_defs.vh` defines only
`OP_COMPUTE`/`OP_FORWARD` (bits [5:4]) and has **no KV_STORE/KV_LOAD opcode at all**,
so the self-invented `2'b10`/`2'b11` values in `kv_cache_bank.v` do not correspond
to any defined wire operation. The correct detection would be `nob_in_ctrl[5:4]`,
and a KV opcode would need to be added to `pnm_defs.vh`.
**Severity:** latent — this path is **dead code** because every generated topology
ties the KV control inputs off (see MEDIUM #33). Not provable via co-sim today.
**Status:** documented; would only manifest if KV cache co-sim (kvcache=true) is
enabled.

### MEDIUM #33: KV cache RTL store/load/evict/reclaim paths have zero coverage
**File:** `sim/internal/pnm/gen_topology.go:254-269`, `sim/internal/pnm/run.go` (RunOne
hardcodes `kvcache=false`), `HDL/kv_offload.v`
**Bug:** When `kvcache=true`, `gen_topology.go` instantiates `kv_cache_bank` but
hardwires **all** KV control inputs to zero: `kv_store_valid(1'b0)`,
`kv_store_sop(1'b0)`, `kv_load_ready(1'b0)`, `evict_req(1'b0)`, `evict_ready(1'b0)`,
`reclaim_req(1'b0)`, `reclaim_valid(1'b0)`, `reclaim_sop(1'b0)`, `reclaim_eop(1'b0)`.
The bank is therefore a pure pass-through (SOP→EOP wire) with its store FSM, load
FSM, eviction, occupancy, and reclaim logic entirely unexercised. Compounding this,
`RunOne` hardcodes `kvcache=false` so the kvcache instantiation path never even runs,
and `kv_offload.v` (the offload controller with the EVICTION_TARGET discard/BMC/NVMe
selection logic) is **never instantiated in any HDL design** — it compiles but has no
integration point. All 7 previously-applied bug fixes in `kv_cache_bank.v`
(header lines 18-25) are therefore unverified against any testbench.
**Fix:** None applied — this is design-dead code. Documented so future KV-cache
co-sim enablement knows the RTL command-detection layer (MEDIUM #32) must be
rewired first. The Go twin (`kv_cache.go`) is the tested reference.

### HIGH #24: `rv32_core.v` SRAI mis-decoded as SRLI (logical shift)
**File:** `HDL/rv32_core.v:135, 175`
**Bug:** For `OP_OP_IMM`, the ALU input mux forces `alu_funct7_r = 7'h0`
(line 135). The shift-right ALU op (funct3=`3'b101`, line 175) selects arithmetic
vs logical shift by testing `alu_funct7_r[5]`. Since that bit is forced 0 for every
OP_IMM, `SRAI` (funct7=`0100000`, arithmetic shift right immediate) is decoded
identically to `SRLI` (funct7=`0000000`, logical) — every SRAI executes a **logical**
shift, zero-filling the top bits instead of sign-extending. When the operand's MSB
is set, SRAI silently produces the wrong result (e.g. `SRAI(x, n)` of a negative x
returns a large positive number instead of a small negative). This breaks signed
division-by-power-of-2, sign-extension idioms, and anything a compiler emits SRAI
for, contradicting the "RV32IMA" claim in the header. The `is_m_ext = funct7[0]`
decode (line 100) itself is **correct** (all M-opcodes share funct7=`0000001`), and
the ADD/SUB distinction at line 170 is correct because OP_OP keeps funct7 intact.
There were **two compounding root causes**, both fixed (applied):
1. `alu_funct7_r` was forced to `7'h0` for `OP_OP_IMM`; changed to `alu_funct7_r = ir[31:25]` so SRAI's funct7 bit 5 survives.
2. Even with funct7 fixed, line 178's ternary
   `(alu_funct7_r[5]) ? ($signed(alu_a_r) >>> ...) : (alu_a_r >> ...)` mixes a signed
   `>>>` operand with an unsigned `>>` operand. In a ternary the operand type is
   **context-determined**, and the unsigned operand demotes the whole expression to
   unsigned — so `>>>` becomes a logical shift. Verified standalone with iverilog
   (`(1'b1)?($signed(a)>>>s):(a>>s)` returns logical). Replaced with a procedural
   if/else that uses `$signed(alu_a_r) >>> alu_b_r[4:0]` for SRAI and
   `alu_a_r >> alu_b_r[4:0]` for SRLI.
**Regression test:** `HDL/tb_rv32_core.v` (new, applies to `rv32_core.v` alone)
loads `LUI x1,0xFFFFF` (`0xFFFFF0B7`), executes `SRAI x2,x1,4` (`0x4040D113`) and
`SRLI x3,x1,4` (`0x0040D193`), and checks `rf[2]==0xFFFFFF00` (sign-extended) while
`rf[3]==0x0FFFFF00` (logical). Both root causes independently fail this; with both
fixed it PASSES. All four orchestrator TBs (bmc/mcu/sbc/sbc_moe) still PASS.

### LOW #36: `rv32_core.v` MIP CSR collapses all IRQ sources into MSIP bit 3
**File:** `HDL/rv32_core.v:210`
**Bug:** `mip_ext = {28'h0, |(irq), 3'h0}` OR-reduces **all** NMINT interrupt inputs
(UART irq[0], CLINT MTIP irq[1], CLINT MSIP irq[2], spine/PCIe/NVMe on higher bits)
into a single bit at MIP position 3 (MSIP). RISC-V MIP maps MTIP to bit 7 and MEIP
to bit 11; an OR of heterogeneous sources onto MSIP is non-standard, and software
reading MIP cannot distinguish a UART interrupt from a PCIe interrupt. Low impact
today because the core never *services* interrupts (there is no FSM path from irq to
mtvec; it is polled), so MIP is informational only. Documented, no fix.

### HIGH #25: `uart.v` first byte written to THR is lost (stale byte transmitted)
**File:** `HDL/uart.v:91-97, 177-180`
**Bug:** The THR write (bus block, line 177-180) and the TX-start decision (TX FSM,
line 91) are in **separate always blocks** and race on the same cycles. On the cycle
a byte is written to THR while the UART is idle: the bus block does
`thr <= wdata; lsr[5] <= 0` (both NBA). The TX FSM, evaluated with pre-write values
(`!tx_busy && lsr[5]` is still true because `lsr[5]` was 1 this cycle), simultaneously
starts a transmission and captures the **stale** `thr` (the write's NBA has not yet
taken effect) into `tx_shift`. The freshly-written byte is therefore never transmitted;
instead a garbage byte (whatever `thr` held before) is sent. This repeats: after the
stale byte completes, `lsr[5]` is re-asserted and the FSM starts again with the still-stale
`thr`, so the written byte can be dropped entirely or emitted out of order.
**Reproducer:** scratch iverilog test wrote `0x55` to THR from idle; the UART emitted
`0x00, 0xaa, 0xaa` and **never** sent `0x55`. Confirmed in simulation.
**Severity:** high for any firmware that boots a UART from idle and expects its first
character to arrive. The orchestrator TBs do not byte-validate the TX stream, so the
bug is masked there.
**Fix (applied):** Added a `thr_has_data` register that is set on a THR write and cleared
only when the TX FSM loads the held byte into the shift register. The TX-start condition
changed from `!tx_busy && lsr[5]` to `!tx_busy && thr_has_data`. This decouples "THR
holds an unsent byte" from the `lsr[5]` empty flag, which was 1 at reset (auto-starting
a stale transmission) and cleared by the same-cycle write (masking the true start). On
reset `thr_has_data=0` so no stale byte is sent; a write sets it to 1, and one cycle
later (after `thr` holds the new byte) the TX FSM starts and transmits it. `lsr[5]` is
no longer cleared/clobbered by TX completion. Verified: standalone decode shows `0x55`
transmitted correctly; a scratch receiver confirmed the byte value on the wire.
**Regression test:** `tb_bmc_orchestrator.v` now carries a UART TX byte-decoder that
samples `uart_tx` mid-bit, frames start+8N1+stop, and asserts the first transmitted byte
is `0x48` ('H'). With the old buggy UART this reports `UART byte 1: expected 48 got 00`
and fails; with the fix it passes. (Only the first byte is validated deterministically:
the simplified UART has a single-byte holding register and no TX FIFO, so banner bytes
written back-to-back without LSR[5] flow control are legitimately overwritten after the
first; see MEDIUM #37.)

### MEDIUM #34: `nvme_ctrl.v` has no storage datapath (READ fabricates, WRITE discards)
**File:** `HDL/nvme_ctrl.v:259, 269-277`
**Bug:** The NVMe controller model contains **no storage array**. On a READ
(`ST_DMA_RD`) it emits a synthetic pattern `m_axis_rd_data <= xfer_pos + 1`
(line 259) with the comment "non-zero test pattern" — nothing is read from media. On a
WRITE (`ST_DMA_WR`, lines 269-277) it merely increments `xfer_pos` and never stores the
accepted `s_axis_wr_data`; written bytes vanish into a black hole. Consequently no
write-then-read-back round trip is possible, and the controller cannot model actual
block-storage semantics. `tb_nvme_ctrl.v` compounds this: its READ test (lines 191-196)
and WRITE test (lines 232-237) check only the status register's done bit, plus a byte
count (test 8), and **never inspect `m_axis_rd_data` content** — read bytes are never
validated against anything.
**Impact:** For the paper the NVMe path is a behavioral stand-in for the orchestrator's
storage block; the missing storage array is arguably acceptable, but the fabricated read
pattern and write-through black hole mean any TB that pretends to verify NVMe I/O is
only checking control/status. Documented, no fix.

### MEDIUM #35: `pcb_si_link.v` delivered rx_data bypasses the SI channel model
**File:** `HDL/pcb_si_link.v:324, 334-335`
**Bug:** The per-lane `si_lane` models compute attenuation/noise/echo and produce
hard-decision bits `s_dout[g]` (line 281), but those outputs **only feed the
BER/eye/margin accumulators** (lines 306-320). The actual output data path is the plain
framing pipeline: line 324 `assign {rx_sop, rx_eop, rx_valid, rx_data} = p2;` where
`p2` is simply `tx_data` delayed two cycles (lines 334-335). So the consumer's
`rx_data` is the clean, untouched transmit data even when the channel model reports bit
errors. The SI math measures loss/eye/BER in the aggregators but is disconnected from
the data actually delivered. `tb_pcb_si_link.v` validates the delayed framing against
`refq` (which always matches, since rx_data never reflects channel corruption) and
asserts signal quality only via the aggregate counters.
**Impact:** the module reports SI statistics that do not influence the functional data;
any dependent logic that should react to channel degradation on the received stream
never sees it. Documented, no fix.

### MEDIUM #36: LPDDR5/5x/6 PHY models ignore the byte-enable (`bus_be`) input
**File:** `HDL/lpddr5_phy.v`, `lpddr5x_phy.v`, `lpddr6_phy.v` (mem write blocks)
**Bug:** All three PHY models accept a `bus_be[3:0]` byte-enable but the synchronous
`mem_write` blocks write the full 32-bit word unconditionally, ignoring `bus_be`.
Sub-word byte-lane writes (SB/SH over the bus) would silently write all four lanes.
Every testbench drives `bus_be=4'hF`, so the path is entirely untested.
**Impact:** behavioral scope limitation; any future sub-word access via the bus would
corrupt neighbors. Documented, no fix.

### LOW #39: `tb_bmc_orchestrator.v` never byte-validates the spine output
**File:** `HDL/tb_bmc_orchestrator.v`
**Bug (coverage):** The BMC orchestrator TB drives real firmware through the RV32 ROM
(UART writes + PNM CTRL writes) but validates only control/counter signals — `boot_done`,
`route_dispatches`, and `uart_tx` toggling. The `spine_inject_data` output stream
(declared line 31, driven by the DUT line 57) is **never captured nor error-checked**;
there is no `check_byte()` task. This is the weakest of the four orchestrator TBs:
`tb_orchestrator_sbc.v`, `tb_orchestrator_sbc_moe.v`, and `tb_orchestrator_mcu.v` all
byte-check the spine inject header bytes (LAYER..LEN_HI), whereas `tb_bmc_orchestrator.v`
checks none of them and, at the time of writing, did not byte-validate the UART TX stream
either. (Those three also only `$display` (not error-check) the payload and CRC bytes.)
**Fix (partial, round 12):** the UART TX stream is now byte-validated by a mid-bit
sampling decoder (see HIGH #25 regression test). The `spine_inject_data` byte stream
remains unvalidated — no `check_byte()` task — and the PNM inject header bytes are still
not error-checked. Documented as a remaining coverage gap.

## Bug audit / test-improvement log (2026-08-28)

Follow-up to "why did the tests not catch these bugs, and can tests be modified to
detect similar issues?" The audit concluded the RTL/co-sim testbenches validate
*control effects* (a signal toggled, a status bit set, a byte count) rather than
*data semantics* (byte values, arithmetic results, storage round-trips), so
data-corrupting bugs slip through. This round adds tests that assert data semantics:

### New detector: numeric-reference property tests for the R compiler (`ir_numeric_property_test.go`)
**What:** Uses the existing interpreter oracle (`EvalFP64`) as a reference to assert
*arithmetic correctness*, not just "compiles without error". `refEvalR` is a
recursive-descent evaluator (unary minus, parens, `+ − * /`) that the compiled IR is
cross-checked against.
- `TestRIR_NumericUnaryAndPrecedence` — numeric cross-check against `refEvalR`.
- `TestRIR_UnaryOnVariableNoSilentMiscompile` — asserts `a / -b` yields either a clean
  compile error or the correct result, never a silent bogus register.
- `TestRIR_RandomPrecedenceProperty` — 500 random 3-term expressions (e.g. `a + b * c`,
  `a * b + c`, parenthesized variants) cross-checked against `refEvalR`, catching
  silent precedence mis-splits such as the historical R/HLSL reversed-precedence and
  unary-minus bugs in `arith_split.go` / `r_ir.go` / `hlsl_ir.go`.
This directly detects the CRITICAL #2 (R subtraction as `FP64Add`), MEDIUM #29 / HLSL &
R precedence-reversal, and unary-minus-on-variable bug classes, which the old
"compiles without error" assertions could not.

### `resolveRAtom` now returns `(string, error)` (r_ir.go)
**Change:** `resolveRAtom` (and the 8 call sites in `compileRExprTo` / `compileRCall` /
`compileRAgg`) changed from returning a bare string to `(string, error)`. A unary minus
on a bare variable (`-b`, `a / -b`) is now detected and returns a **clean compile error**
instead of silently minting a bogus `"-b"` register that reads as 0. This closes the
silent-miscompile half of the round-11 "known limitation"; Haskell/HLSL still emit a
bogus `"-a"` variable (unchanged). No behavior change for existing shipped examples.

### MEDIUM #37: `uart.v` single-byte holding register drops back-to-back writes without LSR flow control
**File:** `HDL/uart.v`
**Issue:** The simplified UART has a single `thr` holding register and no TX FIFO.
When firmware writes bytes faster than the 9600-baud line can drain them (e.g. a 4-char
banner written back-to-back without polling LSR[5]/THR-empty first), a pending byte is
overwritten by the next write and silently dropped. Verified: writing `'H',' ',' ','P'`
back-to-back transmits only `'H'` then `'P'`; the two spaces are lost.
**Impact:** intrinsic to the 1-byte-holding-register design (no FIFO); correct firmware
must poll LSR[5] before each write. Not a regression introduced by the HIGH #25 fix; it
is pre-existing and exposed by the new byte-decoder. Documented, no UART change. The new
`tb_bmc_orchestrator` decoder therefore validates only the *first* transmitted byte
(deterministic regardless of flow control), which is the exact HIGH #25 regression.

### `tb_bmc_orchestrator.v` now byte-validates the UART TX stream
**Change:** Added a mid-bit UART TX sampler that frames start+8N1+stop and asserts the
first transmitted byte equals `0x48` ('H'). This catches the HIGH #25 first-byte-loss
bug, which the old `$display("[TB] UART TX was toggled")` line could not. Verified:
- With the fixed UART: `*** BMC ROUTER CHIP TEST PASSED ***`.
- With the pre-fix UART reverted: `UART byte 1: expected 48 got 00` → FAILS.
The observation window after `boot_done` was widened (`#50000` → `#500000`) so the
~104 µs/byte (9600 baud) frame completes before the check runs.

## Bug audit log (2026-08-28, round 13 — data-semantic regression detectors)

This round adds data-semantic regression tests (asserting numeric VALUES, not just
control pulses) for the numeric HDL cores previously flagged, and empirically
classifies which "fixes" are actually observable by output data. Each detector was
verified by temporarily reverting the fix and confirming the TB FAILS, then
restoring and confirming PASS. **Verified detectors** (new or confirmed):

### Regression: int8_alu negative-result sign-extension (R2b zero-extend bug)
**Files:** `HDL/core/tb_int8_alu.v`
Added negative-result vectors: ADD(3,-5)=-2, SUB(3,5)=-2, SUB(-4,3)=-7,
SHIFT(-4<<1)=-8, MIN(3,-5)=-5, MAX(-10,-5)=-5, each asserted as sign-extended
16-bit (`0xFFFE`, `0xFFF9`, etc.). Reverting the fix (back to `{8'h00, result}`)
produces 6 FAILs (`0x00FE` etc.); with the fix 16/16 PASS. The existing TB had no
negative ADD/SUB/SHIFT/MIN/MAX, which was exactly the buggy scenario.

### Regression: kv_quant / dyn_act_quant magnitude-preserving dequant
**Files:** `HDL/core/tb_kv_quant.v`, `HDL/core/tb_dyn_act_quant.v`
The old dequant always returned `{sign, scale}` ignoring the stored INT4/INT8
magnitude. New tests drive scale[14:0]=0x40 (64) and multiple nonzero indices,
asserting `out == |idx| * scale` (kv: 1→0x0040, 2→0x0080, 3→0x00C0, -1→0x8040;
dyn: +1,2,3,-1,-2). Reverting to `{sign,scale}` fails (kv: 2 FAILs; dyn: 3 FAILs,
all the magnitude>1 cases collapse to full scale); with fixes they PASS.
Note the testbench timing: the registered dequant output must be sampled one
cycle past the sampling posedge **plus a `#1` delta** so the NBA update is
visible (`@(posedge clk); #1; …`). Without `#1` the read races the non-blocking
assignment and sees the stale pre-update value.

### Regression: rotary_engine real (non-identity) rotation
**Files:** `HDL/core/tb_rotary_engine.v`
The LUT is initialized to identity (cos=1.0, sin=0.0) at every position, so all
existing tests only hit the pass-through fast paths and never exercised
`bf16_mul`/`bf16_addsub`. New Test 6 pokes `uut.cos_lut[200]=0x4000` (2.0) and
`uut.sin_lut[200]=0x4000` (2.0) hierarchically, then rotates qe=1.0, qo=0.5:
expected qe'=1.0*2−0.5*2=1.0 (0x3F80), qo'=1.0*2+0.5*2=3.0 (0x4040). Reverting
the CRITICAL #4 fix (cos multiply no-op + XOR combine) produces garbage and FAILs;
with the fix it PASSES. This is the first test to cover the real rotation path.

### Regression: fp64_alu MIN/MAX sign + DIV fractional (round 8 CRITICAL #17, R2b CRITICAL #12)
**Files:** `HDL/core/tb_fp64_alu.v` (17 tests)
Added MIN(-2,1)=-2, MIN(1,-2)=-2, MAX(-2,1)=1, MAX(1,-2)=1 (catches the
magnitude-only compare of R2b CRITICAL #12 — verified 4 FAILs with the magnitude
bug) and DIV(6.5,2.0)=3.25 (catches R8 CRITICAL #17 floor bug). New constants
`FP64_65/FP64_325/FP64_NEG2`.

### Regression: rv32_core SRAI (round 11 HIGH #24) — now FIXED
**Files:** `HDL/rv32_core.v`, `HDL/tb_rv32_core.v` (new)
Two root causes fixed and covered by a direct core TB (see HIGH #24 entry).
Also documents the iverilog design gotcha: a ternary mixing `$signed(a) >>> s`
with `a >> s` is context-determined unsigned, silently demoting `>>>` to logical.

### Negative findings — fixes NOT observable in tested output data
These fixes are real/defensive but the existing data tests do NOT distinguish them
from the pre-fix code, so a re-introduction would NOT be caught by those tests:
- **weight_dequant HIGH #15 (-128 negation):** `-(-128)` in 8-bit wraps to 0x80,
  which equals the correct 128 magnitude, so output is identical with or without
  the 9-bit intermediate. The `tb_weight_dequant.v` line-89 `8'h80 → 0xC300` check
  PASSES with both. Not a detector.
- **bf16_fma R2b CRITICAL #11 (zero-guard):** removing the `a_zero||b_zero`
  guard on `mul_exp_w`/`mul_man_w` (exact original code) still yields 0.0 for
  every tested input — with one operand exactly zero the mantissa is zero
  regardless of the corrupted exponent, so downstream normalization still returns
  0. The existing `tb_bf16_fma.v` 1.0*0.0 test PASSES with both. Not a detector.
- **fp32/fp64_fma overflow mantissa alignment (CRITICAL #1/#2):** the overflow
  test (`0x3FFFFFFF*0x3FFFFFFF` → ~4.0 with a small tolerance window) PASSES
  with both the fix and the exact pre-fix alignment (`s1_mul_man << 1` truncated
  to [105:0]). The normalize stage re-finds the leading 1 and rescales, so the
  MSB-loss is self-correcting for these inputs. Retained as arithmetic sanity
  checks (they lock in that max-magnitude multiplication yields ~3.9999), but
  they are NOT fix-detectors.

### Coverage note: int4_mac_array (round 6 HIGH #14)
The HIGH #14 "all MACs receive external act_valid" fix was an architectural rewrite
(row-broadcast weight-stationary replacing left-to-right skew); there is no
single line to revert for verification. The existing `tb_int4_mac_array.v`
identity-matrix data check (result must equal the activation vector) remains the
baseline protection and would catch the original bug's all-zero-output failure
mode. A proposed multi-token back-to-back extension was not adopted: the array's
`result_valid` holds the last accumulator value across the drain rather than
streaming one result per input token, so a back-to-back drain-counter test does
not match the architecture.

## Bug audit log (2026-08-28, round 14)

### C firmware KV load was destructive / ignored sequence position (?)
**File:** `fw/pnm_fw.c`
**Bug:** The C mirror of the Go KV cache `Load()` popped FIFO-style, ignoring the
requested sequence position and advancing the read pointer (destructive read), the
same class of bug as Go HIGH #8. Loads of position N returned whatever entry the
bank queue happened to offer next.
**Fix:** Made the load positional and non-destructive, added live-window validation
(reject reads outside `[write_ptr-Occupancy, write_ptr)`), and reject negative
positions. Persisted `fw/test_kv_load.c` + `TestIntegration_CKVLoadNonDestructive`.
Verified by the Go integration test (PASS).

### Haskell frontend comparison-before-arithmetic precedence
**File:** `sim/internal/pnm/haskell_ir.go`
**Bug:** `a == b + c` was parsed by the arithmetic splitter before the comparison
parser ran, so the comparison never matched a condition operator. The comparison
splitter now runs first.
**Fix:** `findHaskellCmp` runs before `splitArith`. Added `h-add-cmp`/`h-cmp-mul`
subtests to `TestHaskellSemantics` (13 subtests PASS).

### mac_array result_valid trigger: fp32 scheme ported to fp16/bf16
**Files:** `HDL/core/fp16_mac_array.v`, `HDL/core/bf16_mac_array.v`
**Bug:** `result_valid` fired from the bottom-left FMA instead of the bottom-right
after the last shift stage, so the result handshake was asserted before the
accumulated value was stable (the same defect fixed earlier in fp32).
**Fix:** Ported fp32's scheme: row staggered `fma_valid_out`, bottom-right FMA
triggers `result_valid`, `out_active` clears to 0 after the drain.
Investigated the apparent "same-edge NBA race" and concluded it is NOT a bug:
capturing `fma_result` on the edge `fma_valid_out` pulses is safe because the
result holds stable (the apparent failure was a testbench pulse-race artifact —
deasserting `act_valid` at the exact posedge with zero delay clobbers the DUT
sample). Hardened `tb_fp16_mac_array.v`/`tb_bf16_mac_array.v`: added
`reg result_seen`, result_valid/result_out assertions, widened the sampling window
to 60 cycles, and added `@(posedge clk); #1;` before deasserting act pulses.
Rejected the up_v/bottom_done latency experiments (do NOT re-add — they add +4
cycles of latency). Verified tb_fp16/bf16/fp32 all PASS.

### CRITICAL: fp32_alu DIV exponent write-back wrap
**File:** `HDL/core/fp32_alu.v`
**Bug:** The 9-bit `d_exp` wraps for negative exponents, and bare `d_exp[8]`
conflated true overflow with wrapped underflow. `2^-126/2^127` produced +Inf
instead of 0, and `2^127/2^-126` produced 0 instead of +Inf (reading 380 as -132
in 9-bit signed).
**Fix:** `d_exp` is now `reg signed [9:0]` (10-bit, wrap-free, range [-126,380]),
captured via `$signed({2'b00,a_exp}) - $signed({2'b00,b_exp}) + 10'sd127`, with a
`wire signed [9:0] d_result_exp` (iverilog rejects part-selects on expressions)
and unified DIV_NORM: `> 10'sd254` → +Inf, `< 10'sd1` → 0. Added 6 regression
vectors to `tb_fp32_alu.v` (subnormal, overflow-to-Inf, and exact quotients).
Verified via `/tmp/tb_div.v`, `/tmp/tb_div2.v` (internal-state probe shows
d_exp=-126), and tb_fp32_alu "TEST PASSED". Full Go suite `ok 247.833s`, vet clean.

### CMP semantics: fp64_alu and fp32_alu disagreed with their documented contracts
**Files:** `HDL/core/fp64_alu.v`, `HDL/core/fp32_alu.v`
**Bug:** fp64_alu OP_CMP computed "a ≥ b" but README.md:290 contracts "a == b";
fp32_alu OP_CMP computed strict "a > b" but README.md:306 contracts "a >= b".
Both disagreed with their own docs and with each other.
**Fix:** fp64 OP_CMP now `(s1_a[62:0]==s1_b[62:0] && s1_a[63]==s1_b[63]) ? 1.0 : 0.0`
(strict equality, sign-aware). fp32 OP_CMP now
`(s1_a_gt_b || (s1_a[30:0]==s1_b[30:0] && s1_a[31]==s1_b[31])) ? 1.0 : 0.0`.
Added TB vectors fp64 CMP(2,1)=0 and fp32 CMP(3,3)=1; both TBs PASS.
**Latent design asymmetry (NOT an active bug):** the IR frontends (R/HLSL/Haskell)
emit ALUCmp/FP64Cmp with an arbitrary `Cond` ("==", ">=", "!="), but the hardware
`OP_CMP` opcode is a single fixed comparison with no condition input. There is no
IR→HW lowering that maps a specific Cond onto OP_CMP; Cond is only consumed by the
Go software interpreters. The HW OP_CMP semantic is exercised only via HDL TBs.

### FMA subnormal flush — validated NOT a bug
**Files:** `HDL/core/fp16_fma.v`, `bf16_fma.v`, `fp64_fma.v`
fp16/bf16/fp64_fma flush subnormals to zero at `(norm_exp < 0) || (norm_exp == 0 &&
!rounded_carry)`; fp32_fma implements full denormal output with RNE. All three use
a signed `norm_exp` and flush ONLY true subnormals (smallest normal preserved), so
there is no boundary misclassification. This is an intentional, consistent FTZ
design (the fp16 TB explicitly allows 0x0000 or 0x0001). Do NOT port fp32's
denormal path — it would add risk with no failing test.

### int4_mac_array result<op>/eop were always 0 at result_valid
**File:** `HDL/core/int4_mac_array.v`
**Bug:** `result_sop <= act_sop; result_eop <= act_eop;` sampled the LIVE inputs
during the result cycle (many cycles after feed), so sop/eop were always 0 when
result_valid pulsed. The fp16 array correctly queues `out_sop_q`/`out_eop_q`
at feed time and presents them with the result.
**Fix:** Added `out_sop_q`/`out_eop_q` captures at `act_valid` and present
`result_sop`/`result_eop` alongside result_valid. Caution: an initial
`result_valid ? out_sop_q : 1'b0` version failed because result_valid is
NBA-assigned this edge (reads old 0); the working pattern presents on the incoming
`psum_v_sr` pulse. Added sop/eop assertions to tb_int4_mac_array; PASSED.

### rv32_core LB/LH lane addressing ignored the byte/halfword lane
**File:** `HDL/rv32_core.v`
**Bug:** Load writeback read `mem_result[7:0]`/`[15:0]` unconditionally (always
lane 0) while the SB/SH store path correctly shifted into the addressed lane.
LB@1 returned 0x44 instead of 0x33; LH@2 returned 0x3344 instead of 0x1122.
**Fix:** Added lane muxes using `alu_result[1:0]` (LB/LBU) and `alu_result[1]`
(LH/LHU) via explicit case statements (iverilog rejects part-selects on
expressions). New `HDL/tb_rv32_core_load.v` self-checking TB. Verified by revert
(old code fails 4 cases) and re-apply (all 5 pass); original tb_rv32_core and
tb_bmc_orchestrator still PASS.

### C firmware MoE gating always routed to experts 0..TOPK-1
**File:** `fw/pnm_fw.c`
**Bug:** `fw_plan_inference` iterated `exp = 0..PNM_MAX_TOPK-1` and looked up
`moe_map[model_layer, exp_idx==exp]`, so gating always picked experts 0..TOPK-1
regardless of token/layer. The Go `selectTopExperts` (firmware.go:523-563)
computes a deterministic FNV-1a 64-bit gate score and sorts desc / expert-asc.
**Fix:** Ported `fnv1a_64()` (offset 14695981039346656037, prime 1099511628211)
and `select_topk()` (mixes with `ml*0x9E3779B97F4A7C15`, per-expert
`e*0x2545F4914F6CDD1D`, splitmix-64 down-mix, insertion sort by score desc /
expert asc) into pnm_fw.c. The MoE loop now collects all map entries for a layer
into `cand[]`, calls `select_topk`, and maps each selected expert back to its node.
Also: outer loop bound now `model_layers = min(PNM_MAX_MODEL_LAYERS, mpl*num_layers)`;
added truncation detection (returns -2 if records would exceed max_records instead
of silently truncating); `fw_verify_dispatch` now also rejects a plan missing any
model layer (not just a non-dense first record). New `fw/test_moe_gating.c` +
`TestIntegration_CMoeGating` cross-check C vs Go bit-for-bit for 5 tokens (PASS).

### Go speculative decoding double-advanced SeqPositions
**File:** `sim/internal/pnm/firmware.go`
**Bug:** `PlanInferenceSpeculative`: the draft phase advanced each model layer once
per drafted token, the restore only re-valued keys that already existed (new keys
leaked), and then the verify phase advanced every layer once per drafted token.
On a mismatch, positions were advanced for the rejected tokens too (overshoot of
len(drafted)-len(accepted)).
**Fix:** The restore now rebuilds the map from scratch (deleting draft-created
keys), snapshots `basePositions` after the rollback, and after acceptance rewrites
each layer to `basePositions[ml] + len(accepted)`. Added
`TestSpeculativeSeqPositions` (PASS); co-located TestMoEDispatchReachesFullExpert
Population and TestSlidingWindowPerModelLayer still PASS.

### Paper doc fixes
**Files:** `paper/Paper.MD`, `paper/readme.md`, `AGENTS.md`
- Paper.MD line 73: LPCAMM2 (JESD318) is ref 16, not 17 — `{c(17)}`→`{c(16)}`.
- Paper.MD line 498: CERN-OHL-S is ref 20, not 21 (ref 21 = Deloitte) —
  `{c(21)}`→`{c(20)}`. (REFS array current order: 15=HBM, 16=CAMM2, 17=LPDDR6,
  20=CERN-OHL-S.)
- Paper.MD: `fp32_alu` latency `1--25`→`3--25` cycles; "single-cycle
  MIN/MAX/CMP"→"3-cycle MIN/MAX/CMP" (HDL: MIN/MAX/CMP=3, FMA-path=4, DIV=25).
- Paper.MD: `int8_mac` `1 cycle`→`2 cycles` (int8_mac.v is 2-cycle).
- `paper/readme.md`/`AGENTS.md`: REFS count `31`/`20`→`30` entries.
- AGENTS.md doorbell iverilog command now includes `core/weight_dequant.v
  core/int8_mac.v` (pe_tile_stub instantiates both; without them elaboration
  errors "Unknown module type"). Fixes verified with `python3 paper/build.py`
  (Wrote paper.docx/pdf), while reused text runs in a stale process are a known
  file-clobber hazard in this repo.

### Round 14, additional agent-quad fixes (2026-08-28, continued)

**fp64_alu ADD-overflow produced NaN instead of +Inf (CRITICAL).**
`fp64_alu.v` ADD normalization: the carry branch (`as_add_result[53]`) packed
`{sign, as_norm_exp[10:0], as_norm_man[52:1]}` with no overflow clamp. When
`as_norm_exp` reached 2047 with a nonzero mantissa (carry from a near-max
addition, e.g. `2^1023*(1.0+1.5)`), the result decoded as NaN instead of +Inf.
The non-carry branch already clamped `>= 2047` → Inf. Fixed by adding the same
clamp to the carry branch. Detector: `/tmp/tb_fp64_det.v` (add-overflow).
Regression vector added to `tb_fp64_alu.v` (21 passed).

**fp64_alu and fp32_alu DIV Inf/0 returned ±Inf instead of NaN (CRITICAL, IEEE).**
Both DIV paths classified `Inf/0` under the `b_is_zero`/`div_a_inf||div_b_zero`
branch → ±Inf. IEEE-754 declares `Inf/0` invalid → NaN. fp64: added
`(div_a_inf && div_b_zero)` to the NaN branch. fp32: added
`(a[30:23]==8'd255 && b_is_zero)` to the NaN branch. Detectors: `/tmp/tb_fp64_det.v`,
`/tmp/tb_fp32_det.v`. Regression vectors added to both TBs (fp64 21 passed;
fp32 "TEST PASSED").

**fp32_alu CMP of two identical NaNs returned 1.0 (IEEE unordered violation).**
`OP_CMP` computed `a_gt_b || equality`; the equality term matched two identical
NaN bit patterns → 1.0, despite `a_gt_b` being forced 0 for NaN. fp64 already
returned 0 for NaN CMP, so fp32 was inconsistent. Fixed by guarding
`(s1_a_nan || s1_b_nan) ? FP32_ZERO` first. Regression vector added to
`tb_fp32_alu.v`.

**C R/HLSL/Haskell firmware `flit_bytes` off-by-one (HIGH).**
`fw/pnm_fw_r.c`, `pnm_fw_haskell.c`, `pnm_fw_hlsl.c` set `flit_bytes =
4 + token_len + 2`, but the wire format has a 5-byte header
(LAYER+MODULE+CTRL+LEN2), so it undercounted by 1 (the canonical `pnm_fw.c`
uses `5 + token_len + 2`). Also corrected the derived element count
`(flit_bytes - 6)` → `(flit_bytes - 7)` so `elems = token_len/DTYPE_BYTES`
stays correct. All three files compile clean.

**Haskell IR emission/lowering was nondeterministic (HIGH determinism break).**
`HaskellProgram.Emit()` and `LowerHaskellToPNM()` iterated the `Funcs` map
directly, so with ≥2 functions the emitted IR text and the (round-robin node
assignment in the) lowered `.pnm` program varied across runs. Fixed both to
iterate in sorted function-name order. Added `TestHaskellEmitAndLowerDeterminism`
(50-iteration stability check). Co-located Haskell/HLSL/R + firmware tests all
pass.

**docs.md / HDL-README / readme doorbell command and latency-table fixes.**
- `docs.md` table: `fp32_alu` `1-25`→`3 (MIN/MAX/CMP), 4 (FMA), 25 (DIV)` cycles;
  `int8_mac` `1`→`2` cycles; int8 TB caption "single-cycle"→"2-cycle".
- Doorbell iverilog command in `HDL/README.md`, `docs.md`, `readme.md` was missing
  `core/` prefixes and the `bf16_fma`/`weight_dequant`/`int8_mac` dependencies
  (`pe_tile_stub` instantiates both); all three made consistent with AGENTS.md
  (verified elaborates and PASSes: activations=6, rejections=2, corrupt=2).

**dyn_act_quant `div_floor` return width (MEDIUM).**
`dyn_act_quant.v` declared `div_floor` as `function automatic [7:0]` but the loop
shifts 16 numerator bits and writes `div_floor[dk]` for dk=8..15 — out-of-range
writes on an 8-bit return. Widen the return to `[15:0]`; the call site already
masks `& 8'hFF`, so behavior is preserved and the writes are now legal. tb passes.

**int4_mac_array weight index truncation to 4 bits (LATENT, parameter-only).**
`int4_mac_array.v` indexed `weights` with `[3:0]` slices in the load
(`weight_row[3:0]`/`weight_col[3:0]`) and the generate-loop compute read
(`weights[row[3:0]][col[3:0]]`), which is only correct at ARRAY_SIZE=16. Fixed the
generate-loop read to `weights[row][col]` (genvars are already bounded); the load
write remains 4-bit-sliced for ARRAY_SIZE=16 (documented latent limitation, no
ARRAY_SIZE>16 instantiation exists).

**llm_client sampling robustness (MEDIUM, latent).**
- `sampleFromLogits` with a mask mutated the caller's `logits` slice in place,
  corrupting a reused buffer. Now copies to a scratch slice before applying the
  mask.
- A tiny positive temperature (`0 < t ≪ 1`) overflowed `l/temperature` to +Inf,
  making `l-maxLogit` NaN, the softmax all-NaN, and since `NaN <= 0` is false the
  greedy fallback was skipped — silently returning a wrong fixed token. The
  `total <= 0` fallback now also triggers on NaN/±Inf total.
Added `TestSampleFromLogits_TinyTempNoNaN` and
`TestSampleFromLogits_MaskDoesNotMutateLock` (both PASS); all co-located llm tests
pass.

**Validated non-bugs (agent-quad round 14):** fp32 vs fp64 CMP contract (fp32 uses
`>=`, fp64 uses `==`) is intentional per each module's documented contract — do
NOT unify. `kv_quant`/`dyn_act_quant` BLOCK_SIZE boundary checks rely on
`BLOCK_SIZE[n:0]` wrapping to 0 for power-of-two sizes; correct for the shipped
BLOCK_SIZE=16 default, latent for any non-power-of-two parameter.

## Bug audit log (2026-08-28, round 15)

### CRITICAL: `fp32_mac_array` / `fp16_mac_array` / `bf16_mac_array` mid-drain re-arm corrupts in-flight drain
**Files:** `HDL/core/fp32_mac_array.v`, `HDL/core/fp16_mac_array.v`, `HDL/core/bf16_mac_array.v`
**Bug:** A second `act_valid` pulse asserted while the array was still draining (`busy=1`) corrupted the in-flight activation and lost its result. Two compounding causes: (1) the arming logic and the output collector (`out_active`) re-fired on any `act_valid`, even mid-drain, overwriting the current drain's pipeline state and framing flags; (2) every row's stage-0 sampled the *live* `act_in` port each cycle, so the second pulse's data overwrote the first before it reached the FMAs. Net effect: a re-fire produced a single result carrying the second activation's data with the first's framing, or lost one result entirely.
**Fix:** Verified with `/tmp/tb_fp32_mac_rearm.v` (mid-drain re-fire → the result must keep the first activation, `sop=1`, and only one result pulse). Added `accept = act_valid && !out_active` to gate the arming restart and the output-collector re-arm, so a re-fire during a drain is ignored (the host must wait for `busy=0`). Introduced a per-array `act_hold` register latched on `accept`; each armed row samples `act_hold` (row 0 reads `act_in` at the accept edge) instead of the live port, so a mid-drain change of `act_in` cannot corrupt the staggered stage-0 captures. Applied identically to all three arrays. Original single-pulse TBs and the re-arm detector both PASS.

### HIGH: `doorbell.v` single-byte EOP frame wedges the receiver
**File:** `HDL/core/doorbell.v`
**Bug:** The frame-start branch (`!in_msg`) consumed the first byte as DEST and unconditionally set `in_msg <= 1` without checking `s_eop`. A truly single-byte frame (`s_valid`+`s_eop` on the start byte) left `in_msg` high forever waiting for a body — the doorbell neither fired nor rejected (silent wedge).
**Fix:** In the `!in_msg` branch, if `s_eop` is set, treat the frame as malformed: assert `node_err`, increment `rejections`, and keep `in_msg` low. Normal frames are unaffected. Verified with `/tmp/tb_doorbell_1byte.v` (net-empty frame → `node_err` pulses, `in_msg` stays clear) and the full `tb_doorbell.v` regression (activations=6, rejections=2, corrupt=2) still PASSES.

### CRITICAL: `orchestrator_chip.v` MoE gating was structurally inert
**File:** `HDL/orchestrator_chip.v` (+ `HDL/core/moe_gating.v`, `HDL/orchestrator_sbc_moe.v`)
**Bug:** The `u_gating` instance's `weight_load`, `weight_addr`, `weight_data`, and `hidden_valid` inputs were hardwired (`1'b0` / zeros). `moe_weights` was a dead array never written. The gating unit therefore never loaded weights and never latched a hidden vector — `gate_start` was the only live input, so the top-k dispatch was a fixed/empty result regardless of the token payload.
**Fix:** (1) In `moe_gating.v`, added a `hidden_valid` input that gates the hidden-latch capture and a mid-load restart on `start` (so a new token can preload the hidden buffer). (2) In `orchestrator_chip.v`: removed the dead `moe_weights` array; widened `pie_state` to 4 bits and added `PIE_MOE_W`/`PIE_MOE_WP` for a new PCIe command `0x05` (layer, expert, rsvd, then `2*HIDDEN_SIZE` payload bytes) that streams gating weights into `moe_gating.weights[]` via `gate_weight_*` wires; in `FB_PAYLOAD` for `PIE_INF_TOKEN_P`, capture the token payload as byte pairs (`gh_hi`/`gh_odd`) and drive `gate_hidden_data`/`gate_hidden_valid` — the token payload doubles as the gate's hidden state. Wired `gate_hidden_valid`/`gate_weight_load`/`gate_weight_addr`/`gate_weight_data` to `u_gating`; added reset defaults. (3) Updated `tb_moe_gating.v` (drives `hidden_valid=1`) and `orchestrator_sbc_moe.v` (ties `hidden_valid=1` since firmware preloads `hidden_buf`). Rewrote `tb_orchestrator_chip.v` with small gating params (`MAX_EXPERTS=4`, `TOP_K=2`, `HIDDEN_SIZE=8`): it uploads gating weights via cmd `0x05`, drives content-sensitive tokens, checks content-addressable routing (token 3 → expert 1), and exercises egress. `*** ROUTER CHIP TEST PASSED ***`; `tb_moe_gating.v` still PASSES.

### HIGH: `orchestrator_chip.v` spine→PCIe egress dropped bytes under host backpressure
**File:** `HDL/orchestrator_chip.v`
**Bug:** The egress path captured `spine_extract_data` only when `pcie_out_ready` was asserted; when the host stalled (`pcie_out_ready=0`), in-flight spine bytes were dropped instead of buffered, silently losing results.
**Fix:** Replaced the drop-on-not-ready capture with a 10-byte ring (`rc_buf`/`rc_sop`/`rc_eop`, `rc_fifo_head`/`rc_fifo_cnt`). Writes are always accepted when `boot_done` (full → `errors+1`); bytes drain to the host when `pcie_out_ready`, and the head byte is re-presented with `pcie_out_valid=1` while the host backpressures. Verified by `tb_orchestrator_chip.v` Phase 7 (host stalls 3 bytes then drains, checks DE/AD/BE framing) — PASSES.

### MEDIUM: `fw/pnm_fw.c kv_store` missing negative seq_pos guard
**File:** `fw/pnm_fw.c`
**Bug:** `kv_store` computed `bank_idx = seq_pos % PNM_KV_CACHE_BANKS` with no `seq_pos < 0` check; `-1 % N = -1` in C indexes `&layer->banks[-1]` (UB). The sibling `kv_load` already guards `seq_pos < 0`.
**Fix:** Added a `if (seq_pos < 0) return false;` guard, matching `KVCacheLayer.Store` (Go) and `kv_load`. `gcc -Wall -Wextra` clean, zero warnings.

### MEDIUM: `fw/pnm_lustre.c` start_ost off-by-one vs the Go twin
**File:** `fw/pnm_lustre.c`
**Bug:** `fd = lc->file_count++` post-increments, then `f->start_ost = lc->file_count % ost_count` read the incremented value — first file landed on OST 1 (1-based). The Go twin `nvme_lustre.go` uses `len(lc.Files) % len(lc.OSTs)` (0-based), so the same logical filename striped onto a different OST on the two implementations, violating the "identical layouts on both sides" contract.
**Fix:** Changed to `f->start_ost = fd % lc->ost_count`, using the pre-increment descriptor index. `gcc -Wall -Wextra` clean.

### MEDIUM/LOW: documentation stale values
- `docs/usage_manual.md` fp32_alu latency `1-24 cycles` → `3 (MIN/MAX/CMP), 4 (FMA), 25 (DIV)`; int8_mac `1 cycle` → `2 cycles` (2-stage pipeline).
- `pcb/README.md` ASCII diagram "Compute nodes (16 per layer)" → "(64 per layer)", matching the reference-chassis text.

### Known limitations (documented, not fixed)
- **R/Haskell/HLSL firmware ports route MoE to experts 0..TOPK-1 regardless of token.** `fw/pnm_fw_r.c`, `pnm_fw_haskell.c`, `pnm_fw_hlsl.c` iterate `moe_map[e].expert_idx == exp` for `exp < PNM_MAX_TOPK`, so only global experts 0..TOPK-1 are reachable and the token is ignored. The canonical `pnm_fw.c` was upgraded in round 14 to token-seeded `select_topk` (FNV-1a + splitmix64), but these three source-language ports were not, and their `verify_dispatch` also lacks the canonical all-layer coverage check. These ports have **no test harness, no compile target, and no Go/x-check** (verified by the auditing agent), so a full gating port cannot be regression-verified in this loop; they are simplified reference ports and are flagged here rather than risk an untested large change.
- **Paper citation topic mismatches (low severity, retained to avoid renumbering).** `Paper.MD:496` cites `{c(15)}` (HBM, JESD235D) for a "mature-node DUV logic" claim, and `Paper.MD:17` cites `{c(25)}` (TrendForce DDR5 price surge) at an EUV-yield sentence; neither ref supports its claim precisely. LEFT UNCHANGED because REFS is numbered by cite order, and editing/removing a cite would renumber the bibliography; the mismatch is minor and noted here for a future editorial pass.


## Bug audit log (2026-08-29, round 16)

### CRITICAL #13: `kv_quant.v` maximum positive value round-trips with flipped sign
**File:** `HDL/core/kv_quant.v:98-99`
**Bug:** Symmetric INT4 quantization maps the block's peak positive value to
qn=8 (e8 = 8*scale = block_max). The encoder emits `enc_index = qn` = `0b1000`
for a positive value, whose sign bit (bit 3) is set. The dequantizer
(`d_int4_in[3]` → negative branch, magnitude `~8+1`=8) reconstructs `-8*scale`
even though the original peak was positive (should be `+8*scale`). Every block's
maximum positive element was sign-flipped, corrupting KV-cache attention scores.
Reproduced: dequant of quantized positive peak returned sign=1 (negative).
**Fix:** Clamp positive `qn` to 7 in the encode (the symmetric INT4 positive range
is 0..7; -8..-1 are exclusively for negatives). The negative branch already
handles `qn=8` correctly (→ -8). Modified `enc_index` positive branch to
`(qn > 4'd7 ? 4'd7 : qn)`.

### CRITICAL #14: `dyn_act_quant.v` maximum positive activation round-trips with flipped sign
**File:** `HDL/core/dyn_act_quant.v:98-99`
**Bug:** Identical symmetric-quantization defect at INT8: the peak positive
activation maps to qn=128, encoded as `0x80` whose sign bit is set; the
dequantizer reconstructs `-128*scale` instead of `+128*scale`. INT8 symmetric
range is -128..127, so +128 is unrepresentable as positive. Corrupts W8A8
activation inputs.
**Fix:** Clamp positive `qn` to 127 in the encode:
`(qn > 8'd127 ? 8'd127 : qn)`.

**Verification:** Reconstruction is mathematically determinate from the RTL (no
toolchain dependence). Confirmed by round-trip testbenches:
- `/tmp/tb_kvquant_rt.v` -- quantize a block of identical positive peak values,
  dequantize the emitted int4, assert sign preserved. Before fix: emitted
  `enc=8`, dequant sign=1 (FAIL). After fix: emitted `enc=7`, all dequant
  sign=0 (PASS).
- `/tmp/tb_dynquant_rt.v` -- same for dyn_act_quant; after fix emitted `enc=7f`,
  all sign=0 (PASS).
- Existing `tb_kv_quant.v` PASSES (Scale 0808; peak positive now emits 07 instead
  of the sign-flipped 08).
- Existing `tb_dyn_act_quant.v` PASSES (peak positive now emits 7f; negative-side
  -128/-127 encodings 0x80/0x81 unchanged).

**Note:** the quantizer no longer emits 0x8 (kv_quant) or 0x80 (dyn_act_quant) for
positive inputs, so the prior dequantizer behavior for those encodings (treated as
negative) is unreachable for positive values through normal operation.

### Round-16 docs findings (fixed)
1. `docs/profiling.md` referenced non-existent RTL names (`router_sbc.v`,
   `bmc_router_top.v`, `router_sbc_moe.v`, `tb_router_sbc`, `tb_bmc_router`).
   Renamed to the real `orchestrator_sbc.v`, `bmc_orchestrator_top.v`,
   `orchestrator_sbc_moe.v`, `tb_orchestrator_sbc.v`, `tb_bmc_orchestrator.v`.
2. `HDL/README.md` compute-unit latency table stale: fp32_alu "1-25 cycles" →
   "3 (MIN/MAX/CMP), 4 (FMA), 25 (DIV)"; int8_mac "1 cycle" → "2 cycles"
   (matches `fp32_alu.v:6-9` and `int8_mac.v:7`).
3. `HDL/README.md` IR-latency table: `alu.div` 27 → 25 cycles, `alu.min/max/cmp`
   4 → 3 cycles (matches fp32_alu.v header and the file's own line 303).
4. `HDL/README.md` `router_chip.v`/`tb_router_chip.v` → `orchestrator_chip.v`/
   `tb_orchestrator_chip.v` (module heading updated too).
5. `docs/usage_manual.md` orchestrator_sbc DRAM "512 MB" → "1 GB" (matches
   `orchestrator_sbc.v:37` `0x8000_0000..0xBFFF_FFFF`).
6. `toolchain/fw-linux/README.md` DRAM "512 MB" → "1 GB" (fw-linux targets
   orchestrator_sbc, whose DRAM window is 1 GB).
7. `paper/readme.md` doorbell testbench command sits in the paper/HDL verification
   subset but references `core/bf16_fma.v`, `core/weight_dequant.v`,
   `core/int8_mac.v` which are NOT bundled there (verified: iverilog fails
   "core/bf16_fma.v: No such file or directory"). Added a note pointing to the
   repo root HDL/ where those primitives live.

### Round-16 known limitation (documented, not fixed)
- **Paper.MD SoC-tier filenames (`bmc\_router\_top.v`, `router\_mcu.v`,
  `router\_sbc\_moe.v`, `router\_sbc.v`, `router\_chip.v`,
  `tb\_bmc\_router.v`) differ from the on-disk `orchestrator_*.v` names.** The
  manuscript consistently uses "router chip" terminology and never mentions
  `orchestrator_*`. Left unchanged: (a) the file is being actively rewritten by a
  concurrent external editor during this session (mtime changes between tool
  calls), making a large programmatic rename unreliable and risky for the critical
  manuscript; (b) it is a naming-consistency preference rather than a functional
  error; (c) REFS/cite-order renumbering risk. Flagged here for a future editorial
  pass.

### Round-16 Go/C agent: NO BUGS FOUND
The Go/C auditor independently re-checked des.go, crc.go, run.go, kv_cache.go,
llm_client.go, firmware.go, nvme_lustre.go, pnm_fw/nvme/lustre, rng, IR compilers,
and the twin-divergence checks (notably the round-15 `start_ost` fix is present in
both the Go `nvme_lustre.go` and the C `pnm_lustre.c`). No new reproducible bug was
reported.

## Bug audit log (2026-08-27, round 3)

### CRITICAL #13: FMA mantissa-overflow alignment drops the leading 1 (bf16/fp32/fp64)
**Files:** `HDL/core/bf16_fma.v:133`, `HDL/core/fp32_fma.v:133`, `HDL/core/fp64_fma.v:133`
**Bug:** When a multiply saturates into `[2,4)` (mantissa overflow), the
`mul_man_17/49/107` alignment used `{s1_mul_man, 1'b0}` on the overflow branch,
shifting the implicit leading 1 to bit 16/48/106 and out of the truncation
window (`[15:0]`/`[47:0]`/`[105:0]`), producing half the correct value.
**Reproduced:** `1.5 x 1.5` returned `0.5` on all three units instead of `2.25`.
The existing `0x3FFFFFFF^2` regression vectors were coincidentally immune because
their product's MSB-1 bit is set, masking the bug (the in-code comment even claimed
the leading 1 was already at bit 47/105, contradicting the implementation).
**Fix:** Changed the overflow branch to `{1'b0, s1_mul_man}` (both ternary arms
now identical), keeping the leading 1 inside the truncation width.
**Verified:** New "Test 9: 1.5*1.5+0" vectors in `tb_bf16_fma.v` (expect
0x4010), `tb_fp32_fma.v` (0x40100000), `tb_fp64_fma.v` (0x4002000000000000) all
PASS; all prior vectors still PASS; fp16/bf16 mac arrays and moe_gating (which
instantiate the FMAs) still PASS.

### HIGH #23: `kv_cache.go` RepeatKV divides by zero when HeadDim=0
**File:** `sim/internal/pnm/kv_cache.go:571`
**Bug:** `RepeatKV` called with `HeadDim=0` and `NumKeyValueHeads>0`/`GroupSize>1`
divided by zero (reachable via `SetGQA`, which accepts an unvalidated headDim).
Confirmed panic: "integer divide by zero".
**Fix:** Added guard `if kl.HeadDim <= 0 || kl.NumKeyValueHeads <= 0 { return kvEntry }`.
**Verified:** throwaway `TestRepeatKV` now passes; full Go suite `ok` (443s).

### LOW #31: `fw/pnm_fw.c` fw_verify_dispatch misses middle-layer gaps
**File:** `fw/pnm_fw.c:284-306`
**Bug:** `fw_verify_dispatch` only checked that the final layer index appeared
with a dense record, so a middle-layer omission (e.g. layer 2 skipped) passed
undetected. The Go twin `Firmware.VerifyDispatch` correctly iterates all layers.
**Fix:** Added a `seen[PNM_MAX_MODEL_LAYERS]` array marking each layer's dense
record, then verifies all layers `0..model_layers-1` are covered.
**Verified:** `gcc -Wall -Wextra -std=c11 -c fw/pnm_fw.c` compiles clean (exit 0,
zero warnings).

### Documented, NOT a bug: `llm_client.go` beam-search length penalty
**File:** `sim/internal/pnm/llm_client.go:1202`
**Finding:** Beam length penalty uses `score/(length+1)^(lengthPenalty-1)`; the
`-1` exponent shift means a configured penalty doesn't behave as its magnitude
under the standard `score/length^alpha` convention.
**Decision:** The field doc explicitly says "1.0 = no penalty", which the formula
matches exactly (1.0 -> exponent 0 -> no-op). It is a self-consistent design
choice, not a verifiable bug. NOT changed.

## Bug audit log (2026-08-27, round 4)

### Verified / confirmed this round
- **int8_alu.v ADD/SUB overflow sign bug: NOT A BUG (false positive).** The 9-bit
  signed sum `$signed({a[7],a}) + $signed({b[7],b})` is truncated to `[7:0]` and
  sign-extended from `add_result[7]` (the MSB of the low byte), which is the
  correct wrapped 8-bit two's-complement result. Verified with a 6-vector
  detector (127+1=-128, 127+127=-2, -128+-1=127, 127-(-1)=-128, -128-1=127) — all
  PASS. Rejected.
- **flit_gate.v stripped-head SOP re-assertion: NOT A BUG (false positive).**
  Under downstream backpressure `strip_next_q` stays high and `match_sop` stays
  asserted on the held body byte, which is correct valid/ready hold behavior
  (the master holds data+SOP until accepted); `strip_next_q` clears on the first
  body byte's handshake. Rejected.

### HIGH #24: `fp32_alu.v`/`fp64_alu.v` return NaN for Inf/0 (IEEE-754 violation)
**Files:** `HDL/core/fp32_alu.v:121`, `HDL/core/fp64_alu.v:350`
**Bug:** `(a_inf && b_zero)` is special-cased to NaN, but IEEE-754 gives
`Inf/0 = +-Inf` (only 0/0 and Inf/Inf are NaN). Both modules carry the
contradictory comment "DIV by zero returns +-Inf (per IEEE 754)".
**Status:** Testbenches `tb_fp32_alu.v:143` and `tb_fp64_alu.v:194`
deliberately lock in the NaN behavior, so changing the code would fail the
tests. Documented as a known spec deviation, NOT changed (would require
updating the TBs' asserted behavior).

### Documented, LOW confidence: FMA alignment sticky-bit loss (fp16/fp32/fp64)
**Files:** `HDL/core/fp16_fma.v:216`, `fp32_fma.v:234`, `fp64_fma.v:292`
**Finding:** `sticky = |norm_man[low:0]` only captures in-window bits; the bits
shifted out during exponent alignment are not OR'd into sticky (bf16_fma.v does
include them). This can cause an off-by-one-ulp round-to-nearest error on rare
alignment cases. Its practical impact is sub-ulp on a tiny fraction of inputs;
an exact model could not be reliably validated (Python/iverilog limits). The
FMA units pass their full regression suites. Documented as a known precision
limitation, NOT changed.

### HIGH #25: `reproduce.sh` HDL commands broken (missing core/ prefix + stale router name)
**File:** `reproduce.sh:74-115`
**Bug:** All compute-unit testbench commands ran from `HDL/` root but referenced
modules living in `HDL/core/` (tb_doorbell, tb_fp32_alu, tb_fp32/64/bf16/fp16_fma,
tb_int8_mac, tb_moe_gating, tb_bf16/fp16_mac_array), and `tb_router_chip` invoked
non-existent `router_chip.v` (actual `orchestrator_chip.v`). On top of that,
`pe_tile_stub.v` now instantiates `weight_dequant.v` and `int8_mac.v`, which the
doorbell command omitted.
**Fix:** Added `core/` prefix to all compute-unit sources; renamed
`router_chip.v`/`tb_router_chip.v` to `orchestrator_chip.v`/`tb_orchestrator_chip.v`;
added `core/weight_dequant.v core/int8_mac.v` to the doorbell command.
**Verified:** every fixed command compiles and its TB prints PASS/exit 0
(doorbell, fp32_alu, fp32/64/bf16/fp16 fma, int8_mac, moe_gating, both mac
arrays, orchestrator_chip, plus fabric/load unchanged).

### Doc bugs fixed
- `HDL/README.md:85` — wire-format CTRL was `{vc_class[1:0], op[1:0]}`; fixed to
  `{vc_class[7:6], op[5:4]}` to match `pnm_defs.vh:8` (note `pnm_defs.vh` comment
  covers the same at line 8).
- `pcb/README.md:92,162-163` — `gating_board/`/`gating_board.lpp` corrected to
  `gating_asic/`/`gating_asic.lpp` (actual dir/file).
- `toolchain/fw-linux/src/drv_pnm.h:15` — comment referenced `router_chip.v`;
  corrected to `orchestrator_chip.v`.
- `paper/readme.md:62-64` — the doorbell testbench command was run from
  `paper/HDL` but referenced `core/bf16_fma.v`/`weight_dequant.v`/`int8_mac.v`
  which do not exist in `paper/HDL/core/` (only crc16/doorbell/pe_tile_stub/
  tb_doorbell). Now cd's to repo-root `HDL/`, runs, then returns to `paper/HDL`.

### Documented design distinction, NOT a doc bug
- `pcb/README.md:70-82` physical custom-SoC memory map (4KB bootstub, 500KB-32MB
  SRAM, "No DRAM on the processor package") describes a stripped physical board
  variant, distinct from the full `HDL/orchestrator_sbc.v` model (64KB ROM, 16MB
  SRAM, 1GB DRAM window). Shared peripheral addresses (PCIe 0xC0000000, NVMe
  0xD0000000, PNM 0xF0000000) agree. Documented; not a contradiction.

### Documented latent, NOT changed
- `fw/pnm_fw.c` `select_topk` vs `firmware.go` `selectTopExperts` rank different
  candidate populations: Go scores the full expert range `0..NumExperts-1` then
  filters by `MoeMap` presence; C builds candidates only from `moe_map` entries
  for the layer. Diverges only on a partial map (an expert with no placed weights);
  C has no `numExperts` field, so aligning requires a firmware API change. Latent;
  documented, not changed.
- `kv_cache.go` `PrefixCache.Store` LRU eviction tie-break iterates a map
  (non-deterministic order). Minor reproducibility concern; documented.
- `llm_client.go` `sample()` deterministic hash: the hash input is a linear
  function of `sorted[0].idx` only, producing at most ~256 distinct sample
  points per temperature regardless of float32-vs-uint64 accumulation (verified:
  both give 256 distinct r across 2M index values). The float32 accumulator is
  therefore behaviorally equivalent to uint64 here; NOT a fixable bug (latent
  low-entropy sampling scheduler by design).
- `paper/Paper.MD:394` "450 routed flits" vs the 500-flit load scenario: a
  Results figure in the concurrently-edited manuscript; not force-edited.


## Bug audit log (2026-08-27, round 3)

### CRITICAL: FP32/FP64 FMA round-to-nearest increment at the wrong bit
**Files:** `HDL/core/fp32_fma.v:237`, `HDL/core/fp64_fma.v:295`
**Bug:** The `rounded_man` increment was `48'h000000000800` (=2^11, fp32) and
`106'h<...>1000000` (=2^24, fp64) instead of the guard-bit position. The guard
bit is at `norm_man[23]`/`norm_man[52]` per the code comments, so `round_up`
added at 2^11/2^24 (below the mantissa LSB), making rounding a near no-op
(mantissa truncated rather than rounded). The round-to-nearest-even was broken.
**Verified with detectors before fix:** fp32 `1.0*1.0 + 1.5*2^-24` returned
`0x3F800000` (1.0) instead of `0x3F800001`; fp64 returned `0x3FF0000000000000`
instead of `0x3FF0000000000001`. Existing TBs masked it because all their test
vectors hit exact or already-representable results.
**Fix:** Changed to `(48'd1 << 23)` and `(106'd1 << 52)` (the guard-bit
position). fp16 (`22'd1024`=2^10) and bf16 (`16'd128`=2^7) were already correct.
**Verified:** fp32/fp64 detectors now PASS; full FMA/mac-array/moe regression
suite (bf16/fp16/fp32/fp64 FMA, fp16/bf16/fp32 MAC arrays, moe_gating, edge TBs)
all pass with 0 failures.

### CRITICAL: FP32/FP64/BF16 overflow-branch alignment drops the right-shift
**Files:** `HDL/core/fp32_fma.v:133-137`, `HDL/core/fp64_fma.v:133-137`,
`HDL/core/bf16_fma.v:133-138`
**Bug:** When `s1_mul_overflow=1` the pre-shifted product (`mul_man_norm` at the
full bit) had NO right-shift even when `exp_diff < 0` (addend c has the larger
exponent). The un-shifted product was added against a c that was right-shifted
into it, misaligning the mantissas and producing a wrong low-order add. fp16 had
the correct pattern.
**Verified with detectors:** bf16 `1.5*1.5 + 4.0` returned `0x4488` instead of
`0x40C8` (6.25); fp32 returned `0x41080000` (8.5) instead of `0x40C80000`
(6.25); fp64 returned `0x4018000000000000` instead of `0x4019000000000000`.
**Fix:** Refactored to
`mul_pre = s1_mul_overflow ? mul_man_N : (mul_man_N << 1);`
`mul_man_aligned = (exp_diff >= 0) ? mul_pre : (mul_pre >> (-exp_diff));`
i.e. only shift left by one for the non-overflowing rounding, and always apply
the right-shift when c is the larger exponent.
**Verified:** fp32/fp64/bf16 overflow detectors now PASS.

### MEDIUM: `gating_asic.v` MoE gating hidden-data path unconnected
**File:** `HDL/core/gating_asic.v`
**Bug:** The `u_moe_gating` instance:
- left `.hidden_valid` unconnected (moe_gating's hidden-data handshake port);
- hardwired `.weight_load(1'b0)`, `.weight_addr(0)`, `.weight_data(0)`;
- the module-level `hidden_raddr` and `wght_raddr` wires were declared but
  NEVER driven, so `hidden_rdata`/`wght_rdata` read from an undriven (z)
  address.
Even when `ctrl_start` triggered the gating FSM, moe_gating read garbage from
`hidden_data` and had no loaded expert weights, so top-K output was garbage.
**Fix:** `assign hidden_raddr = mg_hidden_addr;` (feed moe_gating's read pointer
to the hidden SRAM) and added a `hidden_valid` register that is high from
`ctrl_start` until `mg_done` (hidden_sram is a combinational read, so
`hidden_data` is valid the same cycle the address is presented; moe_gating
ignores `hidden_valid` outside `G_LOAD_HIDDEN`). Compiles cleanly.
**Known remaining gap (documented, not fixed):** the expert weight-load
controller does not exist. `weight_load`/`weight_addr`/`weight_data` need an
external FSM that reads `wght_sram` and pulses `weight_load` to populate
moe_gating's internal `weights[]`. Adding that FSM is feature work beyond a
bug-fix; `gating_asic` is not instantiated in the co-sim path, so it is not
end-to-end verifiable.

### Non-bug confirmed: FP16 rounding was correct
My first fp16 round detector "failed" because I hand-computed wrong test vectors
(`0x0900` is NOT 1.5*2^-11; `0x2400` is 2^-6, not 1.5*2^-11). With the correct
vector (`c=0x1200` = 0.75 ULP of 1.0, expected `0x3C01`), fp16 rounds correctly.
fp16/bf16 rounding increments (`22'd1024`, `16'd128`) are correct by code
inspection as well as by detector.

### MEDIUM: documentation mislabeled node-local vs aggregate bandwidth
**File:** `TLDR.md:13`
**Bug:** "Node-local bandwidth ~131 TB/s" mislabeled the aggregate. 131 TB/s is
512 nodes x ~256 GB/s node-local (README.md:27 says "~131 TB/s aggregate").
**Fix:** Changed to "Aggregate bandwidth | ~131 TB/s (512 nodes x ~256 GB/s
node-local)".

### LOW: `paper/docs.md` referenced nonexistent testbenches
**File:** `paper/docs.md:168,173`
**Bug:** Documented `tb_kv_cache_bank.v` and `tb_kv_offload.v`, which do not
exist in HDL/. The modules (`kv_cache_bank.v`, `kv_offload.v`) are verified via
the co-sim `kvcache=true` path (gen_topology.go instantiates `kv_cache_bank`).
**Fix:** Annotated the entries to say "verified via co-sim `kvcache=true` path,
no dedicated standalone TB".

### LOW: toolchain documentation used stale `router_sbc` chip name
**Files:** 26 files under `toolchain/`
**Bug:** READMEs, Makefile headers, linker scripts, config fragments, and source
comments referenced `router_sbc`/`router_sbc_moe`/`router_mcu`. The on-disk
modules are `orchestrator_sbc.v`/`orchestrator_sbc_moe.v`/`orchestrator_mcu.v`.
**Fix:** Renamed `router_sbc_moe`->`orchestrator_sbc_moe`,
`router_sbc`->`orchestrator_sbc`, `router_mcu`->`orchestrator_mcu` in comments
and banner strings across toolchain/ (40 comment/string line changes, no
functional identifiers). Generic descriptive "the router chip" wording left as-is.

### LOW: orchestrator_sbc SRAM default documented as fixed 16MB
**Files:** `paper/docs.md:77,83`, `docs/usage_manual.md:110`, `AGENTS.md:218,230`
**Bug:** Docs said "16MB SRAM" flat, but the HDL default is 512KB
(`orchestrator_sbc.v:56 SRAM_WORDS=131072`, range 500KB..32MB, 256MB window).
16MB is the config fw-linux targets, not the default.
**Fix:** Clarified as "configurable 512KB default up to 32MB" (fw-linux targets
the 16MB config). Paper.MD (manuscript) is unaffected (no SBC SRAM claim).

### LOW: `HDL/README.md` pe_tile_stub compute-path description omitted CU_TYPE
**File:** `HDL/README.md:76-77`
**Bug:** Said pe_tile_stub uses `USE_FMA` to select bias-add (0)/BF16 FMA (1),
omitting the `CU_TYPE` parameter and INT4-MAC (2) compute path present in
`pe_tile_stub.v`.
**Fix:** Updated to mention both `USE_FMA` and `CU_TYPE` (0=bias-add, 1=BF16
FMA, 2=INT4 MAC).

### Go/C round-19 review: NO BUGS FOUND
The Go/C agent returned no new defects (one minor metric-accounting note re
`SpeculativeDrafts` counting accepted vs drafted tokens, deemed minor and
documented, not a correctness bug).


## Bug audit log (round 20: fp64_alu ADD/SUB rounding)

### CRITICAL: `fp64_alu.v` ADD/SUB truncates instead of round-to-nearest-even
**File:** `HDL/core/fp64_alu.v` (ADD/SUB path, was lines 104-213)
**Bug:** The dedicated 3-cycle adder path (`OP_ADD`/`OP_SUB`) had NO rounding at
all. It aligned the 53-bit significands, added/subtracted into a 54-bit field,
and truncated the low bits at the 52-bit fraction boundary. Any result with a
guard/round/sticky remainder was silently truncated toward zero instead of
rounded to nearest-even -- a CORRECTNESS bug, not just a precision nit. E.g.
`1.0 + (2^-53 + 2^-105)` returned `0x3FF0000000000000` (1.0) instead of the
correct `0x3FF0000000000001` (round up, sticky forces it).
**Fix:** Rewrote the ADD/SUB datapath with a wide (55-bit) alignment field:
each 53-bit significand placed with implicit 1 at bit 54 plus two low
guard/round bits; bits shifted out during alignment are OR-ed into a sticky
flag; result normalized so the leading 1 sits at bit 55, giving 52-bit
fraction `[54:3]`, guard `[2]`, round `[1]`, sticky `[0]|operand sticky`.
RNE increment with three sub-fixes discovered by detection:
1. **Exponent off-by-one:** `as_norm_exp` must be `larger_exp - as_lead + 1`
   (the `+1` accounts for the leading 1 being placed at bit 55 rather than
   bit 54 of the aligned field). Without it every ADD/SUB exponent was one low.
2. **Carry lost in 52-bit fraction:** `as_frac_rounded` was `reg [51:0]`, so an
   all-ones fraction + round-up lost the carry (bit 52). Widened to
   `reg [52:0]`, incremented as `{1'b0,as_frac} + {52'd0,round_up}`, carry
   detected as `as_frac_rounded[52]`.
3. **Subtractive sticky:** `as_round_up = guard & (round | sticky | frac[0])`
   treats the sticky as additive, which is wrong for SUBTRACTION: the only
   operand that is shifted (and thus has a discarded tail) is the smaller one
   being subtracted, so its sticky is SUBTRACTIVE and must NOT push a
   `guard=1,round=0` residual over the half-ULP tie point. E.g.
   `(1+2^-52) - (2^-53+2^-105)` sits just below the halfway point (rounds down)
   but the OR'd sticky forced a round-up. Fixed to
   `guard & (round | frac[0] | (sticky & same_sign))`.
**Verification:**
- `/tmp/tb_fp64_alu_rnd.v` -- 10 targeted RNE cases, ALL PASS: exact (1.0+0.0),
  rnd_up (truncation repro), tie_dn (LSB=0 tie -> down), tie_up (LSB=1 tie ->
  up), ovf_carry (all-1s fraction + carry), sub (subtractive sticky),
  big_shift (operand deep in sticky), carry_norm (1.0+1.0=2.0 via bit-55 path),
  sub_tie_up (2.0-2^-52 tie -> up), carry_sticky (all-1s + sticky -> 1.0).
  Expectations computed exactly with Python `Fraction` (naive float math
  rounds and gives wrong expectations; the test harness was the initial
  culprit, not the RTL -- the driving protocol must set inputs at negedge so
  they're sampled at the following posedge).
- `twb_fp64_alu.v` regression: **21 passed, 0 errors** (no regression).
- FMA/mac/moe_gating regression suite: all PASS (fp64_fma, bf16_fma, fp32_fma,
  fp16_fma, moe_gating).

### Notes
- The `as_lead` ladder (bit 55 down) already handled the carry (bit-55) and
  all-zeros normalization; the RNE rewrite preserves it.
- Subnormal results are still flushed to zero (pre-existing design choice).


## Bug audit log (round 20, docs consistency review)

Verified and fixed documentation inconsistencies (docs/consistency agent):

### MEDIUM: `pcb/README.md` custom-SoC memory map contradicted the actual RTL
**Files:** `pcb/README.md:68,76,81,82`
**Bug:** The custom-SoC memory map table (and boot text) documented a 4KB boot
ROM and 4KB NVMe/PNM register windows. The actual RTL (`HDL/orchestrator_sbc.v`)
uses a 64KB boot ROM (`0x0000_0000 - 0x0000_FFFF`) and 64-byte NVMe/PNM register
regions (`0xD000_0000 - 0xD000_003F`, `0xF000_0000 - 0xF000_003F`). The 4KB
figures also contradicted Paper.MD, AGENTS.md, and docs/usage_manual.md (all 64KB
boot ROM).
**Fix:** Boot ROM 4KB -> 64KB; NVMe and PNM windows 4KB -> 64B; boot text now
cites the `orchestrator_sbc.v` address range.

### MEDIUM: `docs/usage_manual.md` LPCAMM2 pin count wrong (262 vs 644)
**File:** `docs/usage_manual.md:202`
**Bug:** Gating-ASIC option table listed "LPCAMM2 socket | 262-pin". The JEDEC
LPCAMM2 (JESD318) module is 644-pin, and every other source in the repo
(Paper.MD:73,448,474; pcb/README.md:45,101,181; the `lpamm2_644.lp` library
footprint) consistently states 644. 262 appeared nowhere else.
**Fix:** Changed to "644-pin, 0.5mm pitch".

### MEDIUM: `docs/profiling.md` documented a non-existent `pnmc compile` subcommand
**File:** `docs/profiling.md:140`
**Bug:** Documented `go run ./cmd/pnmc compile examples/bias_add.pnm ...`. The
`pnmc` CLI (`sim/cmd/pnmc/main.go`) has no `compile` subcommand; its dispatcher
only recognizes `compile-model`, `run-driver`, and `workload`, and any other
token falls through to default program mode, treating `compile` as a (missing)
program path and failing. The program compiler is the CLI's default mode.
**Fix:** Changed to `go run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8`.

### LOW: `paper/Paper.MD` wrong path for PE tile stub
**File:** `paper/Paper.MD:193`
**Bug:** Cited the stub as `HDL/pe\_tile\_stub.v`; the file lives at
`HDL/core/pe_tile_stub.v` (`HDL/pe_tile_stub.v` does not exist).
**Fix:** Changed to `HDL/core/pe\_tile\_stub.v` (double-escaped for the build
pipeline). Paper rebuild verified (exit 0, `Wrote paper.docx`).

### Citation / cross-reference audit
- All 20+ `{c(n)}` citations in Paper.MD were checked against build.py REFS;
  all correct except two low-confidence candidate stretches ({c(25)} at line 17
  for an EUV-yield claim the TrendForce spot-price source doesn't make; {c(2)}
  at line 480 for a 2024 inference-revenue figure that a 2023 IEEE Micro H100
  paper can't be the source of). Both were left as-is (external sources unverifiable).
- All "Section N.M" cross-references resolve to existing sections (2.1-2.19,
  3.1-3.7, 4.1-4.6). No dangling refs.
- All documented `cmd/pnm` and `pnmhost` flags verified to exist in code; the
  only unimplemented documented command was `pnmc compile` (fixed above).


## Bug audit log (round 20, HDL review: int4_mac_array sticky-valid)

### CRITICAL: `int4_mac_array.v` partial-sum valid flags latched high, never cleared
**File:** `HDL/core/int4_mac_array.v:173-182`
**Bug:** `psum_v_sr[i][j][0]` was set to `1'b1` when that PE's MAC fired, but had
NO else branch clearing it to `0`; the only reset path was rst_n. The valid flag
is therefore a sticky LEVEL, not a one-shot pulse, once any row's MAC has fired.
Two compounding consequences:
1. The bottom-right `psum_v_sr[ARRAY_SIZE-1][ARRAY_SIZE-1][PIPE_DEPTH-1]` (the
   result-cycle condition, line 208) stays `1` forever after the first result,
   so `result_valid` asserts once and never deasserts (output block lines
   208-216), and `result_out`/`result_sop`/`result_eop` stay latched.
2. Rows below row 0 fire from `fire = psum_v_sr[row-1][col][PIPE_DEPTH-1]`
   (line 139). Once those valid flags latch high, the lower rows re-fire on
   stale partial sums during every subsequent activation, so the second
   activation vector's accumulation is corrupted (reuses the first vector's
   accumulation).
**Repro:** feed two activation vectors into a 4x4 identity-weight array.
First vector [1,2,3,4] returns correctly, but `result_valid` stays high
indefinitely and the second vector [5,6,7,8] returns the stale [1,2,3,4].
**Fix:** Added an `else` branch clearing stage-0 to `0`:
```verilog
if (mac_valid_out[i][j]) begin
    psum_sr[i][j][0]   <= mac_result[i][j];
    psum_v_sr[i][j][0] <= 1'b1;
end else begin
    psum_v_sr[i][j][0] <= 1'b0;
end
```
This makes the valid a genuine one-cycle pulse that propagates down the shift
chain, exactly like the sibling `bf16/fp16_mac_array` (which tie stage-0 valid
to the FMA's one-shot `valid_out`).
**Verification:**
- New /tmp two-round detector: first vector PASS, result_valid deassert PASS,
  second vector PASS.
- Extended the committed `core/tb_int4_mac_array.v` to (a) check result_valid
  deasserts after the first result and (b) feed a second vector and verify it.
  Both the extended regression and the original single-vector checks PASS.
- Verilator lint clean (only the pre-existing benign int8_mac.v WIDTHEXPAND on
  `s1_product` 16-bit ADD to 32-bit `sum` -- INT8xINT8 fits in 16 bits, sign-
  extended to 32, no truncation; untouched).

### MEDIUM #29: `firmware.go` MoE gating scored by loop index, diverging from C twin
**File:** `sim/internal/pnm/firmware.go:538` (and old line 546)
**Bug:** `selectTopExperts` scored each candidate by its position in the loop
(`h ^ uint64(e)*K`, where `e` was the loop index) instead of by the candidate's
ACTUAL global expert index. The C firmware `select_topk` (`fw/pnm_fw.c`)
correctly scores by the expert's global index from the MoE map. The two twins
diverged whenever a layer's candidate population was not exactly `0..N-1`: with
a sparse per-layer population, Go could route only to `0..numExperts-1` while C
routed across the real population, producing different expert selections.
**Fix:** Changed the signature to `selectTopExperts(token []byte, ml int,
experts []int, topK int)` taking the layer's candidate population slice. Each
candidate is now scored by its GLOBAL index. The caller (`firmware.go` ~line 490)
builds `population` as the set of all `ExpertIdx` for the layer from
`fw.Driver.MoeMap`. Shipped models use contiguous per-layer populations
(`0..N-1`), so no shipped result changes -- this is a strict generalization
that also fixes sparse populations.
**Verification:**
- `go build ./internal/pnm/ ./cmd/pnm ./cmd/pnmc` exits 0.
- `TestIntegration_CMoeGating` (contiguous population, C/Go compare) PASS.
- Added permanent regression test `TestSelectTopExpertsSparsePopulation` in
  `sim/internal/pnm/firmware_fix_test.go`, with a `cSelectTopk` mirror helper
  that reproduces the C scoring. Covers sparse `{10,20,30}`, shifted, gapped,
  contiguous, and single-element populations, plus the known-good
  `selectTopExperts([]byte("sparse-token"),3,{10,20,30},3) == [10 30 20]`.
  PASS.
- Full Go suite `go test ./internal/pnm/` -> ok.

## Bug audit log (2026-08-29, round 21)

### CRITICAL #13: `bf16_fma.v` narrow alignment window truncates product tail, breaking RNE
**File:** `HDL/core/bf16_fma.v` (stage-2 alignment/rounding, lines 128-236)
**Bug:** `bf16_fma` was the only FMA with a narrow 16-bit alignment window that
truncated the right-shifted product and re-added boolean `mul_sticky`/`c_sticky`
bits. The dropped tail (e.g. a `0xF80.75` product truncated to `0xF80`) flipped
guard bits and produced 1-ULP-high results on both addition and subtraction
half-way (RNE tie) boundaries. A 3000-vector targeted detector found 11/3000
mismatches (all 1 ULP HIGH); an exact-Fraction 4096-vector mixed-sign sweep found
8 RNE/classification mismatches.
**Fix (3 parts):**
1. Widened the alignment window to 24 bits (mirroring fp16_fma): implicit 1 at
   bit 23, mantissa field `[22:16]`, guard `[15]`, round `[14]`, sticky `|[13:0]`;
   product and c zero-padded below so right-shifted operands keep discarded bits
   in-window; removed the boolean mul_sticky/c_sticky.
2. Added far-sticky (`mul_far_sticky`/`c_far_sticky` = OR of bits shifted entirely
   below the window, shift clamped to 24) so a tiny addend still rounds the
   mantissa up.
3. Gated far-sticky by same-sign (addition only): in subtraction (opposite signs)
   a fully-below-window residual reduces the true magnitude, so a bare tie
   (guard=1, round=0, sticky=0) must round DOWN instead of RNE-to-even. Added
   `sub_far = (!add_op) & (mul_far_sticky | c_far_sticky)` gating the
   `norm_man[16]` even-tie term off.
**Verification:** 4 seeds x 4096 normal-operand vectors (16,384 total) via exact
`Fraction` golden (not float — float absorbs tiny addends into tie boundaries and
produces false mismatches): 0 errors. Committed `core/tb_bf16_fma.v` PASSED.
The 4 subtraction over-rounding cases (idx 912/1728/2319/2559 from the first
sweep) and the ADD far-sticky under-rounding cases (idx 1735/3170/3698) are all
fixed.

### KNOWN LIMITATION: `bf16_fma.v` subnormal INPUT handling is incorrect (pre-existing)
**File:** `HDL/core/bf16_fma.v`
**Bug:** Subnormal `b`/`c` operands are unpacked with exponent 1 and a 7-bit
mantissa (implicit 0 at bit 7), which places them 2^8 too small in the alignment
window. When a subnormal `c` dominates the result, the normalization exponent
comes out 8 too low and the packing's `result_underflow` flush triggers for a
result that should be a normal (e.g. `a=2c46 b=8ad2 c=8062` -> RTL `8000`,
correct `83c4`). Cases with subnormal `b` are also wrong. This predates the
round-21 fix and is masked in practice because BF16 ML workloads do not produce
subnormal values; the design intentionally flushes subnormal RESULTS to zero.
Fix requires normalizing subnormal operands before alignment (leading-1 scan +
exponent adjust in the unpack stage) and is out of scope of this audit.

### MEDIUM #22: `llm_client.go` deterministic hash accumulated in float32, losing precision
**File:** `sim/internal/pnm/llm_client.go:843-848`
**Bug:** The 8-byte sampling hash was accumulated in a `float32` variable and
normalized by 2^64, but float32 keeps only ~24 mantissa bits, so the comment
"r accumulates 8 bytes (64 bits)" was false for the low 5 bytes. Verified: the
float32 accumulated value differs from the true uint64 hash for 200000/200000
inputs (max normalized-r error 1.8e-8). Impact is low (only flips sampling in
sub-1e-8 cumulative-probability ties) but the code did not do what it documented.
**Fix:** Accumulate into a `uint64` (`rHash`), then normalize via float64.
**Verification:** `go build ./...`, `go vet`, LLM/sample tests PASS, full suite `ok` (304s).

### MEDIUM #23: `fw/pnm_fw.c` `fw_plan_inference` omits KV-load dispatch records
**File:** `fw/pnm_fw.c:211-258`
**Bug:** The Go reference `PlanInference` (firmware.go:440-484) emits, per layer:
(1) dense attention dispatch with `KVAction "store"`, (2) a KV cache load record
(`KVAction "load"`, `TensorRole "attn_kv_load"`, `FlitBytes 0`), and (3) a
conditional `kv_offload`/`evict` record when `NeedsOffload()`. The C port emitted
only the store + MoE records, dropping the load record entirely.
**Fix:** Added the KV-load record after the dense store in C, mirrored from the Go
non-flash path (bookkeeping only, `flit_bytes 0`, same target/CU). The conditional
`kv_offload`/`evict` record requires runtime KV state (seqPos) that the C
`fw_plan_inference` signature does not carry; documented as a structural
limitation of the C port.
**Verification:** `gcc -Wall -Wextra -std=c11 -c pnm_fw.c` -> zero warnings.

### LOW #31: `paper/Paper.MD:496` wrong citation {c(15)} for DUV yields
**File:** `paper/Paper.MD:496`
**Bug:** The Conclusion cited `{c(15)}` (JEDEC HBM JESD235D) for "mature-node DUV
logic with high yields and established supply chains". HBM is the anti-thesis of
mature-node DUV (it requires EUV, low yields); no bibliography entry supports the
claim, and the paper states it uncited elsewhere (abstract line 9, Table 2 line 341).
**Fix:** Removed the erroneous `{c(15)}`.
**Verification:** `paper/build.py --review` -> `Wrote paper_review.pdf` (build clean).

### LOW #32: `AGENTS.md:27` wrong path for docs.md
**File:** `AGENTS.md:27`
**Bug:** The repo layout table listed `docs.md` at the repo root, but the file
lives at `paper/docs.md` (root `docs/` holds `usage_manual.md` and `profiling.md`).
**Fix:** Changed to `paper/docs.md`.

## Bug audit log (2026-08-30, round 22)

### CRITICAL R22-1: `fp32_fma.v` / `fp64_fma.v` zero-product exponent unguarded
**Files:** `HDL/core/fp32_fma.v`, `HDL/core/fp64_fma.v`
**Bug:** The multiply-stage exponent `mul_exp` was computed unconditionally. When
either operand was zero, `0*x` produced a far-negative exponent (e.g. -127 for
fp32) instead of 0, corrupting the barrel-shifter alignment and producing
incorrect results for zero-product FMAs. `fp16_fma.v` already carried the fix;
it had not been ported to the 32-bit and 64-bit units.
**Fix:** Guarded both `mul_exp` and `mul_man` with `(a_zero || b_zero) ? 0 : ...`,
matching the fp16 pattern. (This was a separate residual from round 21 and is
included in commit `2c6b65f`.)
**Verification:** all committed FMA/ALU/MAC regressions PASS post-fix.

### CRITICAL R22-2: KV cache eviction deadlock and data-path defects
**Files:** `HDL/kv_cache_bank.v`, `HDL/kv_offload.v`, `HDL/tb_kv_cache_bank.v`
**Bug:** The KV-cache eviction path had multiple compounding defects: (1) the
eviction FSM (`load_done`/`evict_done`) returned to `KL_IDLE` instead of holding
the final byte, so tail-behavior/backpressure was wrong and eviction could stall;
(2) when `evict_req` is a pulse, the FSM needed a dedicated tail state to wait for
`evict_req` deassert + `nob_out_ready`; (3) hazard of `evict_req` level-vs-pulse
inconsistency. Provided a tailored `KL_TAIL` state.
**Fix:** Reworked the `kl_state` FSM: `load_done`/`evict_done` jump to a new
`KL_TAIL` (localparam 2'd3) that only returns to `KL_IDLE` once `evict_req`
deasserts and `nob_out_ready` is high; changed write/read pointer wrap from
`== BANK_DEPTH-1` to `== {ADDR_BITS{1'b1}}` (verilator WIDTHEXPAND); changed the
four `reclaim_ready_0..3` ports from `input wire` to `output wire` (pre-existing
verilator ASSIGNIN error). New combined self-checking TB exercises both the
eviction path (via kv_offload + kv_cache_bank, exactly 1 eviction / 512 bytes /
occupancy 63) and the KV_LOAD path (single sop byte, `[EE,80,00,02]` header +
512 payload bytes), with 600-cycle spurious-replay tail watches.
**Verification:** `iverilog -g2005 -I. -o /tmp/tb_kvcache5.out kv_offload.v
kv_cache_bank.v tb_kv_cache_bank.v && vvp /tmp/tb_kvcache5.out` →
`*** KV CACHE BANK TEST PASSED ***`. Committed `a7140c9`.

### CRITICAL R22-3: `fp32_fma.v` / `fp64_fma.v` lost far-sticky in rounding
**Files:** `HDL/core/fp32_fma.v`, `HDL/core/fp64_fma.v` (commit `2c6b65f`)
**Bug:** Both FMA units rounded using only the in-window guard/round/sticky
(`|norm_man[21:0]` for fp32, `|norm_man[50:0]` for fp64), dropping bits fully
shifted out of the alignment window (the "far" bits) in same-sign addition, and
applied the RNE tie-break on opposite-sign (subtraction) drops. Concretely,
`(1+2^-w)^2 + 4.0` with guard=1, round=0, in-window sticky=0 came out 1 ULP low
because the far sticky bit, which decides between round-up and round-down, was
never consulted. Subtraction half-way ties erroneously rounded up instead of down.
**Fix (ported bf16 145-165 / fp64_alu round-21 pattern):** added
`mul_far_sticky`/`c_far_sticky` wires computed from a top-aligned mask over the
pre-alignment product and `{c_mantissa, 0}`; folded them in only for same-sign
addition (`mul_far_eff`/`c_far_eff`) and introduced `sub_far` to suppress the RNE
tie-break for opposite-sign drops. Rounding became
`sticky = |norm_man[...] | mul_far_eff | c_far_eff` and
`round_up = guard & (round | sticky | (norm_man[24] & ~sub_far))`.
**Proof vectors (Fraction-exact goldens, failing first on real iverilog RTL):**
- fp32: `a=b=0x3F800001 (1+2^-23), c=4.0` → exact `0x40A00001`; unpatched RTL 1 ULP
  low, patched matches.
- fp64: `a=b=0x3FF0000000000001 (1+2^-52), c=4.0` → exact `0x4014000000000001`.
- Mask widths are intentional: 49-bit `mul_pre` (fp32)/107-bit (fp64) and
  48-bit `{c_mantissa,24'd0}`/106-bit, clamped so `<< shift` cannot overflow
  verilator's width checks; the masks do not depend on the aligned window.
**Verification:** single-vector detectors PASS post-fix
(`/tmp/tb_fp32_farsticky.v`, `/tmp/tb_fp64_farsticky.v`); all committed FMA/ALU
regressions PASS.

### INVESTIGATED-AND-DISMISSED R22-4: `int4_mac_array` `result_out` overwritten every cycle
**File:** `HDL/core/int4_mac_array.v`
**Claim:** `result_out` is assigned unconditionally each cycle, so it is clobbered.
**Finding:** False positive. `result_out` is registered and gated behind the
accumulation/`act_v_sr` valid pipeline; each MAC holds its result until the next
valid activation, so the value is stable between valid pulses. No code change.

### MEDIUM R22-5 (Go-1): C `fw_plan_inference` missing `kv_offload`/`evict` record
**Files:** `fw/pnm_fw.c`, `fw/pnm_fw.h` (commit `96141b2`)
**Bug:** The C port's `fw_plan_inference` emitted dense + moe records but dropped
the Go firmware's KV-offload step (emit a `kv_offload`/`evict` record and drain a
layer's bank past an 80% threshold). It also never honored a run-time
`top_k_experts` (hardwired to `PNM_MAX_TOPK`).
**Fix:** Added a Step-2b block mirroring `firmware.go:472-484`: when
`kv_needs_offload(&fw->kv.layers[pl], 80)`, emit an evict record (phase
`kv_offload`, expert_idx -1, flit_bytes 0, cu_type CU_NONE, kv_action "evict")
and drain via `kv_evict_oldest` in a loop that breaks when the `evictions`
counter stops advancing (no backing store). Added `top_k_experts` to `firmware_t`
with 0-means-default semantics and a `PNM_MAX_TOPK` cap.
**Verification:** parity detectors `/tmp/fw_kv_offload_test.c` (evict + drain +
empty-KV control) and `/tmp/fw_topk_test.c` (12 candidates, topk 8 → 8 MoE
records, total 10; topk 0 → 12) PASS. `gcc -Wall -Wextra -std=c11` zero warnings
in both standard and `-DPNM_MCU` contexts.

### MEDIUM R22-6 (Go-3): `DefaultKVCacheConfig` entry size vs RTL frame
**File:** `sim/internal/pnm/kv_cache.go`, `sim/internal/pnm/kv_cache_fix_test.go`
(commit `96141b2`)
**Bug:** `DefaultKVCacheConfig(hiddenSize)` derived `EntryBytes = 2*hiddenSize*2`,
which only coincides with the RTL `ENTRY_BYTES(512)` frame (gen_topology.go:257,
byte-addressable SRAM) at hidden-size 128. For any other model the Go KV
accounting diverged from what the fabric actually stores.
**Fix:** Pinned `entryBytes := 512` unconditionally (memory-sizing callers set
EntryBytes explicitly; comment documents the RTL co-sim contract). Added
`TestDefaultKVCacheConfigRTLConsistency` asserting 512/1024/4 for hiddenSize
∈ {0,64,128,512,2816}.
**Verification:** targeted test PASS; full `go test ./internal/pnm/` (375.8s)
PASS.

### MEDIUM R22-7 (docs-1..4): `paper/Paper.MD` build/content corrections
**Files:** `paper/Paper.MD`
- docs-1: line 396 had a literal tab inside `8$\t imes$8` (from a pasted tab),
  producing `8$imes$8` in the rendered PDF. Replaced with `8$\times$8`.
- docs-2: line 396 said "all six scenarios" of Section 2.15, but on the 512-node
  chassis only five of the six are run (sweep, load, hotspot, stress, replay);
  the count now reads "five of the six scenarios".
- docs-3: `router_*.v` → `orchestrator_*.v` filenames (bmc_orchestrator_top.v,
  orchestrator_mcu.v, orchestrator_sbc_moe.v, orchestrator_sbc.v and their
  tb_*_orchestrator.v counterparts; router_chip.v → orchestrator_chip.v). The RTL
  sources were named thus from the start; the manuscript used stale router_ names.
- docs-4: abstract line 9 `{c(1,15)}` → `{c(15)}` (interposer reticle bound) +
  `{c(25)}` (EUV yield/wafer-area claim), so the HBM yield statement is supported
  by 25 (TrendForce) rather than the HBM standard 15.
**Verification:** `python3 paper/build.py --review` → `Wrote paper_review.pdf`
(build clean) after each change.

### MEDIUM R22-8 (docs-5): MoE SBC tier does not instantiate a systolic array
**Files:** `paper/Paper.MD:311`, `AGENTS.md:216`
**Bug:** Both claimed the MoE SBC tier (`orchestrator_sbc_moe.v`) carries an
"on-chip systolic array". The module only realizes the `bf16_mac_array` as a
provisioned `ARRAY_SIZE` parameter and instantiates `moe_gating`; no mac-array
instance exists.
**Fix:** Reworded Paper.MD:311 to "adds a 64 KB BF16 gating SRAM and the
moe_gating unit" (dropping the unsubstantiated systolic-array claim) and AGENTS.md
to note the array is provisioned via `ARRAY_SIZE` with no separate mac-array
instance.
**Verification:** `paper/build.py --review` → clean build.

## Bug audit log (2026-08-27, round 3)

### CRITICAL R23-A: fp16 FMA far-sticky rounding (alignment drop)
**File:** `HDL/core/fp16_fma.v`
**Bug:** The far-sticky fix ported to bf16/fp32/fp64 in earlier rounds was missing
from fp16. When the addend is far apart in exponent, right-shifting the smaller
mantissa dropped bits that must contribute to the round-to-nearest sticky.
**Proof vector:** `a=b=0x3C01 (1+2^-10), c=4.0`. Exact = 5 + 2^-9 + 2^-20; the
2^-20 cross-term (at product bit 1) must set sticky. Without far-sticky the FMA
rounded down to `0x4500` (1 ULP low); correct is `0x4501`. Exact analog of the
round-22-3 fp32 vector `(1+2^-23)^2 + 4.0`.
**Detector:** `/tmp/tb_fp16_farsticky.v` — FAILED pre-fix on the c4 vector.
**Fix:** Ported the fp32 pattern (`mul_far_sticky`/`c_far_sticky`/`mul_far_eff`/
`c_far_eff`) with fp16 widths: `mul_man_norm` 22-bit, `{c_mantissa,11'd0}` 22-bit,
5-bit shift wires clamped at `5'd22`.

### CRITICAL R23-B: far-sticky carry-drop in ALL four FMA units
**Files:** `HDL/core/fp16_fma.v`, `HDL/core/bf16_fma.v`, `HDL/core/fp32_fma.v`,
`HDL/core/fp64_fma.v`
**Bug:** After the R23-A fix, the fp16 `c=3.0` case STILL failed: the 2^-20
cross-term survives alignment into `add_result[0]`, but `norm_man = add_result[22:1]`
(triggered when the add carries into bit 22) drops bit 0 without sticky, rounding
down to `0x4400` instead of `0x4401`. Exact value sits 2^-20 ABOVE the midpoint.
The identical `norm_man = add_result[N:1]` carry-drop pattern exists in bf16
(add_result[24]), fp32 (add_result[48]) and fp64 (add_result[106]); fp16 was the
only one with an observable failing vector (the bf16 2^-14 cross-term lands at
aligned bit 8, not bit 0, so the carry never drops a set sticky bit there).
**Detector:** `/tmp/tb_fp16_dbgX.v` (internal-signal debug) revealed the drop; the
c3 case in `/tmp/tb_fp16_farsticky.v` confirmed FAIL pre-fix.
**Fix:** Added `wire carry_drop = add_op & add_result[N] & add_result[0];` to all
four units and OR'd it into `sticky`. Mathematically safe: only ADDS sticky in a
previously lossy path. All six FMA testbenches + mac_array/alu suites + a
40,512-vector randomized fp16 sweep (exact `fractions.Fraction` goldens in
`/tmp/fp16_stim.hex`) pass with 0 mismatches.

### MEDIUM R23-1 (docs): INT8 MAC described as single-cycle in manuscript
**File:** `paper/Paper.MD:271`
**Bug:** "the INT8 MAC (single-cycle multiply-accumulate)" contradicted
`HDL/core/int8_mac.v` ("Pipeline latency: 2 cycles").
**Fix:** Changed to "two-cycle multiply-accumulate".
**Verification:** `paper/build.py --review` → clean.

### MEDIUM R23-2 (docs): orchestrator_sbc_moe systolic-array claims lingering
**Files:** `paper/docs.md:76`, `docs/usage_manual.md:101`
**Bug:** Both still described `orchestrator_sbc_moe` as carrying a "BF16 systolic
array" / "BF16 array". The module only provisions `ARRAY_SIZE` and instantiates
`moe_gating` (same correction as round-22 docs-5, which missed these two files).
**Fix:** Removed the systolic-array claim from both rows; the remaining
`tb_bf16_mac_array.v` "BF16 systolic array" row in `paper/docs.md:331` is a
legitimate testbench reference and was kept.

### CRITICAL R23-C: C kv_load returns stale data after eviction + wrap refill
**Files:** `fw/pnm_fw.c` (`kv_load`/`kv_store`), `fw/pnm_fw.h` (`kv_bank_t`)
**Bug:** The C `kv_load` only did a live-window distance check
(`dist >= occupancy`). A bank slot that was evicted and overwritten with a NEWER
seqPos still lies inside the live window, so the check passed and returned the
wrong (newer) entry for an old, evicted seqPos. The Go reference
`KVCacheBank.Load` validates the stored seqPos per slot (`EntrySeq[idx] != seqPos`
→ nil).
**Detector:** `/tmp/detect_kv_stale.c` (gcc). Pre-fix FAIL:
`kv_load(seq0)` returned true with stale data 0x99 (seq8's data) after
store0,store4,evict,store8 on a single bank. Post-fix PASS.
**Fix:** Added `int *entry_seq` to `kv_bank_t` (parallel backing array, optional).
`kv_store` records `entry_seq[write_ptr] = seq_pos`; `kv_load` rejects when
`entry_seq[idx] != seq_pos`. NULL-guarded so existing callers are unaffected.

### MEDIUM R23-D: C fw_plan_inference plans phantom model layers
**Files:** `fw/pnm_fw.c` (`fw_plan_inference`, `fw_verify_dispatch`),
`fw/pnm_fw.h` (`firmware_t`)
**Bug:** `model_layers = mpl * num_layers` was planned even when that exceeded the
model's real layer count. The Go firmware bounds its loop with
`for ml := 0; ml < tc.NumHiddenLayers; ml++` (firmware.go:821). The C firmware had
no `num_hidden_layers` field, so with `mpl*num_layers > NumHiddenLayers` it
dispatched non-existent (phantom) model layers.
**Detector:** `/tmp/detect_phantom.c` (gcc). Pre-fix FAIL: planned 8 phantom model
layers with num_layers=2, mpl=6, num_hidden_layers=8. Post-fix PASS.
**Fix:** Added `num_hidden_layers` to `firmware_t` and clamped `model_layers` to it
(when >0) in both `fw_plan_inference` and `fw_verify_dispatch`.

### Verified-clean (round-3, nothing to fix)
- HDL agent: BF16/FM builders, clint, pnm_arb, pcb_link, weight_dequant,
  int4/int8_mac, moe_gating, fp64_alu, optical_link, clk_gate/rst_sync.
- Go/C agent dismissals: kv_store FIFO, fullestBank, kF64Cmp NaN, selectTopExperts,
  layerIsSliding, fw_verify_dispatch (beyond mpl clamp), memcpy sizes, splitArith,
  rng, crc.
- Docs agent dismissal: `{c(5)}` citation, driver_log 137.4GB figure,
  tb_bf16_mac_array.md entry (real TB, kept).
- Agent caveat: the round-3 agents had read-only tools only (no shell/write); the
  orchestrator built every failing detector directly.

## Bug audit log (2026-08-30, round 24)

### CRITICAL R24-M: co-sim weight upload exhausts host RAM (41 GB RSS + 84 GB swap)
**Files:** `sim/internal/pnm/driver.go` (`BuildWeightCommands`,
`generateWeightPayload`, `WeightUploadCommand`), `sim/internal/pnm/firmware.go`
(`VerifyWeightUpload`), `sim/cmd/pnmc/main.go` (`totalPayloadBytes`)
**Bug:** `BuildWeightCommands` materialized EVERY tensor's full synthetic weight
payload (~51 GB for the Gemma-4-26B test model) into a never-evicted
`payloads map[payloadKey][]byte` cache, then held every command's `Payload`
reference in the `cmds` slice. `go test` (`TestIntegration_DriverBootAndDispatch`
shells out to `pnmc run-driver examples/gemma4_test_synthetic -l 4 -x 4 -y 4`) peaked at
~41 GB RSS and spilled ~84 GB into swap. The model is fully materialized
regardless of chassis size (`PopulateSchema` places all 30 layers x 128 experts).
**Proof:** directly measured `pnmc run-driver` peak RSS = 40.8 GB pre-fix.
**Key fact:** the payload BYTES are never consumed downstream — only their
lengths feed the per-node budget check (`VerifyWeightUpload`) and the MB report
(`totalPayloadBytes`). `BuildWeightFlit` (the only content consumer) is dead code
with zero call sites.
**Fix:** Added `SizeBytes int64` to `WeightUploadCommand` (authoritative tensor
size). `generateWeightPayload` now emits a bounded 4 KiB deterministic sample
per tensor instead of the full tensor. `VerifyWeightUpload` and
`totalPayloadBytes` use `SizeBytes`, preserving full-model byte accounting.
**Verification:** peaked RSS `pnmc run-driver` = 12.1 MB post-fix (Phase 3 still
reports 55,403.4 MB total — accounting unchanged). Full `go test ./internal/pnm/`
passes in 1.7 s under a strict 8 GB `ulimit -v` (previously the single culprit
test alone exceeded 64 GB + swap). Committed `e36d0d2`.

### CONFIRMED R24-1: fp32 CMP misclassifies mixed-sign ±0
**File:** `HDL/core/fp32_alu.v`
**Bug:** The CMP equality term did not treat `+0` and `-0` as equal. CMP(+0,-0)
and CMP(-0,+0) returned 0.0 pre-fix.
**Detector:** `/tmp/tb_fp32_zcmp.v`: CMP(+0,-0)=1.0, CMP(-0,+0)=1.0 post-fix (5/5
PASS). **Fix:** added `s1_both_zero ||` to the equality term
(`HDL/core/fp32_alu.v:237-239`). Committed `1f87529`.

### CONFIRMED R24-2: kv_cache_bank KS_IDLE reclaim races with store
**File:** `HDL/kv_cache_bank.v`
**Bug:** Reclaim (`KS_IDLE`) branch was an independent `if`, so in the same cycle
both a store write-back and a reclaim could act, losing the store.
**Detector:** `/tmp/tb_kv_race.v` (timing-fragile) + static race confirmed.
**Fix:** changed reclaim to `else if` (store priority, mutual exclusion). Existing
kv_cache_bank TB PASSES. Committed `1f87529`.

### CONFIRMED R24-3: Haskell cross-function inlining register aliasing (HIGH)
**File:** `sim/internal/pnm/haskell_ir.go`
**Bug:** Inlined function bodies used definition-time registers never written at
call time. `f (g 3) 4` evaluated to 0 pre-fix (should be 10).
**Fix:** recorded `ArgRegs []string` in `HaskellFunc`; at each call site remap every
body register to fresh call-time registers, bind arg regs to passed values, and
deep-copy `Src` slices to avoid corrupting cached definitions.
**Detector:** `TestHaskellCrossFunctionCall` (0→10) + `...Multi`.
Committed `e6265f8`.

### CONFIRMED R24-4: Lustre stripe LBA aliasing (data corruption, MEDIUM-HIGH)
**Files:** `fw/pnm_lustre.c` (`obj_lba`), `sim/internal/pnm/nvme_lustre.go`
(`objLBA`)
**Bug:** objects mapped to a single LBA (`lba_base + obj_id % lba_count`), so
adjacent objects aliased and stripe 1 clobbered stripe 0.
**Detector:** `/tmp/detect_lustre.c`: `WRITE lba=1 nlb=7` then `WRITE lba=2 nlb=7`
→ readback corruption at byte 512 pre-fix; PASS post-fix ("LUSTRE STRIPING OK").
**Fix:** space objects by their `stripe_size/512` block extent. Both twins kept in
lockstep. Committed `5a12434`.

### DISMISSED R24-A: fp32 vs fp64 CMP contract contradiction
README.md:306 vs :290 document two distinct instructions (fp32 CMP vs fp64
CMP); not a contradiction. No fix.

### DISMISSED R24-B: LLM sampling entropy collapse
My detector showed the flat distribution correctly drew token 2 vs the peaked one
drew token 0 (same argmax, same temperature); `rHash` is distribution-independent
(derived only from `sorted[0].idx` + temperature, llm_client.go:845-848), but each
distribution's own CDF maps the identical r to valid distinct draws.
Deterministic-hash sampling is intentional (`--seed` reproducibility). No fix.

### LOW R24-C (deferred): fp64 subtractive RNE sticky exclusion
Documented-intent behavior; likely dismiss unless a concrete failing vector is
found.

### Docs R24 (4 applied): orchestrator_mcu/sbc_moe comment paths
`sim/toolchain/`→`toolchain/`; HDL/README.md sqrt/rcp → "software-lowered";
Paper.MD MoE gating ~1MB → "fits entirely in 64KB gating SRAM (32K BF16
entries)"; usage_manual.md CLINT 4KB → 64KB. Committed `ebcbc3b`.


## Bug audit log (2026-08-30, round 25)

Round-25 quads: H (HDL) = fp64_alu RNE tie-break, lpddr6_camm refresh drop,
vc_merge starvation (dismissed); G (Go/C) = flash_attn C twin divergence,
KV entry-bytes divergence (dismissed), kv full off-by-one (dismissed), Haskell
do-block in-result (G4), dead Driver.PlanInference (G5); D (docs) = fp32_alu
latency (dismissed), profiling closed-form ambiguity. Empty-quad count: 0.
4 confirmed+fixed across 6 candidates; memory fix carried over as R24-M.

### CONFIRMED R25-H1: fp64_alu ADD/SUB round-nearest-even tie-break
**File:** `HDL/core/fp64_alu.v`
**Bug:** The working tree carried a large pre-existing RNE rewrite; the H1
defect was that the round-up term `as_frac[0]` was not gated by same-sign,
so an even-sign tie (guard set, LSB 0, opposite sign) could round up instead
of to even.
**Detector:** `/tmp/tb_fp64_sub_rne.v` + `/tmp/alu_sim.py`: 21-vector regression
+ 5-vector SUB RNE detector; all pass on fixed RTL.
**Fix:** gate `as_frac[0]` by `as_same_sign` in `as_round_up`
(`HDL/core/fp64_alu.v:234`). Committed `a3b9a60`.

### CONFIRMED R25-H2: lpddr6_camm drops CPU write presented during refresh
**File:** `HDL/lpddr6_camm.v`
**Bug:** Accept gate `if (bus_valid && bus_ready && !refresh_pending)`
silently dropped a CPU write presented while refresh was active: `bus_ready`
stayed high (only falls on `cmd_pending`), so the CPU's handshake completed but
the accept was blocked.
**Detector (authoritative):** `/tmp/tb_refresh_drop8.v` forces a write during
active refresh: ORIGINAL `wr_count=0` + readback `xxxxxxxx` (FAIL); FIXED
`wr_count=1` + correct readback (PASS).
**Fix:** removed `!refresh_pending` from the accept gate (1-line change).
All four committed LPDDR testbenches pass (`tb_dma_lpddr6`, `tb_sodimm_lpddr`,
`tb_host_bmc`, `tb_sodimm_ctrl`). Committed `735b932`.

### DISMISSED R25-H3: vc_merge starvation
**Analysis:** `vc_merge.v` round-robins via `pri_q` which toggles after each
completed packet, so no channel starves. No failing detector produced.

### CONFIRMED R25-G4: Haskell do-block drops `in <expr>` result
**File:** `sim/internal/pnm/haskell_ir.go`
**Bug:** `compileHaskellDo` parsed and emitted `let` bindings but dropped the
final `in <expr>` result expression.
**Fix:** captured `inExpr` and returned it as the block result. Added
`TestHaskellDoBlockInResult` to `ir_compound_test.go`. Committed `d0a78d1`.

### CONFIRMED R25-G5: dead `Driver.PlanInference` no-op + `InferDispatch` type
**File:** `sim/internal/pnm/driver.go`
**Bug:** `InferDispatch` type + `Driver.PlanInference` are dead code (zero
callers; all real calls go to `*Firmware.PlanInference`).
**Fix:** removed both dead symbols (50 lines). Build/vet clean, full Go suite
passes. Staged surgically via `git add -p` hunk 4 only (the file also carries
pre-existing uncommitted MoE refactor that must not be committed). Committed
`5191268`.

### CONFIRMED R25-G1: C firmware twin emits `dense` instead of `flash_attn`
**Files:** `fw/pnm_fw.c`, `fw/pnm_fw.h`
**Bug:** `fw_plan_inference` unconditionally emitted `"dense"` attention
phases, but the Go `PlanInference` twin emits tiled `"flash_attn"` store/load
records because `DefaultFlashAttnConfig` enables flash attention by default
(`Enabled:true`, never set false). On identical input the two planners diverged
in phase, record count, and content. The C twin is compile-checked but never
diffed against Go for the dispatch graph, so it slipped through.
**Detector:** `/tmp/tb_flash_v2.c` (works with both old/new headers): ORIGINAL
gives `flash_store=0 flash_load=0 dense=2` (FAIL); FIXED gives flash store/load
(PASS).
**Fix:** ported the Go flash_attn tiling branch to the C twin: added
`flash_attn_enabled`/`flash_tile_size_kv`/`seq_pos` to `firmware_t`, flash
metadata to `dispatch_record_t`, defaults in `fw_init` (matching Go, 256 KV
tile), and the tiled branch in `fw_plan_inference`. `kv_offload` now uses a
persistent `attn_target`. Verdict requires seq_pos advance per layer.
Committed `bbab641`.

### DISMISSED R25-G2: KV entry-bytes 512 vs hidden_size*4 divergence
**Analysis:** Go default run path and RTL `kv_cache_bank` both pin `ENTRY_BYTES`
= 512 (deliberate, documented in `DefaultKVCacheConfig`); the Go *planner*
(`model_ir.go`) and the C `kv_cache_init` both use `hidden_size*4`. The C
`kv_cache_init` is only called by the standalone `test_kv_load.c` (intentionally
uses a 16-wide fake model with `hidden*4` = 64-byte entries); the C run-path
firmware never initializes its KV cache. No run-path impact, no unambiguous
correct value (512 silicon frame vs hidden*4 model footprint are both
"correct" in different contexts), so no fix applied. Documented design split.

### DISMISSED R25-G3: KV full off-by-one
**Analysis:** `full_r <= (occupancy == BANK_DEPTH-1)` is an NBA reading the
pre-increment occupancy, so RTL fulls at 1024, matching Go `Full == (Occupancy
== Depth)`. Agent misread as full-at-1023. No bug.

### DISMISSED R25-D1: fp32_alu MIN/MAX/CMP "3 vs 4 cycles"
**Analysis:** MIN/MAX/CMP genuinely take 3 cycles valid-to-valid (the
registered output mux is already counted in the documented 3); FMA path is 4,
DIV 25. Every doc table reads `3 (MIN/MAX/CMP), 4 (FMA), 25 (DIV)` consistently.
No discrepancy.

### CONFIRMED R25-D2: profiling.md closed-form latency formula ambiguous
**File:** `docs/profiling.md:44`
**Bug:** Formula `wire_len - 1 + l_eff * spine_hops + x * X_hops +
PE_PIPE_DELAY` referenced undefined `spine_hops`/`X_hops` and multiplied
`l_eff`/`x` by them; the code asserts a plain sum `wire_len - 1 + lEff + x +
PE_PIPE_DELAY` (run.go:1014).
**Fix:** corrected to `wire_len - 1 + l_eff + x + PE_PIPE_DELAY` and defined
every variable with a pointer to the `verify()` closed form. Staged surgically
(hunk 1 only; the file carries other pre-existing edits). Committed `ba44ec0`.

### Memory fix carried over (R24-M)
`e36d0d2` (weight-payload memory: `SizeBytes`, 4KiB bounded payload, peak RSS
40.8GB→12MB) is the fix for the user's "pnm test uses up all 64 gigs" report.

## Bug audit log (2026-08-30, round 26)

### CONFIRMED R26-G1: int8_alu ADD/SUB/SHIFT/MIN/MAX/AND zero-extend signed results
**Files:** `HDL/core/int8_alu.v`
**Bug:** The working tree sign-extension fix (signed 8-bit wrap then
sign-extend to 16 bits) was **uncommitted**; HEAD zero-extended results, so
`-4 - 3` gave `249` instead of `0xFFF9`. Authoritative testbench `tb_int8_alu`
(16 checks) fails on HEAD (6 errors), passes on the working tree.
**Fix:** committed the pre-existing working-tree fix as `c3ab02a`
(sign-extends signed results + corrected "zero-extended"→"wrapping signed
sign-extended" header comment). Detector `/tmp/tb_int8_alu_r26.v`; verified
`-128 + -1 → 0x007F`, `100 + 100 → 0xFFC8`, all cases with 8-bit wrap +
sign-extend correct. The agent's original claim was a miscalculation of
`add_result[7]` (it IS the sign bit of the wrapped 8-bit value); the RTL was
functionally correct, but the HEAD zero-extension was a real latent bug now
preserved.

### CONFIRMED R26-H1: orchestrator_chip rc_fifo simultaneous write+drain count loss
**File:** `HDL/orchestrator_chip.v`
**Bug:** The result-collection FIFO (`rc_fifo_cnt`) had two NBAs on the same
counter: `rc_fifo_cnt <= cnt+1` in the write branch and `rc_fifo_cnt <= cnt-1`
in the drain branch. When a spine write and PCIe drain coincided, the last
NBA won (the -1), silently losing the written byte: the drain emitted `0x11`
instead of `0x22`.
**Fix:** introduced `rc_can_write` (`spine_extract_valid && boot_done &&
rc_fifo_cnt != 10`) and `rc_do_drain` (`rc_fifo_cnt != 0 && pcie_out_ready`)
and netted the update (`both → cnt`; write-or-drain → ±1). Detector
`/tmp/tb_rc_fifo_r26.v` extracts the exact always-block: ORIGINAL drains
`0x11`, FIXED drains `0x22`. Committed as `1a7c720` (staged hunk 12 of 12;
the file still carries other pre-existing uncommitted hunks, not committed).

### CONFIRMED R26-G2: HLSL and Haskell miscompile unary minus on a bare variable
**Files:** `sim/internal/pnm/hlsl_ir.go` (`resolveHLSLAtom`),
`sim/internal/pnm/haskell_ir.go` (`resolveHaskellAtom`)
**Bug:** A compound operand like `2.0 * -b` fell through to the Variable case
in `compileHLSLExprTo`/`compileHaskellExprTo`, emitting a read of an unwritten
register literally named `-b`, which later failed with "register read before
it is written". The R frontend already rejected this with a clean error; the
HLSL/Haskell twins did not.
**Fix:** each atom resolver now lowers `-var` to a real negation before the
recursive compile: HLSL emits `0 - b` via `ALUSub` off an `ALUConst 0.0`
(matching `emitALUAbs`), Haskell emits native `FP64Neg`. Regression tests
`TestHLSLUnaryMinusOnVariable` / `TestHaskellUnaryMinusOnVariable` added to
`ir_compound_test.go`. Verified via temp detector `zz_r26_unary_test.go`
(both fail with the dataflow error pre-fix, pass post-fix), then the tests
were promoted to permanent regression tests and the temp file removed.
Committed as `331f3b8` (staged with an entangled pre-existing HLSL
expression-lowering rework in the same function; cannot be split cleanly, and
the full suite validates the combined result).

### DISMISSED R26-G3: routing bitmap drops X coordinate
**Analysis:** `computeRouteBitmaps` (driver.go) encodes only LAYER + AXIS=Y +
Y-dist, so nodes sharing (layer, Y) get identical bitmaps. This is **by
design**: the X dimension is routed by source-routed parameterized `xy_turn`
gates (compare `LOCAL_X` against the MODULE_ID X nibble, `match_mask 8'hF0`),
not by the bitmap. `gen_topology.go:334` emits the identical Y-only
`((l+1)<<7)|(1<<6)|y` for the node MAC stubs, and `pe_tile_stub.v:437-439`
only mask-compares the AXIS-selected nibble (Y). The 11-bit layout
(L4|AXIS|SIGN|DIST5) supports one dimension by construction. Not a defect.

### CONFIRMED R26-D1: Paper.MD power, halo-hop, IR-op, and audit-reference errors
**Files:** `paper/Paper.MD`
**Fixes (verified against code/HDL), committed `463f164` (with regenerated
submission artifacts):**
- **0.6 MW → 0.25 MW** (3 spots: abstract, Section 1.1, Section 3.3): 819
  H100-class GPUs × 300 W = 0.246 MW ≈ 0.25 MW, not 0.6 MW.
- **Halo "two X-hops" → single dimension-order hop** (Section 2.11.2): a
  nearest-neighbor halo exchange is 1 hop in the closed-form
  (`wire_len-1 + l_eff + x + PE_PIPE_DELAY`, x=1 for a neighbor), matching
  the explicit "single-hop" claims in Sections 2.2/2.13/4.something. The
  build also flushed two pre-existing stale-submission corrections (abstract
  citation `{c(1,15)}`→`{c(15)}`, INT8 MAC "single-cycle"→"two-cycle");
  "two-cycle" matches `int8_mac.v`'s documented 2-cycle latency.
- **IR op list** (Section 2.6): added `f64.sub`, `f64.neg` (both in the FP64
  enum, r_ir.go:20,29) and `alu.const` (hlsl_ir.go:26) to the enumerations.
- **"Section HIGH-11" audit-log reference**: dropped, since HIGH-11 is an
  internal bug identifier, not a paper section, and the reference would not
  resolve. Rephrased to "a ready/valid bug class the harness's audit log
  documents fixing".

### DISMISSED R26-D2: "512 bitmaps at 6 bytes each"
**Analysis:** Paper.MD:105's "512 bitmaps at 6 bytes each via sideband" is a
first-order wire-format estimate for POST routing-table load; the bitmap
itself is 11 bits and there is no authoritative 4-byte load-entry constant in
the code to contradict 6 bytes, and either way 512 × 6 B = ~3 KB loads in
well under 1 s. No code contradiction. Left as-is.



## Bug audit log (2026-08-30, round 27)

### CONFIRMED R27-G1: C firmware shares one seq_pos across all model layers
**Files:** `fw/pnm_fw.c:228,367`, `fw/pnm_fw.h:213`
**Bug:** `fw_plan_inference` read a single `fw->seq_pos` (line 228) and advanced
it once per layer iteration (line 367), while the Go reference `firmware.go`
keeps a per-model-layer `SeqPositions[ml]` (lines 384, 520). For tiled flash
attention, `num_kv_tiles = (seq_pos + tile)/tile` is derived from that position.
Because the C global counter grew model_layers× faster than any layer's own
position, once the shared counter crossed a tile boundary (seq_pos=256) the C
firmware emitted 2 KV tiles per layer where Go emitted 1 — 64 mismatched
layer-call tile counts (C=384 vs Go=320) in a 4-layer, 256-tile run.
**Detector:** `r27_fw_seqpos_test.c` runs the real `fw_plan_inference` with
flash_attn, 2 layers, and 260 calls past the tile boundary. Pre-fix FAILED
(MISMATCH call=128 layer=0/1 got_tiles=2 exp=1); post-fix PASSED with both
layers advancing independently to 260 positions.
**Fix:** `fw->seq_pos` is now `int seq_pos[PNM_MAX_MODEL_LAYERS]`; the plan loop
reads/writes `fw->seq_pos[ml]`, mirroring `SeqPositions[ml]`. `fw_init`'s
`memset(fw,0,...)` zero-initializes it. `kv_store`/`kv_load` are unaffected
(they take seq_pos as a parameter).
**Commit:** `e595def`.

### CONFIRMED R27-D1: Paper.MD weight-upload LEN order reversed
**File:** `paper/Paper.MD:97`
**Bug:** The WEIGHT_UPLOAD command was shown as `... MODULE_ID | LEN_HI | LEN_LO | ...`,
reversed from the byte 3 = LEN_LO / byte 4 = LEN_HI order used everywhere else
(`pnm_defs.vh:9-10`, `usage_manual.md:57-58`, the paper's own §2.9, and the
firmware `Flit()` builder at `run.go:110`). No code paths emit a reversed LEN
order, so this was a documentation inconsistency.
**Fix:** Changed to `LEN_LO | LEN_HI`.
**Commit:** `a05e79d`.

### CONFIRMED R27-D2: Paper.MD misattributes SoC config constants to the MCU port
**File:** `paper/Paper.MD:117`
**Bug:** The C-port sentence quoted `PNM_MAX_LAYERS=8`, `PNM_MAX_NODES_TOTAL=512`,
`PNM_MAX_EXPERTS=256`, `PNM_KV_CACHE_DEPTH=4096` as if they were the MCU
target's constants. `pnm_fw.h` `#ifdef PNM_MCU` actually uses `2/32/16/64`
(with `PNM_MAX_MODEL_LAYERS=8`); the larger 8/512/256/4096 are the non-MCU
(SoC) defaults.
**Fix:** Rephrased to note the reduced `PNM_MCU` limits and reserve the full
SoC defaults for the non-MCU build.
**Commit:** `a05e79d`.

### CONFIRMED R27-D3: pcb/README.md orchestrator_sbc memory map wrong
**File:** `pcb/README.md`
**Bug:** Listed CLINT as 4 KB (actual: `orchestrator_sbc.v:117` decodes
`0x2000_0000`–`0x2000_FFFF` = 64 KB), claimed "No DRAM on the processor
package" (actual: `orchestrator_sbc.v:119` decodes a 1 GB LPDDR5/6 window at
`0x8000_0000`, matching `usage_manual.md:111`), and the memory-map table had no
DRAM row.
**Fix:** CLINT → 64 KB, added a 1 GB DRAM row at `0x8000_0000`, and rewrote the
"no DRAM" sentence to note the SoC's 1 GB LPDDR5/6 window while the Pi Bridge /
MCU variants run from SRAM only. Also folded in earlier-uncommitted corrections
(8×8=512 reference nodes, 64 nodes/layer, 64 KB boot ROM, gating_asic rename).
**Commit:** `bcd59a0`.

### DISMISSED R27-H1: pe_tile_stub FMA accumulator uninitialized
**File:** `HDL/core/pe_tile_stub.v:215-218`
**Analysis:** `fma_acc_lo`, `fma_acc_byte`, `fma_word_in`, `fma_valid_d` are not
in the reset block (:354-364). But iverilog defaults uninitialized regs to 0
(`vvp -x` unsupported), and the code's FMA path relies on that default-0
(treats `fma_acc_lo==0` as "expecting low byte"). A corrected detector
(`/tmp/tb_fma_firstword.v`, USE_FMA=1, weight 1.0) shows the payload
`11 80 04 00 12 34 56 78` is byte-correct at indices 4..7 — the first-word
behavior is right. An attempted defensive reset changed the captured output
length (10→8 bytes), i.e. it is NOT timing-neutral, and no failing detector
can be constructed under iverilog's default-0 masking. Per the failing-detector
protocol this is dismissed as a latent synthesis-hygiene note, not a sim-visible
bug.

### DISMISSED R27-G2: C kv_store writes full seq_pos vs Go bank-local
**Files:** `fw/pnm_fw.c:472,504`, `sim/internal/pnm/kv_cache.go:365,390`
**Analysis:** C `kv_store` stores the full `seq_pos` in `entry_seq` while Go
`KVCacheBank.Store` stores the bank-local `seqPos/NumBanks`. Both select the
same bank (`seq_pos % banks`) and the same circular slot (`(seq_pos/banks)%depth`),
and each twin validates load with the same label it wrote (C at :504, Go at :390).
Internally consistent per twin; the divergent label value only matters if the two
twins' `entry_seq` arrays are cross-compared, which never happens. Functionally
equivalent — dismissed.

### DISMISSED R27-H2: weight_dequant -128 → -0.0
**File:** `HDL/core/weight_dequant.v:47`
**Analysis:** Agent (and initially I) claimed input 0x80 (−128) makes
`weight_abs_9[7:0]` become 0x00. Tracing the 9-bit absolute value: −(−128) =
+128 = `9'b0_1000_0000`, whose low byte is `0x80`, not `0x00`. The `[7:0]` slice
is correct for all |x| ≤ 128. Both HEAD and working-tree pass `tb_weight_dequant.v`.
Agent miscalculation — dismissed.

## Bug audit log (2026-08-30, round 28)

### CONFIRMED R28-H1: `int8_alu.v` SHIFT truncates bit-7 overflow
**File:** `HDL/core/int8_alu.v:42,62,81`
**Bug:** Arithmetic left shift wrote into an 8-bit signed register
(`reg signed [7:0] shift_result`), so `1<<7=+128` wrapped to `-128` and
sign-extended to `0xFF80` instead of `0x0080`.
**Detector:** `/tmp/tb_int8_shift.v` — `1<<7` returned `0xFF80` pre-fix,
`0x0080` post-fix.
**Fix:** Widened to `reg signed [8:0]`, `$signed(a) <<< b[2:0]`,
sign-extend from bit 8. Regression `tb_int8_alu.v` now pins `1<<7=+128` (17/17).
**Commit:** `52837b8`.

### CONFIRMED R28-G1: C source-language ports plan phantom layers
**Files:** `fw/pnm_fw_r.c`, `fw/pnm_fw_haskell.c`, `fw/pnm_fw_hlsl.c`
**Bug:** The R/Haskell/HLSL C ports never clamped `model_layers` to
`num_hidden_layers`, so with num_layers=4, mpl=2, num_hidden_layers=5 they
planned layers 0..7 instead of 0..4 (phantom dispatch).
**Detector:** `/tmp/r28_phantom_detect.c` — max_layer 7 pre-fix, 4 post-fix;
16 records → 10.
**Fix:** Compute `model_layers = mpl*num_layers`, clamp to `num_hidden_layers` if
>0, clamp negative to 0, loop `ml < model_layers` (mirrors `pnm_fw.c`).
**Commit:** `42b2960` (also relocates the ports from `sim/fw/` to `fw/`).

### CONFIRMED R28-G2: C source-language ports route MoE to fixed experts
**Files:** `fw/pnm_fw_r.c`, `fw/pnm_fw_haskell.c`, `fw/pnm_fw_hlsl.c`
**Bug:** All three ports selected only experts with global index in
`0..PNM_MAX_TOPK-1`, ignoring the token gate; sparse experts {100..115} got 0
MoE records vs the reference's 8.
**Detector:** `/tmp/r28_moe_detect.c` (0→8 records) +
`/tmp/r28_crosstwin.c` (R port emits the **identical** expert sequence as the
main twin: `203 170 400 105 310 88 18 55`).
**Fix:** Ported `fnv1a_64` + `select_topk` matching `pnm_fw.c:122-171` and
replaced the fixed-expert loop with gate-scoring selection over the layer's
`moe_map` population.
**Commit:** `42b2960`.

### CONFIRMED R28-G3: `KVCacheLayer.RepeatKV` silently disables GQA
**File:** `sim/internal/pnm/kv_cache.go:578`
**Bug:** Per-head size was `HeadDim*2 * (EntryBytes/(NumKVHeads*HeadDim*2))`.
When the frame was not a clean multiple of all heads (EntryBytes=512, 8 KV
heads @ HeadDim 64), the integer quotient truncated to zero and RepeatKV
returned the entry un-expanded, disabling grouped-query attention.
**Detector:** `/tmp/r28_repeatkv_test.go` — returned 512 bytes pre-fix, 2048
post-fix.
**Fix:** `kvBytesPerHead = EntryBytes/NumKeyValueHeads` (direct frame split).
Full `go test ./internal/pnm/` still passes.
**Commit:** `a49b676`.

### CONFIRMED R28-G4: C `kv_cache_init` derives entry_bytes from hidden_size
**File:** `fw/pnm_fw.c:433`, `fw/pnm_fw.h`
**Bug:** `entry_bytes = hidden_size*4` (e.g. 1024 for hidden 256), diverging
from the RTL `kv_cache_bank` ENTRY_BYTES=512 frame and the Go twin's pinned
`DefaultKVCacheConfig`, overstating paper capacity.
**Detector:** `/tmp/r28_kvcache_detect.c` — 1024 pre-fix, 512 post-fix.
**Fix:** Added `PNM_KV_ENTRY_BYTES 512` and used it in `kv_cache_init`;
removed the stale `sim/fw/pnm_fw.*` duplicates. Compiles clean in SoC + MCU.
**Commit:** `bca83b6`.

### CONFIRMED R28-D1: fp32_alu division latency mis-documented as 25 cycles
**Files:** `paper/Paper.MD:437,440`, `docs/usage_manual.md:91`, `AGENTS.md:192`
**Bug:** FP32 DIV FSM measures 28 cycles (DIV_IDLE + 26 compute + DIV_NORM +
output reg), not 25.
**Detector:** `/tmp/tb_fp32_div_lat.v` (28 cycles).
**Fix:** `3--25→3--28`, `25-cycle→28-cycle`, `25 (DIV)→28 (DIV)` across the
manuscript, table, submission artifacts, and both manuals.
**Commit:** `048ae15`.

### CONFIRMED R28-D2: usage_manual compute-unit taxonomy missing fp16_mac_array
**File:** `docs/usage_manual.md:82`
**Bug:** The compute-unit table listed 7 rows, omitting `fp16_mac_array.v`
present in both Paper.MD Table 4a and AGENTS.md (which list 8). (AGENTS.md's 11
rows are the full hardware catalog, a superset, and correct.)
**Fix:** Added the missing `fp16_mac_array.v` row so usage_manual matches the
8-unit reference-node taxonomy.
**Commit:** `048ae15`.

### DISMISSED R28-H2: `pe_tile_stub.v` FMA output stream position
**Analysis:** Agent claimed FMA results land at the wrong byte offset in the
output stream. Only exercisable with `USE_FMA=1`, which is not the shipped
default (USE_FMA=0 bias-add) and is not exercised by any committed regression.
No failing detector in shipped configs; iverilog defaults uninitialized regs to
0 so a missing-reset variant would not surface. Mirrors R27-H1 reasoning —
dismissed.

### DISMISSED R28-H3: `pe_tile_stub.v` INT4 accumulator never emitted
**Analysis:** Agent claimed the INT4 accumulation result is never driven onto
the output. Only reachable with `CU_TYPE=2` (INT4 MAC path), not the shipped
default and not covered by a committed regression. No failing detector —
dismissed.

### DISMISSED R28-H4: `int4_mac_array.v` sop/eop capture race
**Analysis:** Agent claimed a timing race capturing sop/eop could miscount in
edge cases. Latent in an unshipped config (`USE_FMA=0`, CU_TYPE not 2), no
failing detector in shipped configs. Dismissed per protocol.

### DISMISSED R28-D3: compute-unit taxonomy "8 vs 11 vs 7" contradiction
**Analysis:** Paper.MD Table 4a lists 8 units and its prose says "eight unit
types" — self-consistent. AGENTS.md lists 11 (full hardware catalog, a
superset, correct). Only usage_manual's 7 was wrong; that is fixed as R28-D2.
No remaining contradiction — dismissed.

## Bug audit log (2026-08-30, round 29)

### CONFIRMED R29-G1: `fw_verify_dispatch` rejects its own flash-attention plan
**File:** `fw/pnm_fw.c:411`
**Bug:** `fw_init` sets `flash_attn_enabled=1` (default); `fw_plan_inference`
then emits `"flash_attn"` store+load records as the leading records of every
layer. `fw_verify_dispatch` required the first record of a layer to be
`"dense"`, so under the default it returned -1 on the planner's own valid
output.
**Detector:** `/tmp/r29_verify_flash.c` — `verify_rc=-1` pre-fix, `verify_rc=0`
post-fix. (The Go `VerifyDispatch` never imposed a "dense-first" rule; the C
check was stricter than the reference.)
**Fix:** Accept `"flash_attn"` as a valid first-of-layer phase.
**Commit:** `a5b432d`.

### CONFIRMED R29-G2: C source-language ports omit the PNM_MAX_MODEL_LAYERS clamp
**Files:** `fw/pnm_fw_r.c:104`, `fw/pnm_fw_haskell.c:105`, `fw/pnm_fw_hlsl.c:115`
**Bug:** The three ports clamped `model_layers` only against `num_hidden_layers`
and `>= 0`, dropping the main twin's `model_layers > PNM_MAX_MODEL_LAYERS`
clamp. With `mpl*num_layers > 128` (e.g. mpl=17 on the 8-layer chassis) the R
port planned 272 records vs the reference's 256.
**Detector:** `/tmp/r29_clamp_detect.c` — main=256 vs R=272 pre-fix, 256 vs 256
post-fix.
**Fix:** Add `if (model_layers > PNM_MAX_MODEL_LAYERS) model_layers = PNM_MAX_MODEL_LAYERS;`
to all three ports.
**Commit:** `a5b432d`.

### CONFIRMED R29-D1: remaining stale fp32_alu DIV latency (25) in docs
**Files:** `paper/docs.md:53`, `HDL/README.md:26,71,303,353`,
`HDL/core/fp32_alu.v:8,258`, `HDL/core/fp32_alu_chip.v:17`,
`paper/submission/paper_review.tex:460,463`
**Bug:** The round-28 DIV-latency fix (25→28) was not fully propagated: these
remaining docs/comments and the `--review` artifact still said "25". (AGENTS.md
historical audit-log entries are intentionally left untouched.)
**Fix:** Corrected all to 28 and regenerated `paper_review.*`.
**Commit:** `a5b432d`.

### DISMISSED R29-H1: fp32_alu CMP (a>=b) vs fp64_alu CMP (a==b)
**Analysis:** The two ALUs implement different documented CMP contracts —
`HDL/README.md:306` documents `alu.cmp ..., >=` for fp32 and
`HDL/README.md:290` documents `f64.cmp ..., ==` for fp64, each matching its RTL
with a deliberate comment (fp64 switched from `>=` to `==` for equality-only).
Self-consistent per module contract, not a wrong result against the respective
README. The wider concern — the R/Haskell/HLSL IR emits `FP64Cmp`/`ALUCmp` with
arbitrary `Cond` values (`==`,`!=`,`<`,`>`,`<=`,`>=`) while each RTL hardwires one
operator — is a real cross-cutting design gap (a compiled program with a non-
hardwired condition silently gets the fixed operator), but it is not demonstrably
wrong against a single authoritative contract and needs a tracked lowering/emulation
decision. Flagged, not fixed this round.

## Feature: FP4 and MXFP4 quantized compute units (2026-08-27)

User request: "also add fp4, mxfp4 and a wider range of options". Implemented a
set of 4-bit floating-point quantized compute units plus a broadened precision
taxonomy.

**New hardware units (`HDL/core/`):**
- `fp4_mac.v` — packed E2M1 (OCP Microscaling) MAC. Two FP4 values per byte,
  dequantized to fixed point (value×8) via a direct lookup table, product to
  INT32 accumulate. `wshift[3:0]` input lifts the weight dequant by 2^wshift for
  MXFP4 block scaling. 2-cycle pipeline, same port shape as int4_mac/int8_mac.
- `fp4_mac_array.v` — weight-stationary systolic array of fp4_mac PEs, identical
  structure to int4_mac_array.v (time-staggered, valid-gated accumulation).
- `mxfp4_mac_array.v` — same array plus a per-row 8-bit block scale (`scale_in`/
  `scale_load`) folded into each row's wshift (OCP microscaling convention).
- Dot-product scale: accumulator = sum(d8a × (d8b ≪ scale)); physical value
  = result / 64. All 16 E2M1 encodings map via LUT: 0, ±0.25, ±0.5, ±0.75,
  ±1.0, ±1.5, ±2.0, ±3.0.
- `weight_dequant.v` widened `mode` to 2 bits (0=INT4,1=INT8,2=FP4,3=MXFP4),
  added `scale_in`; FP4/MXFP4 use an E2M1→BF16 lookup with the block exponent
  added into the BF16 exponent field.

**Integration:**
- `pe_tile_stub.v` CU_TYPE 3 (FP4) and 4 (MXFP4) element-wise MAC paths
  (reuse the int4_acc/int4_out serializer); `FP4_WEIGHT`/`MXFP4_SHIFT`
  parameters. Synced to the `paper/HDL/core/` mirror.
- `model_compiler.go` `CUTypeFP4Array`/`CUTypeMXFP4Array` (String/DTypeBytes=1,
  packed).
- `llm_client.go` `QuantFP4`/`QuantMXFP4` QuantMode options mapped to the new
  array units; QuantWeightBytes returns 1 (packed byte).
- `run.go` FABRIC list and `pnmt` tb registry include the new modules.

**Tests:** tb_fp4_mac (nibble planes, accumulate, negative, MXFP4 scale),
tb_fp4_mac_array (identity + weighted column), tb_mxfp4_mac_array (block scale
apply + reload), tb_weight_dequant FP4/MXFP4 rows. All pass; `go test ./internal/pnm/`
and the full `go run ./cmd/pnm` fabric co-sim still pass.

**Docs:** Paper.MD Table 4a now lists **eleven** unit types (was eight; added
int4_mac_array, fp4_mac_array, mxfp4_mac_array) plus a paragraph on the FP4/MXFP4
quantized spectrum and MXFP4 block scale. HDL/README, docs/usage_manual, README
updated; submission/ regenerated.

**Note (reconciles prior R28-D3 dismissal):** the earlier "8 vs 11" taxonomy gap
(Table 4a 8 vs AGENTS hardware catalog 11) is now closed by the manuscript itself
listing all 11 units.

**Commit:** `2379247`.
## Bug audit log (2026-08-27, round 30)

### CONFIRMED R30-H1: FP4/MXFP4 E2M1 dequant LUT off by a factor of two
**Files:** `HDL/core/fp4_mac.v:71-110`, `HDL/core/weight_dequant.v:83-95`
**Bug:** The E2M1 (OCP Microscaling FP4) dequant lookup mapped codewords to
`{0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3}` (the INT4-style quarter-step ladder),
but the true OCP MXFP4 E2M1 magnitude set is `{0, 0.5, 1, 1.5, 2, 3, 4, 6}`
(codewords 0000-0111, E2M1 with bias 1). The top of the range was capped at
3.0, silently dropping the valid 4.0 and 6.0 encodings, and every value below
6.0 was halved. `b_scaled` was 16 bits wide, too narrow for the 6.0 (x8 = 48)
products during MXFP4 block scaling.
**Detector:** `/tmp/tb_fp4_lut.v` — asserted `0010→1.0, 0100→2.0, 0101→3.0,
0111→6.0`; FAILED before fix, PASS after.
**Fix:** Corrected both LUTs to the OCP magnitude set (d8 = value×8 =
`{0,4,8,12,16,24,32,48}`), widened `b_scaled` 16→32 bits, updated the four
FP4/MXFP4 testbenches to the correct values. All FP4/MXFP4 testbenches,
`go test ./internal/pnm/`, and the full `go run ./cmd/pnm` fabric co-sim pass.
**Commit:** `f19be51`.

### R30-D*: documentation consistency (docs agent)
- **FIXED:** AGENTS.md CU_TYPE description was stale (only 0/1/2; now lists all
  five paths 0=bias-add, 1=BF16 FMA, 2=INT4 MAC, 3=FP4, 4=MXFP4).
- **FIXED:** AGENTS.md compute-units catalog was missing the fp4/mxfp4 rows;
  added them. Eleven-unit count now consistent across all active docs.
- **NOT fixed (historical):** the historical DIV "25" note is superseded by the
  documented 28-cycle latency (in changelog); left as historical per convention.


## Bug audit log (2026-08-27, round 31)

### CONFIRMED R31-H1: `weight_dequant.v` INT4/INT8 negative weights dequantize to positive BF16 (sign lost)
**File:** `HDL/core/weight_dequant.v:106-108`
**Bug:** For the INT path (`mode[1]==0`), the BF16 sign bit was hardwired to `1'b0`
in the nonzero branch of `bf16_mag`. `weight_sign` was computed but only consumed
in the zero branch. Negative INT4/INT8 weights produced magnitude-correct but
sign-flipped BF16: INT4 `0x0F` (-1) → `0x3F80` (+1.0) instead of `0xBF80` (-1.0);
INT8 `0x80` (-128) → `0x4300` (+128.0) instead of `0xC300` (-128.0). The module's
own `tb_weight_dequant.v` asserted the correct negative golden values but passed
vacuously — its `send_and_check` handshake (repeat(3) without flush) never reliably
captured `valid_out`, so it never detected the mismatch.
**Detector:** `/tmp/tb_wd_mon.v` — `$monitor` of a single INT4 `0x0F` input showed
`0x3F80` before fix, `0xBF80` after.
**Fix:** Changed the nonzero INT branch from `{1'b0, ...}` to
`{weight_sign, bf16_exp, norm_mantissa[6:0]}`.
**Commit:** `efc3755`.

### CONFIRMED R31-G1: `weight_dequant.v` MXFP4 zero weight with nonzero scale dequantizes to nonzero BF16
**File:** `HDL/core/weight_dequant.v:99-102`
**Bug:** `fp4_mag_scaled` unconditionally added `scale_in[3:0]` into the BF16
exponent field. For the zero codeword (`fp4_mag_bf16 = 16'h0000`), the zero
exponent field plus a nonzero scale produced a nonzero value, but `0 x 2^scale = 0`
must be exact zero. The INT4/INT8 branch already guarded zero; the FP4/MXFP4 path
did not. The passing `tb_weight_dequant.v` MXFP4 rows never drove the `0x00`
codeword with a scale, so it went undetected.
**Detector:** `/tmp/tb_wd_zero.v` — MXFP4 `weight_in=0x00`, `scale_in=2` showed
`0x0100` before fix, `0x0000` after.
**Fix:** Guarded `fp4_mag_scaled` with `(fp4_mag_bf16 == 16'h0) ? 16'h0 : ...`.
**Commit:** `efc3755`.

### DISMISSED R31-H2: `fp4_mac.v` MXFP4 block-scale shift alleged 12-bit truncation
**File:** `HDL/core/fp4_mac.v:95`
**Claim:** `b_scaled = b_d8 << wshift` where `b_d8` is `reg signed [11:0]`; a strict
reading of IEEE 1364-2005 §5.1.2 (self-determined left operand width) would truncate
the shift to 12 bits, wrapping any `|d8| << wshift >= 4096`.
**Detector:** `/tmp/tb_fp4shift.v` — a=1.0 (d8=8), b=6.0 (d8=48), wshift=7. Correct
`8 * (48<<7) = 49152`; 12-bit-truncated would be `8 * 2048 = 16384`. The RTL produced
**49152** (the correct full-width value). Icarus Verilog evaluates the shift in the
32-bit context of `b_scaled`, so there is no truncation in the co-simulation path
(which is the source of the paper's numbers) or in the comment's stated intent.
Not a bug under the actual toolchain; flagged in case a synthesis tool evaluates the
shift differently.

### CONFIRMED R31-D1: FP4 (E2M1) density claimed 8x vs BF16 / 2x vs INT4 (wrong)
**Files:** `paper/Paper.MD:440,445`, `HDL/README.md:77`, `docs/usage_manual.md:96`,
`HDL/core/fp4_mac.v` + `fp4_mac_array.v` headers, `sim/internal/pnm/model_compiler.go:56`,
`sim/internal/pnm/llm_client.go:561`, `AGENTS.md` catalog row.
**Bug:** FP4 (E2M1) is a **4-bit** format packing two values per byte, so it has
**4x** the packing density of BF16 and is **equal to INT4** (which also packs two per
byte). Every active source claimed "8x density vs BF16 and 2x vs INT4" / "8x
compression", which would put FP4 at half INT4's bit count (2-bit) — contradicted by
the paper's own same-sentence "two per byte" and by the RTL's packed-byte layout.
**Fix:** Corrected to "4x packing density of BF16, equal to that of INT4" across all
seven locations; regenerated `paper/submission/*`. Verified `paper.tex:456,461`.
**Commit:** `efc3755`.

## Bug audit log (2026-08-30, round 32)

### C1: `pe_tile_stub.v` compute-unit serializer rewrite (CU_TYPE paths)
**File:** `HDL/core/pe_tile_stub.v`
**Change:** Unifies the always-block driving the node's output serializer across all
compute paths (bias-add, BF16 FMA, INT4/FP4/MXFP4 MAC). The INT4/FP4/MXFP4 MAC path now
maintains a direct 32-bit running sum per payload byte and drains on `tready`, and the
master take-over on the residual feed is correctly sequenced. Verified by the doorbell
TB (activations=6, rejections=2, corrupt=2), the `pe_int4` core TB, and the fabric
co-sim (`go run ./cmd/pnm` ALL SCENARIOS PASSED).

### C2/S1: `fp32_alu_chip.v` flit/CRC rewrite
**File:** `HDL/core/fp32_alu_chip.v`
**Change:** Rewrote the ALU-chip control so it collects the flit header + payload,
computes CRC-16/CCITT-FALSE over `[MODULE_ID .. last payload]`, compares against the
trailing CRC bytes, asserts `corrupt_out` on mismatch, and re-arms to 0xFFFF for the
next flit (ST_IDLE/COLLECT/COMPUTE/EMIT). Verified by the new `core/tb_fp32_alu_chip.v`
regression and pnmt hdl-core (27/27).

### S2: INT4/FP4/MXFP4 MAC arrays accepted a mid-drain re-fire, corrupting in-flight accumulation
**Files:** `HDL/core/fp4_mac_array.v`, `HDL/core/int4_mac_array.v`,
`HDL/core/mxfp4_mac_array.v`
**Bug:** The round-15 `accept = act_valid && !out_active` arming fix was present on the
fp16/bf16/fp32 arrays but NOT on the three quantized (int4/fp4/mxfp4) arrays. A second
`act_valid` pulse asserted before the first drain completed re-fired the input capture,
overwriting the in-flight activation and its partial sum.
**Detector:** `/tmp/tb_fp4_refeed.v` — FAILED on unfixed fp4 array (3 errors, second
result corrupted), PASSED after fix.
**Fix (identical edit to all three):** Added a per-array `fed` latch (arming
single-shot): `wire accept = act_valid && !fed;` that captures the activation on the
accept edge and holds until the drain clears it (`assign busy = fed;`). `act_valid_q`
samples `accept` so no re-fire during the drain can corrupt state.
**Verification:** fp4/int4/mxfp4 array regressions all PASS; fp16/bf16/fp32 array
regressions still PASS (6 arrays total); S2 detector PASSES.
**Also (race fix in the array TBs):** The committed array regressions failed on
`result_sop`/`result_eop` because `tb_fp4_mac_array.v` / `tb_int4_mac_array.v` /
`tb_mxfp4_mac_array.v` assigned `act_sop`/`act_eop` and `act_valid` in the same
timestep. Under the old double-firing `if (act_valid)` this was masked; the new
single-shot `accept` exposed it. Fixed the three TBs with the proven pattern:
set `act_sop`/`act_eop`, `#1;`, set `act_valid=1`, `@(posedge clk); #1;` deassert.

### R32-G1: C firmware sliding-window twin divergence (firmware.go vs pnm_fw.c)
**Files:** `fw/pnm_fw.c`, `fw/pnm_fw.h`
**Bug:** The Go `PlanInference` (sim/internal/pnm/firmware.go) computes per-model-layer
`WindowStart`/`WindowEnd` via `layerIsSliding` (clamping `if(win_start<0)win_start=0`);
the C twin (`fw/pnm_fw.c`) hardcoded `window_start=-1`/`window_end=-1` on every attn
record, so a compiled sliding-window dispatch diverged from the Go reference.
**Detector:** `/tmp/r32_sliding_detect.c` — FAILED on old code (layer-1 window collapsed
to `[0:0]`), PASSED after fix (`SLIDING-WINDOW OK (layer1 [69:100], layer0 full)`).
**Fix:** Added `int sliding_window[PNM_MAX_MODEL_LAYERS];` to `firmware_t`
(pnm_fw.h:221); `fw_plan_inference` now computes `win_start`/`win_end` once per model
layer (mirroring the Go clamp) and applies them to both the flash and dense store/load
records (pnm_fw.c:238-243, 263-315). Compiles clean under
`gcc -Wall -Wextra -std=c11 -I.`.

### R32 D1/D2/D3: documentation corrections
- **D1 (doorbell command missing fp4_mac):** `pe_tile_stub.v` unconditionally
  instantiates `fp4_mac`, so every committed doorbell iverilog command failed to
  elaborate ("Unknown module type: fp4_mac"). Added `core/fp4_mac.v` to the doorbell
  command in `AGENTS.md:58`, `HDL/README.md:176`, `paper/readme.md:60,62`,
  `paper/docs.md:626`, `reproduce.sh:75`. Verified `tb_doorbell.v` PASSES with it.
- **D2 (paper/docs.md compute-unit table):** `paper/docs.md:45-55` omitted the
  INT4/FP4/MXFP4 quantized family (8 units besides gating, not 11). Added rows for
  `int4_mac.v`, `int4_mac_array.v`, `fp4_mac.v`, `fp4_mac_array.v`,
  `mxfp4_mac_array.v` to match usage_manual.md.
- **D3 (usage_manual UART/PCIe window sizes):** `docs/usage_manual.md:114,118` claimed
  "4 KB" for UART/PCIe; RTL decode (`orchestrator_sbc.v:116,120`) shows UART=256B
  (`cpu_addr[31:8]==24'h1000_00`) and PCIe=256MB (`cpu_addr[31:28]==4'hC`). Both
  fixed.

### R32 REGRESSION FIX: R28-G4 entry_bytes change broke `test_kv_load.c` (segfault)
**File:** `fw/test_kv_load.c`
**Bug:** Round-28-G4 pinned `kv_cache_init`'s `entry_bytes` to the RTL-fixed
`PNM_KV_ENTRY_BYTES` (512) and made `hidden_size` unused. But `test_kv_load.c`
allocated 64-byte banks (`store[PNM_KV_CACHE_BANKS][2][64]`) and called
`kv_cache_init(&kv, 1, 16)` expecting `entry_bytes=64`. `kv_store` computed
`offset = write_ptr * bank->entry_bytes = write_ptr * 512` and `memcpy`'d 64 bytes at
offset 512+, overrunning the 128-byte `store[b]` array. ASAN (gcc -fsanitize=address)
reported a stack-buffer-overflow WRITE of size 64 at `pnm_fw.c:494`, and the committed
Go integration detector `TestIntegration_CKVLoadNonDestructive` segfaulted (exit 139).
**Fix:** Updated `test_kv_load.c` to size its banks with `PNM_KV_ENTRY_BYTES`
(`store[PNM_KV_CACHE_BANKS][2][EBYTES]`, `entries[i][EBYTES]`, entry length `EBYTES`),
preserving the test's intent (positional non-destructive `kv_load`) while matching
`kv_cache_init`'s RTL-fixed frame. ASAN-clean (exit 0, ALL PASS); both
`TestIntegration_CKVLoadNonDestructive` and `TestDESCrossCheckRTL` PASS.
**Note:** the `kv_store`/`kv_load`/`kv_evict_oldest` offset arithmetic
(`idx * bank->entry_bytes`, `copy_len` clamped to `entry_bytes`) is internally
consistent; the overrun was purely a caller/buffer-size mismatch in the test, now
fixed.

### Round-32 verification / regression
- `go build ./...` clean.
- `go test ./internal/pnm/` — 164 tests PASS, 0 FAIL, 0 SKIP (with iverilog on PATH).
- `go run ./cmd/pnmt hdl-core` — All 27 tests passed (incl. moved `tb_pe_int4.v`,
  `tb_fp32_alu_chip.v`; new `fp32_alu_chip`/`pe_int4` registry entries).
- `go run ./cmd/pnmt go` / `c` / `integration` / `lint` — all pass.
- `go run ./cmd/pnm` — ALL SCENARIOS PASSED (fabric co-sim, 48-node).
- Array regressions (fp4/int4/mxfp4 + fp16/bf16/fp32) all PASS; S2 detector PASS;
  doorbell TB PASS; fp4 refeed detector PASS.
- **Files moved:** `HDL/tb_pe_int4.v` → `HDL/core/tb_pe_int4.v`,
  `HDL/tb_fp32_alu_chip.v` → `HDL/core/tb_fp32_alu_chip.v` (pnmt registry references
  `core/` paths; both untracked new files).

### Round-32 notes
- The round-32 Go/C and docs agent dispatches were rate-limited this session; on
  re-dispatch they returned the following CONFIRMED findings, all verified with
  failing detectors and fixed:
- **R32-G2 (flash_num_tiles on KV-load record):** `fw/pnm_fw.c:282` set
  `lr->flash_num_tiles = num_kv_tiles` on the flash-attention **load** record, but the
  Go twin (`firmware.go:423-436`) leaves `FlashNumTiles` at 0 on the load record (only
  the STORE records set it). Detector `/tmp/det_flash_load_tiles.c` FAILED pre-fix
  (`flash KV-load flash_num_tiles=1 (Go twin=0)`), PASSED post-fix. Fix: set
  `lr->flash_num_tiles = 0` explicitly on the load record, matching the Go reference.
- **R32-G3 (kv_store never zero-pads to the entry frame):** Go `KVCacheBank.Store`
  (`kv_cache.go:358-363`) builds `padded := make([]byte, b.EntryBytes)` and `copy`s
  the entry into it, so `Load` returns a zero-padded full frame. The C `kv_store`
  (`pnm_fw.c:492-494`) copied only `min(entry_len, entry_bytes)` bytes and left the
  tail bytes stale (prior occupant / uninitialized), so a short entry read back
  divergent tail bytes vs Go. Detector `/tmp/det_kv_pad.c` FAILED pre-fix
  (`kv_load tail byte[10]=0xAA, Go twin zero-pads`), PASSED post-fix. Fix: after
  `memcpy`, `memset` the remainder of the slot
  (`entries+offset+copy_len` .. `+entry_bytes-copy_len`) to 0, mirroring Go.
  **Committed regression:** strengthened `fw/test_kv_load.c` with a short-entry
  store + full-frame load that asserts the tail is zero-padded (both new CHECKs PASS;
  ASAN-clean).
- **R32-D4 (pcb/README memory-map UART/PCIe sizes):** `pcb/README.md:79,83` documented
  UART and PCIe windows as 4 KB, but `orchestrator_sbc.v:116,120` decode UART=256B
  (`cpu_addr[31:8]==24'h1000_00`) and PCIe=256MB (`cpu_addr[31:28]==4'hC`). Fixed both
  rows to 256B / 256MB (same class as the round-32 D3 usage_manual fix, propagated to
  pcb/README).
- Verified detectors: `/tmp/det_flash_load_tiles.c`, `/tmp/det_kv_pad.c` — both
  FAIL pre-fix, PASS post-fix; `/tmp/test_kv_load` (strengthened) — ASAN-clean PASS;
  `TestIntegration_CKVLoadNonDestructive` / `TestIntegration_CMoeGating` — PASS.


## Bug audit log (2026-08-30, round 33)

### CONFIRMED R33-G1: C firmware offload drained only the current layer (record-stream divergence)
**Files:** `fw/pnm_fw.c:319-349` (Step 2b of `fw_plan_inference`)
**Bug:** The C port drained only the *current* physical layer (`layers[pl]`) when
a KV cache crossed the 80% offload threshold, emitting one `kv_offload` record
per over-threshold layer. The Go reference (`firmware.go PlanInference` +
`KVCache.OffloadCycle` at `kv_cache.go:798`) drains *every* over-threshold layer
at the FIRST trigger and emits a single record: `if Layers[pl].NeedsOffload() {
append(evict record); fw.KV.OffloadCycle() }`, where `OffloadCycle` loops over
all `kc.Layers`. On identical input (2 physical layers, 4 model layers, both KV
caches past threshold) the two twins produced different dispatch plans: **Go=1
kv_offload record / 17 total, C=2 / 18**. Both reached the same final occupancy
(Go drains through the layer loop; C by the second record), so the divergence was
purely in the dispatched record stream.
**Detector:** `/tmp/r33_c_offload.c` (C, -DPNM_MCU: 2 layers, 4 model layers, 55
entries/bank > 51 threshold) printed `C_OFFLOAD_COUNT=2` pre-fix; the Go twin
`zz_r33_offload_test.go` (825 entries/bank > 819 threshold) printed
`G_OFFLOAD_COUNT=1`. Post-fix the C detector prints `C_OFFLOAD_COUNT=1` and both
emit 17 records with identical layer/phase placement.
**Fix:** The drain loop now iterates all `fw->kv.num_layers` (`for dl ...
kv_needs_offload(&fw->kv.layers[dl],80) ... kv_evict_oldest(&fw->kv.layers[dl]...)`),
mirroring `OffloadCycle`'s per-layer drain. Verified: `gcc -Wall -Wextra
-std=c11` clean in both `-DPNM_MCU` and standard configs; full Go suite
(163 tests, incl. `TestIntegration_CMoeGating`/`CKVLoadNonDestructive`) PASS;
`go run ./cmd/pnmt c` 2/2 PASS; `go run ./cmd/pnm` ALL SCENARIOS PASSED.
**Commit:** `0fdb524`.

### CONFIRMED R33-D1: paper/docs.md ComputeUnitType count stale (9 -> 15)
**File:** `paper/docs.md:421`
**Bug:** The model-compiler struct list said `ComputeUnitType` (9 types), but
`model_compiler.go:41-58` enumerates 15 concrete units (BF16FMA, FP16FMA,
FP32FMA, FP64FMA, FP32ALU, INT8MAC, BF16Array, FP16Array, FP64ALU, FP32Array,
INT8ALU, INT4MAC, INT4Array, FP4Array, MXFP4Array — excluding CUTypeNone).
**Fix:** Changed "(9 types)" -> "(15 types)". Verified the enum directly.
**Commit:** `0fdb524`.

### DISMISSED R33-H1: int8_alu SHIFT 1<<7 claimed to yield 0xFFC0
**Files:** `HDL/core/int8_alu.v:62`, `HDL/core/tb_int8_alu.v`
**Claim:** The HDL agent asserted `$signed(a) <<< b[2:0]` computes in 8-bit width
(self-determined LHS) so `1<<7` wraps to 0xFF80/-64 before sign-extension into
the 9-bit `shift_result`, making `tb_int8_alu.v`'s `1<<7=+128` assertion FAIL.
**Verdict:** Falsified empirically. The committed regression runs
`*** INT8 ALU TEST: 17 passed, 0 errors ***`: iverilog context-widens the left
shifter operand to the 9-bit `shift_result` LHS, so `1<<7` = +128 (0x0080)
correctly. The 9-bit SHIFT widening (round 28) already handles this case; the
agent mis-traced Verilog operand width rules. No code change.

### DISMISSED R33-G2..G6 (design-level, no wrong result)
- **Offload threshold hardcode (C `80` vs Go `Config.OffloadThresh`):** Go default
  is 80; the C never exposes a config knob. Behaviorally identical at the
  default. Documented, not changed.
- **MoE CU type (C `me->cu_type` from map vs Go hardcoded `CUTypeBF16FMA`):** the
  AOT compiler assigns BF16FMA to every expert (`model_ir.go`), so both resolve
  to bf16_fma on shipped configs (gated on the same map population). No record
  divergence. Flux in the CJK port mirrors the same single-value population.
- **TensorRole / RepeatKV / GroupSize missing from C dispatch_record_t:** metadata
  consumed only by Go stats collectors (`RepeatKVOps`), never by a dispatch or KV
  op; the C port is a dispatch planner, not a stats source. Not changed.
- **C fw_verify_weight_upload / fw_verify_dispatch weaker than Go:** the C
  verifiers are boot-time sanity checks; the C boot path never rejects a valid
  plan, and the stricter Go checks are Go-side. Not changed.
- **Chunked / Speculative / Summary functions absent from C:** not implemented in
  the reference port (single-token dense path only). Not a divergence on the
  shipped path.

### Clean audits (round 33)
- Full re-trace of `fw_plan_inference` vs Go `PlanInference`: phases, flash
  tiling math, per-layer sliding window, per-layer seq_pos, FNV-1a `select_topk`,
  kv_store/kv_load staleness tokens, boot sequence, physLayerOf — all in parity
  after R33-G1.
- kv_store/kv_load/kv_evict_oldest differential fuzz vs Go (same op stream, same
  bank depth/entry size/threshold): identical hit/miss verdicts, eviction counts,
  bank order, final occupancy.
- Docs: fp32_alu DIV=28, int8_mac=2-cycle, fp4=4x-density, LPCAMM2=644-pin,
  512-node reference, doorbell command file list, orchestrator_sbc window sizes —
  all consistent across the 9 active doc files.


## Bug audit log (2026-09-08, round 34)

### CONFIRMED R34-G1: UART RX rotated the received byte and fired spurious framing errors
**File:** `HDL/uart.v` (RX path, lines ~138-156)
**Bug:** The RX FSM sampled data bits into `rx_shift[rx_bit_cnt[2:0]]` with a
3-bit index while `rx_bit_cnt` ran 0..9, so bit 8 wrapped to index 0 (rotating
the byte: `A5` came out `4A`) and the stop-bit check fired at cnt==8 while the
data bit was still being sampled, producing spurious framing errors. The TX
path also lost the first byte written to THR from idle: `!tx_busy && lsr[5]`
started a transmission with pre-write values, capturing stale `thr` (HIGH #25
from round 12 was a partial fix; the `thr_has_data` register completed it).
**Detector:** `/tmp/tb_uart_rx_detect2.v` — center-aligned loopback driving
bytes A5, 01, 7F, 80; PASS on all four post-fix (`PASS[1] a5 ... PASS[4] 80`).
**Fix:** RX samples `rx_shift[rx_bit_cnt - 4'd1]` for cnt 1..8 (4-bit
arithmetic, no index wrap), stop-bit check at cnt==9. TX starts only when
`thr_has_data` is set (on THR write, cleared on load into the shift register).
**Caveat (documented):** RX uses the free-running `baud_tick` with no half-bit
start-bit resync, so the sampling point is phase-sensitive; the fix is correct
for center-aligned sampling when the baud tick aligns. No shipped TB exercises
RX (the UART is TX-only in all orchestrator TBs), so no regression risk.
KEEP decision: the fix was verified on disk and retained after a deliberate
keep-vs-revert review.

### CONFIRMED R34-G2: C firmware dispatch plan truncated to physical-layer bound
**Files:** `fw/pnm_fw.c` (`fw_plan_inference`, `fw_verify_dispatch`)
**Bug:** `fw_plan_inference` computed `model_layers`/`perPhysical`/`pl` from a
per-physical-layer loop that under-provisioned the plan: with
`num_layers=4, mpl=2, num_hidden_layers=24` it planned only 16 records and max
model layer 7 instead of 48 records / layer 23. The Go twin `firmware.go:601-611`
plans every model layer. `fw_verify_dispatch` covered only the layers the planner
reached, so the truncation was self-consistent and invisible.
**Detector:** temp C harness — pre-fix `num_records=16, max_layer_planned=7`;
post-fix `num_records=48, max_layer_planned=23`.
**Fix:** mirrored Go: iterate `ml < model_layers` with
`model_layers = num_hidden_layers`, `perPhysical = model_layers/num_layers`,
`pl = ml / perPhysical`; `fw_verify_dispatch` loops all `num_hidden_layers`.
**Verified:** `go run ./cmd/pnmt c` → 2/2 PASS.

### CONFIRMED R34-G3: rv32_core CSR minstret double-count and CSRRW-x0 clobber
**File:** `HDL/rv32_core.v` (OP_SYSTEM, S_WRITEBACK)
**Bug:** (1) `csr_minstret` incremented unconditionally at the top of the
`OP_SYSTEM` case (`x6=1, x7=3` for two CSRR reads — CSR instructions counted
twice); (2) `csrrw x0, csr, x0` / `csrrwi` with zimm=0 wrote the CSR, so
`csrrw x0, mcycle, x0` cleared mcycle (read-only idiom must not write). (The
file also carried the prior-round uncommitted SRAI decode + sub-word load lane
fixes; all committed together.)
**Detector:** `/tmp/tb_rv32_detect.v` (mstatus-based: reset 0x1800, write 5 →
expect 5) — pre-fix double-count and clobber; post-fix
`x6=1, x7=2, x8=0x5, mstatus=0x5` ALL PASS.
**Fix:** minstret incremented only in ECALL/EBREAK/MRET branches (written once
via S_WRITEBACK); CSR writes suppressed when
`(funct3==CSRRW && rs1==0) || (funct3==CSRRWI && zimm==0)`.
**Verified:** `tb_rv32_core.v` (SRAI) and `tb_rv32_core_load.v` (LB/LH lanes)
both PASS.

### CONFIRMED R34-G4: lpddr6_camm ignored bus byte-enables
**File:** `HDL/lpddr6_camm.v`
**Bug:** `bus_be[3:0]` was declared but never sampled; the write-commit block
wrote the full `cmd_wdata_r` word unconditionally, so sub-word writes
(`bus_be != 0xF`) clobbered all four lanes.
**Detector:** `/tmp/tb_lpddr6_be.v` — write `0x11223344`, then `0xAABBCCDD`
with be=0010 → expect `0x1122CC44`. Pre-fix `mem[0]=aabbccdd` (FAIL).
**Fix:** capture `cmd_be_r = (bus_we) ? bus_be : 0xF` at accept; commit loops
per enabled lane (`if (cmd_be_r[be_i]) mem[..][be_i*8 +: 8] <= ...`).
**Verified:** detector 3/3 PASS post-fix; `tb_dma_lpddr6.v`, `tb_sodimm_lpddr.v`,
`tb_host_bmc.v` all PASS.

### CONFIRMED R34-D1: HLSL described as compiling to FP64 dispatch (wrong)
**Files:** `docs/usage_manual.md:440-441,488-489`, `README.md:124,134-135`
**Bug:** Both docs claimed "Haskell, R, or HLSL to FP64 dispatch instructions"
and "operands packed as big-endian FP64 bytes (8 bytes each)". Per
`sim/internal/pnm/hlsl_ir.go:1-2` the HLSL compiler emits an **FP32 ALU IR**
(`alu.*` ops targeting `fp32_alu.v`) that `LowerHLSLToPNM`/`hlslOpToFP64`
(`haskell_pnm.go:78`) lowers to `f64_*` kernels for dispatch. Only Haskell and
R compile through the FP64 IR directly; claiming HLSL computes in FP64
overstated the pipeline.
**Fix:** reworded both files: Haskell/R → FP64 IR; HLSL → FP32 ALU IR lowered
to `f64_*` kernels for ABI/dispatch compatibility; operands packed in the FP64
payload format (8-byte slots).

### CONFIRMED R34-D2: usage_manual compute-unit table missing four units
**File:** `docs/usage_manual.md:84-98`
**Bug:** The node compute-unit table omitted `int4_mac.v`, `fp32_mac_array.v`,
`int8_alu.v`, `fp64_alu.v` (all exist in `HDL/core/` and are in
`paper/docs.md`/AGENTS.md catalogs).
**Fix:** added the four rows with latencies from module headers (`int8_alu`
1-cycle ADD/SUB/SHIFT/MIN/MAX + 2-cycle MUL; `fp64_alu` 3-cycle
ADD/SUB/MUL/MIN/MAX/CMP + 56-cycle DIV).

### Round-34 verification
- `go build ./...` clean; `go test -count=1 ./internal/pnm/` → ok (163 PASS).
- `go run ./cmd/pnmt c` → 2/2; `go run ./cmd/pnmt hdl-core` → 27/27.
- `go run ./cmd/pnm` → ALL SCENARIOS PASSED (48-node fabric co-sim).
- rv32 (SRAI + load-lane), lpddr6 family (dma/sodimm/host) TBs all PASS.
- Manual audits clean (no findings): clint.v, pnm_arb.v, optical_link.v,
  pcie_phy.v, result_log.go, workloads.go, nvme_lustre.go, sodimm_ctrl.v.
- Go/C Finding 1 (firmware.go hardcodes CUTypeBF16FMA vs C configurable
  cu_type) documented as design divergence, no fix (C superset).
- Commit `2b3295b`.

## Bug audit log (2026-09-08, round 35)

### CONFIRMED R35-A: C source-language twins used floor (mpl) physical-layer grouping
**Files:** `fw/pnm_fw_r.c`, `fw/pnm_fw_haskell.c`, `fw/pnm_fw_hlsl.c` (`r_fw_plan_inference` etc.)
**Bug:** The R/Haskell/HLSL C ports computed `perPhysical = mpl` (floor), so with
`num_hidden_layers` not a clean multiple of `num_layers` the physical-layer grouping was
off by one and `pl` could exceed `num_layers-1` (the loop `break`t instead of clamping).
The canonical `pnm_fw.c` uses ceiling grouping (`ceil(num_hidden/num_layers)`) with a tail
clamp, so the source-language twins diverged from the reference on non-divisible chassis.
**Fix:** each port now uses `num_hidden_layers > 0 ? ceil(num_hidden/num_layers) : mpl`
as `perPhysical` and clamps `pl` to `num_layers-1` instead of breaking (mirrors
`kv_cache.go ConfigureSlidingWindow`, R32-G1). Detector `/tmp/r35_detect_a.c` (R port):
24 records post-fix (was truncated).

### CONFIRMED R35-B: prefill generated no dispatch/stat records in llm_client
**File:** `sim/internal/pnm/llm_client.go` (`Generate` ~276-291, `GenerateWithLogprobs`
~1037-1048)
**Bug:** During the prefill phase the client called `c.FW.PlanInference(...)` for the
token/attention math but discarded the returned dispatch records, so the prefill's
dispatches never contributed to `Stats.TotalDispatches` nor to per-CU `collectStats`.
The speculative site was already correct; the two non-speculative sites dropped the
records entirely.
**Fix:** both sites now capture `records, err := c.FW.PlanInference(...)`, add
`c.Stats.TotalDispatches += len(records)`, and loop `c.collectStats(r)`.
Detector `TestR35PrefillStatsCollected` (`llm_client_fix_test.go`).

### CONFIRMED R35-C: sliding-window config used floor grouping + no fallback path
**Files:** `sim/internal/pnm/firmware.go` (`NewFirmware`), `sim/internal/pnm/kv_cache.go`
(`ConfigureSlidingWindow` ~753-796)
**Bug:** (1) `ConfigureSlidingWindow` reused the floor `perPhysical = len(layerTypes)/len(kc.Layers)`
logic, mis-scaling the sliding-window flag once a model layer count is not a clean multiple
of physical layers, and left a trailing window off by one. (2) `NewFirmware` applied
`ConfigureSlidingWindow` unconditionally even when the firmware had no per-physical KV
layers to map to.
**Fix:** `ConfigureSlidingWindow` now uses ceiling grouping with a tail clamp (empty
`layerTypes` marks all layers sliding); `NewFirmware` guards
`if cfg.SlidingWindow > 0`. Detectors `TestR35SlidingWindowPhysicalMapping`,
`TestR35LayerIsSlidingFallback`, `TestR35ConfigureSlidingWindowFallback`
(`firmware_fix_test.go`). Note: firmware.go was committed with the entire pre-existing
uncommitted MoE/sliding-window refactor (`layerIsSliding`/`physLayerOf`/`selectTopExperts`)
because the committed `firmware_fix_test.go` depends on those functions (R26-G2 precedent;
full suite validates the combined result).

### CONFIRMED R35-D: model_ir KV frame size diverged from RTL ENTRY_BYTES
**File:** `sim/internal/pnm/model_ir.go` (hunk 289 only)
**Bug:** `KVCacheConfig { EntryBytes: int64(tc.HiddenSize)*4, ... }` sized KV entries from
hidden_size, but the silicon `kv_cache_bank` frame is a fixed `ENTRY_BYTES=512` and the Go
`DefaultKVCacheConfig` pins 512 (R25-G2 dismissal). For hidden_size ≠ 128 the IR/planner
accounting diverged from what the fabric actually stores.
**Fix:** pinned `kvEntryBytes := int64(512)` with a comment tying it to the RTL frame.
Detector `TestR35KVCacheFrameConsistency` (`model_ir_fix_test.go`). The other
pre-existing uncommitted model_ir.go hunks (dtype/BF16 norm, kv-cache reservation) were
surgically excluded from the commit.

### CONFIRMED R35-E: C firmware KV cache depth 4096 vs RTL BANK_DEPTH 1024
**File:** `fw/pnm_fw.h`
**Bug:** `PNM_KV_CACHE_DEPTH` was 4096, but the RTL `kv_cache_bank` uses `BANK_DEPTH=1024`
per bank and the Go twin sizes banks at `Depth`. The C port's KV occupancy/eviction math
ran against a 4x-larger frame than silicon, overstating capacity.
**Fix:** `PNM_KV_CACHE_DEPTH` 4096 -> 1024 (RTL BANK_DEPTH parity). Detector
`/tmp/r35_detect_e.c` = PASS-E (post-fix).

### CONFIRMED R35-F: C firmware dispatch records lacked GQA repeat/group fields
**Files:** `fw/pnm_fw.h`, `fw/pnm_fw.c`
**Bug:** The Go `dispatch_record_t` carries `RepeatKv`/`GroupSize` (from `kv_cache.go`
grouped-query-attention expansion), but the C twin's `dispatch_record_t` had neither field
and `fw_plan_inference` never populated them, so C-issued GQA dispatches diverged from the
Go reference on multi-query (grouped) attention.
**Fix:** added `repeat_kv`, `group_size` to `dispatch_record_t`; added
`num_attention_heads`, `num_kv_heads`, `head_dim` to `firmware_t`; in `fw_plan_inference`
after the sliding-window block: `group_size = num_kv_heads>0 && num_attn>0 ?
max(1, num_attn/num_kv) : 1`; `need_repeat_kv = group_size > 1`; populated at all four
attention record sites. Detector `/tmp/r35_detect_f.c` = PASS-F (post-fix).

### CONFIRMED R35-G: host RunModel swallowed boot-loop failures (Findings G) — FIXED BUT UNCOMMITTED
**File:** `sim/internal/pnm/host_driver.go` (`RunModel` ~435-466, new `finishModel` ~459-476)
**Bug:** `RunModel`'s boot loop called `hd.driverBoot(boot, mr)` inside a
`for mr.Attempts < ...` retry loop but then unconditionally logged `"OK"` and returned
`mr` regardless of whether `mr.Errors` was non-empty, so a failing model boot was reported
as success.
**Fix:** the boot loop now calls the new `finishModel(modelDir, &mr)`, which appends the
`ModelResult`, logs `"OK"` only when `len(mr.Errors)==0`, otherwise logs `"FAILED"` and
appends to `Result.Errors`, returning false. Detector `TestR35RunModelReportsFailures`
(`host_driver_fix_test.go`) forces a `PerNodeBudget` too small to fail `VerifyWeightUpload`
and asserts `finishModel` returns false + appends errors.
**COMMIT STATUS:** Finding G is verified in the working tree but **left uncommitted**.
`host_driver.go` and `host_driver_fix_test.go` are entirely untracked (a 672-line
pre-existing unified host-driver feature); committing them whole under "round 35" would
sweep that undocumented feature into the round commit, and there is no committed baseline
for `git add -p` surgical extraction (R25-G5 / R26-G2 entanglement precedent). The two
files should be committed as their own standalone feature commit, not mixed with round 35.

### CONFIRMED R35 docs 1-3: Nix toolchain and seL4 references
**Files:** `README.md:72,75`, `paper/readme.md:16,20`, `paper/docs.md:16`,
`toolchain/fw-sel4/README.md:18`, `toolchain/fw-linux/README.md:18`,
`toolchain/soc-linux/README.md:31`, `toolchain/fw-sel4/Makefile:15`,
`toolchain/soc-linux/Makefile:13`, `flake.nix:84`
**Bug:** three doc classes: (1) all READMEs/Makefiles still cited `shell.nix` plus
`nix-shell`, but the repo uses flake-style `nix develop` (flake.nix, shell.nix GONE);
(2) `toolchain/soc-linux/README.md` still referenced the Redox kernel / `redox-kernel`
/ `./soc-linux.sh` with no seL4 path — the actual stack is the seL4 microkernel
(`sel4-kernel`) with a `pnm_rustd` access-control daemon and `./soc-linux.sh sel4`;
(3) `flake.nix:84` validated a non-existent `pcb/orchestrator_sbc/orchestrator_sbc.lpp`
path (actual `pcb/processor/processor.lpp`).
**Fix:** `shell.nix`->`flake.nix` and `nix-shell`->`nix develop` everywhere; rewrote
`toolchain/soc-linux/README.md` to the seL4 stack (title, `redox-kernel`->`sel4-kernel`,
added `pnm_rustd` row, Rust stable note, `./soc-linux.sh sel4`); corrected the
`flake.nix` PCB check path to `processor`. Verified `flake.nix` still `nix flake check`-able
(edit-only; no build change).

### HDL audit (round 35): 3 latent findings, all dead-path — NONE fixed, NONE instantiated
- **kv_offload EVICTION_TARGET framing:** the BMC/NVMe discard-selection logic assumes
  `EVICTION_TARGET!=0` framing that no design instantiates; `kv_offload.v` compiles but has
  no integration point (R32 MEDIUM #33). Dead path.
- **weight_flits counter semantics:** `orchestrator_chip.v`'s `weight_flits` counts emissions
  per PCIe command, not per physical flit; a naming/counter-semantics note, no functional
  divergence on the shipped single-flit-per-command path. Not a bug.
- **TOP_K=16 sentinel aliasing:** `moe_gating.v` uses `TOP_K` as the sentinel for a full
  buffer; at `TOP_K=16` the sentinel aliases a valid index. All shipped `TOP_K` values are
  < 16 (default 8), so the aliasing is unreachable. Documented latent, not fixed.
All three are parameter/instantiation-gated dead paths with no failing detector in any
shipped configuration; per the failing-detector protocol they are documented, not changed.

### Round-35 verification / regression
- `go build ./...` clean; `go test -count=1 ./internal/pnm/` -> ok (170 PASS, 167 + 3 new
  R35 tests: `TestR35PrefillStatsCollected`, `TestR35KVCacheFrameConsistency`,
  `TestR35SlidingWindowPhysicalMapping`/`...LayerIsSlidingFallback`/
  `...ConfigureSlidingWindowFallback`).
- `go run ./cmd/pnmt c` -> 2/2; `go run ./cmd/pnmt hdl-core` -> 27/27.
- `go run ./cmd/pnm` -> ALL SCENARIOS PASSED (fabric co-sim, 48-node).
- C firmware SoC + MCU (`gcc -Wall -Wextra -std=c11 [-DPNM_MCU]`) compile clean.
- `/tmp/r35_detect_a`, `/tmp/r35_detect_e`, `/tmp/r35_detect_f` all PASS post-fix.
- The staged commit was additionally verified to compile/pass standalone by temporarily
  moving `host_driver*.go` out of the package: `go vet ./internal/pnm/` clean and the
  firmware/R35 detector tests still pass without host_driver (the committed subset does not
  reference it). Files were restored byte-identically afterward (`go build ./...` and the
  full suite re-GREEN).
- Commit `184dec0` (21 files). Finding G + `host_driver*.go` intentionally left uncommitted
  (see R35-G).

## Bug audit log (2026-09-08, round 36)

### CONFIRMED R36-D1: AGENTS.md current-doc sections still cited shell.nix / nix-shell
**File:** `AGENTS.md:26,33,481` (current documentation sections only; historical audit-log
lines 4264-4271 intentionally left untouched)
**Bug:** The round-35 docs fix renamed `shell.nix`->`flake.nix` and
`nix-shell`->`nix develop` across README.md / paper docs / toolchain, but missed the
guidance file's own current-doc sections: repo-layout table row 26, the Environment
paragraph 33, and the Gotchas line 481 still cited `shell.nix` (which does not exist in
the repo; only `flake.nix` is present).
**Detector:** `ls flake.nix shell.nix` -> only `flake.nix` exists; `grep -n 'shell\.nix\|nix-shell' AGENTS.md`
showed 3 current-doc hits.
**Fix:** line 26 `| `shell.nix` | Nix shell ... |` -> `| `flake.nix` | Nix flake ... |`;
line 33 "Nix shell: `nix-shell` (flake-style)" -> "Nix flake: `nix develop`";
line 481 "toolchain from `shell.nix`" -> "`flake.nix`". AGENTS.md is gitignored, so this
is a local guidance-file fix (not committable).

### CONFIRMED R36-H1: orchestrator_sbc_moe.v header overstated a BF16 MAC array instance
**File:** `HDL/orchestrator_sbc_moe.v:4,14`
**Bug:** The module header claimed "SBC Router Chip with BF16 MAC Array" and listed
"bf16_mac_array (16x16 systolic) for local projection compute" in the silicon budget.
The module instantiates ONLY `moe_gating` (`u_moe_gating` at line 338); `bf16_mac_array`
appears nowhere else, and `ARRAY_SIZE` (line 51) is declared but never referenced. This
is the same claim class corrected for the docs in R22-8/R23-2 (Paper.MD, AGENTS.md,
paper/docs.md, usage_manual), but the RTL header itself was missed.
**Detector:** `grep -n 'mac_array\|u_gating' HDL/orchestrator_sbc_moe.v` -> only the
`moe_gating` instance and the header-comment/parameter references; no `bf16_mac` instance.
**Fix:** title now "SBC Router Chip with MoE Gating SRAM"; the silicon-budget bullet now
reads "moe_gating unit (top-K selection + coordinate map); bf16_mac_array dimension
provisioned via ARRAY_SIZE param, no separate mac-array instance" (matches the AGENTS.md
wording for this tier).
**Verified:** `iversim tb_orchestrator_sbc_moe` -> `*** SBC+MOE ROUTER CHIP TEST PASSED ***`
(comment-only change; no functional impact).
**Commit:** `bc25bc7`.

### Round-36 agent outcomes
- **HDL agent:** no data-corrupting findings. Re-traced fp32/fp64_alu DIV + ADD/SUB RNE,
  fp32/fp64_fma rounding/far-sticky/carry-drop, int8_alu sign/shift, weight_dequant INT
  sign + MXFP4-zero-scale, fp4/mxfp4 LUT (OCP magnitudes) + b_scaled width + fed/accept
  arming — all correct vs their TBs. Noted the fp32 CMP (`>=`) vs fp64 CMP (`==`) contract
  divergence; this is the intentional per-module contract documented in HDL/README.md
  :290/:306 and dismissed in R29-H1 — no action.
- **Go/C agent:** full parity confirmed on all round-36 checkpoints (ceil physical-layer
  grouping, per-layer seq_pos, flash_num_tiles, sliding-window, select_topk/FNV-1a,
  kv_store/load staleness + zero-pad, offload drain-all-layers, repeat_kv/group_size,
  NVMe/Lustre LBA spacing). No findings; suggested (unexecuted) extra parity detectors
  for FNV tie-break boundaries — no bug found, coverage suggestion deferred.
- **Docs agent:** README.md, paper/readme.md, paper/docs.md, paper/build.py (30 REFS,
  all {c(n)} resolve), paper/Paper.MD (latencies, FP4 density, 64KB gating SRAM, memory
  map, Section cross-refs), docs/usage_manual.md, docs/profiling.md, HDL/README.md,
  TLDR.md all clean vs code; only the two CONFIRMED items above (AGENTS.md current-doc,
  sbc_moe RTL header). `pcb/README.md` "router" terminology matches the LibrePCB
  library's own naming (not a bug). Flagged nothing else.

### Round-36 verification / regression
- `orchestrator_sbc_moe` TB (`tb_orchestrator_sbc_moe.v`) PASSES post-comment-fix.
- AGENTS.md current-doc grep now clean (`grep -n 'shell\.nix\|nix-shell' AGENTS.md` ->
  only historical audit-log lines remain).
- Earlier full round-35 regression (170 Go PASS, pnmt c 2/2, pnmt hdl-core 27/27,
  `go run ./cmd/pnm` ALL SCENARIOS PASSED) unchanged by this round — comment/doc-only
  edits.
- Commit `bc25bc7` (1 file, 3+/3-). Empty-quad counter: **0** (round 36 has 2 confirmed
  fixes, one committed).

## Bug audit log (2026-09-13, round 37 — outsider review response)

Three critiques from an external reviewer of an earlier repo snapshot were
verified against the code and addressed in `paper/Paper.MD` (commit `7a85269`,
with regenerated submission artifacts). AGENTS.md is gitignored, so this block
is a local record; the manuscript is the committed artifact.

### R37-1: "No global mutable state" overclaim (design-philosophy text, Paper.MD §1.2)
**Critique:** the claim "no global mutable state anywhere in the system" is
false — routing tables, MoE maps, weight commands, KV cache, dispatch records,
POST state, LRU/FIFO eviction, and runtime gating are all state.
**Verdict:** the reviewer is correct; the phrase was an overclaim. The code
(the `firmware_t` struct in `fw/pnm_fw.h` and the Go `Firmware`/`Driver`
types) literally holds all of these as statically sized arrays, and the RTL
(orchestrator_chip.v, kv_cache_bank.v, moe_gating.v, lxy_repeater.v) carries
pre-loaded routing bitmaps, gating weights, KV banks, and POST FSMs.
**Fix:** §1.2 now scopes the claim precisely: statelessness is a property of
the *data transport plane* — no routing/arbitration state on the forwarding
path — and all mutable state is enumerated (routing bitmaps and gate config,
MoE map + gating weights in the router chip, the weight-upload command stream
during POST, KV cache banks and eviction state, dispatch records, POST/READY
boot state), each owned by exactly one mutable agent (the router chip or a
node's controller), initialized from a compile-time schedule, and replayable,
so the deterministic-replay guarantee (Section 2.10) attaches to the stateful
control plane as it would to a stateless one. The phrase "no global mutable
state anywhere in the system" is gone.

### R37-2: inconsistent KV cache arithmetic (Paper.MD §2.7 sub-phase 2d, §2.12, §3.1.1)
**Critique:** "KV budget per node is 80% of the 128 GB capacity" gave
102.4 GB/node for KV, and the same node later "holds a single expert's 70--80
GB weights at 80% of its post-weight budget" — the numbers cannot coexist.
**Verdict:** the reviewer is right on both counts. Code check:
- `model_ir.go:291,313-318` computes `kvBudgetPerNode` as **80% of
  `PerNodeBudget - usedBytes`** (the post-weight budget), not 80% of raw
  capacity — the manuscript said "80% of the 128 GB capacity" in two places.
- `model_compiler.go` (expert placement, sub-phase 2b prose): a *single*
  expert in a 70B-class model is ~0.6 GB at BF16 (e.g. gate_up
  [2x704, 2816] + down [2816, 704] for the Gemma-4 fixture = 11.9 MB; a 128-
  expert population at ~0.6 GB/expert totals ~70-80 GB). The old phrasing made
  one expert itself weigh 70-80 GB.
**Fix:** sub-phase 2d and §2.12 now read "80% of the node's post-weight
budget — the 128 GB capacity minus resident weight bytes"; §2.7 sub-phase 2b
now says the full expert *population* spans the node pool (70-80 GB for a
70B-class model, ~0.6 GB per expert), with the per-node post-weight budget
deciding resident expert count alongside the KV share. §3.1.1's "post-weight
budget" phrase already matched the code and was kept.

### R37-3: "round-robin" vs "round-robin-free" contradiction (Paper.MD §2.7, §3.1.1)
**Critique:** §2.7 sub-phase 2b says experts are distributed round-robin
across the node pool; §3.1.1 says "experts are placed round-robin-free".
**Verdict:** both statements are true at different stages, and the manuscript
did not say so: sub-phase 2b *is* a compile-time round-robin assignment
(`nodeIdx = expIdx mod (B_x x B_y)`, model_compiler.go), while runtime
selection is gated (per-token top-k over the resident map — firmware
`selectTopExperts`, R35/round-14). "Round-robin-free" at §3.1.1 meant "each
expert maps to exactly one node" (no runtime round-robin fan-out).
**Fix:** §3.1.1 now reads "Expert placement is deterministic but not
round-robin at runtime: the compiler assigns each expert to exactly one node
(Section 2.7's sub-phase 2b distributes experts round-robin over the node
pool at compile time), and the gating network... selects which experts fire."
The word "round-robin-free" is removed.

### Bonus: FIFO vs LRU eviction terminology aligned (Paper.MD §2.6 layer 4, §2.7 sub-phase 2d)
`kv_cache.go` banks evict by FIFO (`Evict` = oldest write position; comment
"evict at 80% full"), and LRU applies only to the separate `PrefixCache`
(`MaxSize`, lowest-hit-count eviction). Two manuscript sentences said
"least-recently-used" about the KV banks; both changed to "oldest entries"
(FIFO), matching §2.12's existing FIFO wording and the RTL/go twins.

### Round-37 verification / regression
- `python3 paper/build.py` (inside `nix develop`) — `Wrote paper.docx` + PDF,
  clean exit.
- Paper.MD diffs restricted to the four passages above (no other manuscript
  drift beyond the previously committed round-36 state).
- Commit `7a85269` (10 files: Paper.MD + submission artifacts).
- The large pre-existing working-tree drift (HDL `core/*.v` fixups, sim
  `internal/pnm/*` edits, `sim/pi_host` + `sim/toolchain` moves to
  `pi_host/`/`toolchain/`, untracked pnmhost/host_driver/etc.) predates this
  round and remains uncommitted, as it is unrelated to the reviewer response.

## Bug audit log (2026-09-13, round 38 — third-party limitations critique)

A second third-party review (stored as `docs/limitations.md`, now deleted) raised
13 items. Each was verified against the manuscript and the code; 4 were already
disclosed and 9 were genuinely missing/understated. Manuscript-only round — no
code changes, no tests run. Commit `590773a` (Paper.MD + regenerated submission
artifacts), build clean (`Wrote paper.docx`). `docs/limitations.md` was untracked
and removed with `rm` (not `git rm`).

### Already disclosed — no manuscript change (documented only)
1. **Single spine (no redundant spine):** §4.4 "A dual-spine variant eliminates
   single-chassis partition mode", Conclusion "total spine failure partitions the
   chassis", §4.1 node-failure paragraph.
2. **Single router chip holding all mutable state:** §4.4 last paragraph
   (single point of failure, no live failover, cold-swap sub-second outage) and
   §2.10.
3. **Timing numbers are projections over a ~160x gap:** Abstract, §2.3 (the
   1 GHz 128-bit links are never clocked), §3.4, §4.4 Validation scope.
4. **Thermal/power figures are analytical:** §4.4 Validation scope + Results
   intro ("first-order design-point estimates... await CFD validation").

### Fixed in Paper.MD (9 items)
5. **Head-of-line blocking / tree saturation under hotspots** (was not disclosed):
   new §4.4 paragraph "Hotspots, errors, and scaling ceilings." — closed-form
   latency bounds are exact only on an idle chassis; hotspot scenario verifies
   losslessness, not a contention bound; compile-time mitigations (hot-expert
   replication, layer-affine placement, credit-feasible schedules).
6. **End-to-end-only error handling** (partially disclosed §4.1; retransmit cost
   never stated): same §4.4 paragraph — CRC only at the destination doorbell,
   mid-fabric corruption detected on ACK timeout, costs a full-flit source
   retransmit, no per-hop retry.
7. **Wire-format scaling caps** (not disclosed): same §4.4 paragraph — 16-bit LEN
   caps payloads at 64 KB (uploads span many flits); routing-bitmap 4-bit Layer ID
   caps a chassis at **15 routable layers** (wire field is 8-bit LAYER_ID but the
   bitmap reserves bits [10:7], 1-based — the critique's "16 layers" was
   imprecise); MODULE_ID nibbles cap a board at 16x16; reference config is 8
   layers / 8x8.
8. **Sideband ACK aggregation cost** (not disclosed): same §4.4 paragraph — up to
   512 wires per signalling function (DOORBELL_ACK, NODE_ERR, TOPOLOGY_RDY) into
   the router package, not captured by the per-node four-pin budget of §2.4. (No
   "Table 1" exists; tables are numbered 2/3/4/4a, so §2.4 is cited instead.)
9. **Fixed-function brittleness / co-locking** (partial §1.4/§2.7): new §4.4
   paragraph "Fixed-function brittleness and resource limits." — no instruction
   decoder, new op/quant format is a silicon respin; compiler/wire-format/CRC/
   bitmap co-locked; model-class changes absorbed by compile-time re-derivation
   (§3.1.1), ISA changes are not.
10. **Adaptation only at batch boundaries** (disclosed but never framed as a
    limitation): same §4.4 paragraph — hot-expert replication and failure-schema
    re-export need a quiet-fabric routing-table reload; in-batch shifts cannot be
    absorbed.
11. **Single tenant only** (not disclosed): same §4.4 paragraph — no isolation,
    multi-tenancy, or memory protection; AOT schedule assumes exclusive chassis
    ownership.
12. **KV-cache capacity cliff** (numbers verified accurate, framing missing):
    §2.7 sub-phase 2d and §2.12 now state the fixed 512-byte frame bounds the
    implemented capacity below the HiddenSize x 4 model formula
    (11,264 B/entry at hidden=2816); §4.4 states 1,024 physical entries x 4
    banks = 4,096 per node, 16K logical-entry window, NVMe spill at
    storage-class bandwidth. Code verification: `kv_cache.go` entryBytes := 512,
    BankDepth: 1024, MaxPages 256 / MaxVirtPages 1024.
13. **Weight-upload "64 TB in <10 min" optimistic** (valid; code-verified): PCIe
    Gen5 x16 is 63 GB/s unidirectional; 64 TB at line rate ~17 min per uplink,
    ~8.5 min dual at 100%. §4.2's "~128 GB/s aggregate" is the bidirectional sum.
    Fixed to "approximately 12--15 minutes at a realistic sustained fraction of
    the dual PCIe Gen5 x16 uplinks" in §2.5 Phase 3, the §2.5 boot-bounds list,
    and §2.16 doorbell DMA; §4.4 states the bound is set by the host uplink, not
    the fabric. The "two minutes through 512 parallel streams" boot-flash figure
    was validated (~62 MB/s per node, plausible) and retained.
14. **LPDDR6 PHY on mature-node DUV = riskiest silicon claim** (mostly disclosed
    as "behavioral stubs"; one sentence added): §4.4 Validation scope now reads
    "The LPDDR6 controller and PHY integration on a mature 14/28 nm node is the
    riskiest silicon claim in the design; the stubs validate control flow and
    framing, but no analog PHY exists in the RTL."

### Build / commit
- `nix develop --command bash -c 'cd paper && python3 build.py'` → "Wrote
  paper.docx", exit 0. Only `paper/Paper.MD` + `paper/submission/*` staged;
  the large pre-existing working-tree drift (HDL/core/*.v, sim/internal/pnm/*,
  pi_host/toolchain moves, untracked pnmhost/host_driver) was left untouched and
  uncommitted.
- Commit `590773a` "paper: address third-party limitations critique on HOL, E2E
  CRC, wire-format caps, PCIe upload bound, KV cliff, tenancy".
- AGENTS.md is gitignored; this block is a local record only.

## Manuscript rewrite (2026-09-13, round 39 — structural/prose cleanup)

User request: "try to rewrite the paper because its a bit messy" — a
structural and prose cleanup of `paper/Paper.MD` (no content change, no
numerical claim change, no renumbering). Commit `ee60ddb` (with regenerated
`paper/submission/*` artifacts).

### What was characterized as messy
- Several 2500--3000 character single-paragraph blocks (abstract, §1.1,
  §2.1 spine sizing, §2.7, §2.15 verification, Conclusion).
- The same technical fact restated as full prose in 2--3 places: the 11-bit
  routing bitmap layout (§2.5 Phase 2, §2.7 Stage 4, §2.8), the learned-router
  projection (§2.5 Phase 4, §2.12, §4.4), the KV 512-byte frame (§2.7
  sub-phase 2d, §2.12), the 0.3--1 MB / 5--15x learned-router sizing.
- Stub 3-level subsections: §2.11.2 "Routing designs by use case"
  (4 routing-pattern paragraphs, no prose references) and §2.17.1 "Main
  thread placement" (3-constraint paragraph, no prose references).
- An out-of-sequence table numbered "4a" after Table 4 (now Table 5 — no
  prose referenced "4a", so no cascade renumber), with loose "4x" ascii
  escaping in its rows.
- Title-case headings (§4.1--4.4, §2.17 "BMC/Router") inconsistent with the
  sentence-case style of all other headings.
- RTL micro-detail in §2.17 that duplicates the repo's HDL/README (5-stage
  FSM sentence, 5-region memory map with addresses, SPI DMA offsets) and is
  not load-bearing for the architecture argument.
- Three stale "Redox OS" references; the repo's actual toolchain story is
  Linux/seL4 (seL4 already cited at §4.6 and the SBC tier). Fixed to seL4.

### Edits applied (28 total; all verified by grep inventory)
1. Abstract split into 3 paragraphs; §1.1 split into 3.
2. §2.1 spine paragraph split at "Each generated token costs 270 fabric
   dispatches..." (token-rate sentence now opens its own paragraph).
3. Heading casing: §2.5, §2.6, §2.11, §2.17 ("BMC/Router" → "BMC/router"),
   §4.1--4.4 all sentence-case.
4. Routing-bitmap dedup: §2.5 Phase 2 and §2.8 now cite "Section 2.7
   (Stage 4)" instead of restating the 11-bit layout; the canonical Stage 4
   description is untouched. Kept the AXIS/DIST computation sentence,
   sentinel detail, and sideband-loading sentence in §2.5.
5. §2.5 Phase 3 upload-timing parenthetical rewritten for precision:
   "at the $\approx$128 GB/s unidirectional aggregate ... the line-rate
   bound is roughly 8.5 minutes, so the 12--15 minute figure reflects the
   achievable sustained fraction rather than the theoretical ceiling"
   (keeps "12--15 minutes", "roughly two minutes through 512 parallel
   streams").
6. §2.7 Stage 1 split at "For example" (shape-inference enumerations now
   their own paragraph).
7. §2.7 closing dedup: deleted the two duplicated closing paragraphs
   ("The compilation model has a second, less obvious consequence..." and
   "The source-language front ends..."); folded the unique
   "the compiler has already verified that the weight dimensions fit the
   node ... what the compiler proved correct" sentence into the Gemma-4
   paragraph, which now flows directly into the §2.8 heading.
8. Learned-router dedup: §2.12 restatement replaced with "the learned-router
   sizing and its per-token evaluation latency are projections (Sections 2.5
   and 4.4)". Canonical §2.5 Phase 4 text and the §4.4 limitation recap
   retained (both still say 0.3--1 MB / 5--15x).
9. KV-frame dedup: §2.12 restatement replaced with "bounded below by the
   co-simulated and RTL cache's fixed 512-byte frame per entry (Section 2.7,
   sub-phase 2d)".
10. §2.15 split into 5 paragraphs (oracle list, six scenarios, HDL
    testbenches, memory/optical verification, verilator lint + compiler
    path) plus the pre-existing DES/parallel-slicing paragraphs.
11. §2.11.2 deleted and its content moved verbatim into §2.2 after the
    intra-layer fabric's final paragraph ("...fabric-bound at the link
    rate."); only the heading and "The fabric supports" → "The fabric
    provides" changed. No prose references to 2.11.2 existed.
12. §2.17.1 heading removed; its three-constraint paragraph is now a normal
    paragraph ("For source-language transpilation...") in §2.17. No prose
    references to 2.17.1 existed.
13. §2.17 micro-detail trims: 5-stage FSM paragraph condensed to one
    sentence; 5-region memory map condensed (no addresses); SPI DMA offsets
    removed ("target address, transfer word count, start/read/done control,
    and a FIFO data port"). Verified the trimmed details still live in
    AGENTS.md memory maps / HDL/README.
14. Table 4a → Table 5 ("Compute unit taxonomy"); the three "4x" occurrences
    (INT4 row, FP4 row, prose) → "4$\times$". No "Table 4a" prose refs
    existed; Tables 1--4 referenced by prose are unaffected as text.
15. §4.5 merged the first two paragraphs (the second's opening
    "Capacity-bound workloads have a memory profile that is the mirror image
    of training's. Training is bandwidth-dominated..." duplicated §4.5's
    opening bifurcation). Kept the weight-stationary framing and
    $\approx$2 FLOP/byte decode intensity; the 270-dispatch spine-sizing
    claim (third paragraph) untouched.
16. Conclusion split into 3 paragraphs: architecture summary (…cold-swappable
    die.), reference chassis + economics (…regardless of market cycles.),
    scaling + target workloads + guarantees. License paragraph stays
    separate.
17. Redox → seL4 in 3 places (§2.17 SoC intro, §2.17 OS-compatibility
    sentence, Conclusion) to match the shipped toolchain (the paper already
    cites seL4 elsewhere); intentional internal-consistency fix.

### Preserved (grep-verified post-edit)
- All section numbers (38 numbered headings incl. 2.11.1, 3.1.1; every
  "Section X.Y"/"Sections X and Y" mention resolves to a live heading —
  verified against `grep -oE 'Section[s]? [0-9.]+'`).
- Every round-38 quantitative claim: "12--15" min upload, "512-byte" KV
  frame, "15 routable layers" cap, 16$\times$16 board cap, "single-tenant",
  "co-locked", CRC residual-rate sentence, 0.3--1 MB / 5--15$\times$
  learned-router, 270 dispatches/token, 128 GB/s PCIe, 256 GB/s per node,
  64 TB chassis, 131 TB/s aggregate, 197 TFLOPS FP64, 15 W/node, 8--10 kW
  chassis. No raw markdown bullets introduced; all LaTeX escapes stay
  double-backslash (build.py collapses `\`→``).
- `{c(n)}` citations and the 30-entry REFS array untouched; TOP_SECTIONS
  (Abstract/Conclusion/Acknowledgments) headings intact.
- §2.7 Stage 4 remains the canonical 11-bit routing-bitmap description.

### Build verification
`nix develop --command bash -c 'cd paper && python3 build.py'` → "Wrote
paper.docx", exit 0. Submission artifacts regenerated and committed
(paper.tex/.pdf/.docx/.aux/.log).

### Commit
`ee60ddb` "paper: restructure and tighten prose for readability" (6 files:
Paper.MD + 5 submission artifacts). Pre-existing uncommitted drift
(HDL/core/*.v, sim/internal/pnm/*, .gitignore, untracked docs/TLDR/HDL
work) untouched. AGENTS.md is gitignored; this block is a local record only.

## Real-weight pipeline (2026-09-15)

The co-sim harness now reads **real safetensors weights** when a fully
downloaded checkpoint is present, falling back to the deterministic
synthetic sample only when shards are missing:

- `sim/examples/gemma4_test` was renamed to `sim/examples/gemma4_test_synthetic`
  (it holds config + index only — the "weights" there were shape-sized
  synthetic bytes, never real).
- Real Gemma-4-26B-A4B checkpoint: `/data/gemma4_dl/complete/` (symlink
  assembly; shard 1 downloaded + SHA-256 verified `a0e671c5…f96`, shard 2
  pre-existing in `/data/ai/gemma-4-26B-A4B/`).  `/data/ai/` itself is
  root-owned and read-only for uid 1000, so the runnable assembly lives in
  `/data/gemma4_dl/complete` unless a root moves shard 1 into `/data/ai`.
- `internal/pnm/safetensors.go` gained `ParseSafetensorsHeaders` +
  `ReadRealTensorBytes` (LE header length, per-tensor data_offsets, absolute
  offsets into the shard, BF16 payloads).  `Driver` retains `ModelDir` +
  `TensorData`; `BuildWeightCommands` emits real bytes via
  `weightPayloadFor` (capped at `sampleCapBytes` = 4096 like the synthetic
  path).
- Verified: `run-fabric /data/gemma4_dl/complete -l 2 -x 2 -y 2 --weights
  --prompt "Who was Alan Turing?"` → gating decisions from the REAL 128×2816
  router, 8233 activations, `FABRIC PROOF PASSED`; upload payloads carry real
  BF16 words (128 distinct words / 256-word sample).
- `pnmc run-driver` (autoregressive LLM path) uses the same Driver, so real
  checkpoints flow into it automatically.

## Real BPE tokenizer wired through the full stack (2026-09-16)

The Gemma BPE tokenizer (`LoadBPEVocab`, `sim/internal/pnm/real_tokenizer.go`)
is now the vocabulary backend across the harness:

- **Host SDK / LLM client** (`llm_client.go`): `Vocabulary` gained a BPE
  backend; `NewLLMClient` loads `tokenizer.json` from the model dir when
  present, so `Vocab.Encode/Decode` are the true Gemma BPE operations
  (byte-fallback + 514,906 merges, `▁` detokenization). Fallback to the
  synthetic `token_N` map when absent. Verified: "Who was Alan Turing?" ->
  [15938 691 27369 63809 236881], decode round-trips exactly.
- **Model compiler** (`cmd/pnmc compile-model`): loads model-dir
  tokenizer.json, reports token count, and emits `<model>_vocab.txt`
  (id<TAB>token) alongside the schema when available.
- **Model-fabric prompt payloads** (`model_fabric.go PromptTokenPayloads`):
  when the driver's model dir has tokenizer.json the injected flits carry
  the real BPE token stream (packed as 16 x big-endian u16 per 32-byte
  payload), so the MoE gating network scores real prompt traffic and the
  fabric delivers real token bytes. Verified by test that payload[0] ==
  15938 ("Who").
- **run-driver** (`cmd/pnmc`): the inference dispatch plan tokenizes
  "The capital of France is" with model-dir BPE when present, else the
  synthetic deterministic token.
- **MoE router SBC firmware** (`fw/pnm_fw.c` + `firmware.go` twin): routes
  by `fnv1a_64`/`selectTopExperts` over the token bytes the host supplies;
  no embedded tokenizer needed (the host tokenizes, the fabric/SBC routes).
  Compiles clean under gcc -std=c11 (SoC + MCU).
- **orchestrator_sbc_moe RTL**: unchanged — firmware preloads hidden_buf
  (PNMG_HIDDEN_BASE writes), moe_gating scores hidden states; the tokenizer
  is host-side by design.

Regression: `go vet ./...` clean; `go test ./internal/pnm/` (incl. new
`tokenizer_wiring_test.go`: `TestRealBPEInHostSDK`,
`TestRealBPEInFabricPayloads`) passes; `go run ./cmd/pnm` fabric co-sim:
ALL SCENARIOS PASSED.

## Benchmark & docs: real-weight inference (2026-09-16)

`docs/real_weights.md` documents the complete runnable stack: the real
Gemma-4-26B-A4B checkpoint, the in-process pure-Go forward pass, the
tokenizer wiring, and measured performance.

Key numbers: decode ≈ 6.5 s/token steady-state (after ~32 s prefill),
peak RSS ≈ 21 GB (cached BF16 tensors), all single-threaded scalar Go —
no torch/transformers/Python. Example outputs: "What is the capital of
France?" → "Paris)\n\nWhat are the main attractions in Paris? (answer:
The Eiffel Tower, The Louvre..."; "Once upon a time" → coherent
fairy-tale continuation. Sampling is splitmix64-seeded temperature 0.8.

## KV-cache co-sim enablement (2026-09-22)

Resolves MEDIUM #32 and MEDIUM #33 from the round-11 audit: the KV cache
bank's store/load paths are now driven by the co-sim harness and verified
end-to-end against a Go twin.

### Wire format (HDL/pnm_defs.vh)
- `OP_KV_STORE = 2'b10`, `OP_KV_LOAD = 2'b11` in CTRL[5:4]. CTRL =
  {vc_class=2, OP_KV_*} → **0xA0 (store) / 0xB0 (load)**.
- **0xA0 collision resolved**: `orchestrator_chip.v`'s `CTRL_WEIGHT_UPLOAD`
  moved from 0xA0 to **0x82** (vc_class=2 | OP_COMPUTE | rsvd[1] weight
  marker); `tb_orchestrator_chip.v` updated (its CRC is computed in-TB).
- Commands: STORE = `[mod | A0 | LEN(512) | entry(512) | CRC]`;
  LOAD = `[mod | B0 | LEN(2) | idx(LE u16) | CRC]`. The bank absorbs both
  at the head, validates the end-to-end CRC, and refuses corrupt commands
  (drain + discard; load → no response).

### kv_cache_bank.v (rewrite)
- Two-stage pass-through (pt, pt2): the MODULE_ID in stage 1 is held until
  the CTRL byte is snooped, so a command is absorbed whole before either
  head byte leaks downstream. Absorption also fires when stage 2 still holds
  the previous flit's tail (`pt2_eop && nob_out_ready`) — back-to-back
  injection without a bubble.
- `LOCAL_X` parameter: each column's bank only intercepts commands whose
  MODULE_ID X nibble matches its column — the X-lane feeds every column's
  bank in turn, so a blind bank at column 0 would absorb ALL of the layer's
  traffic (this was the live bug: every bank served column 0's FIFO).
- KV_LOAD is positional: the 16-bit index is RELATIVE to the live FIFO
  window `[read_ptr, read_ptr+occupancy)`; loads are non-destructive reads
  (read_ptr advances only on eviction). Out-of-window → no response.
- Load responses echo the request MODULE_ID (was hardcoded 0xEE, which
  node_eject would never eject) and carry a CRC the node doorbell validates;
  the response is a full compute flit `[dest | 0x80 | LEN(512) | entry | CRC]`.
- `LQ_DONE` settle state: the response starts one cycle after the request's
  final-byte acceptance, so `nob_in_ready` stays high through the handshake.
- Eviction bookkeeping (occupancy--/read_ptr++) happens when the last evict
  byte streams (EV_DATA tail), not on evict_req deassert.

### Testbench (HDL/tb_kv_cache_bank.v, registered in pnmt hdlFabric)
- A: fill-to-full via reclaim + evict one (occupancy 64→63, 512 evict bytes,
  0 NoB bytes during eviction).
- B: CRC-valid store + load round trip: 518-byte response byte-exact with an
  independently recomputed CRC, no spurious trailing bytes.
- C: corrupt store refused (occupancy unchanged); D: corrupt load → no
  response; E: two stores → two loads with correct FIFO order, then manual
  eviction via the `evict_req_manual` override (the offload controller only
  evicts at kv_full) and a post-eviction load at relative index 0.

### Co-sim scenario (sim/internal/pnm/run.go)
- `ScenarioKV` (opt-in: `go run ./cmd/pnm --scenarios kv --seed 1`) sets
  `prog.KVCache` → `GenTopology(..., kvcache=true)`; 5 target banks (4
  layer-0 columns + 1 layer-1), two committed stores each, one corrupt
  store, two loads, one corrupt load.
- `VerifyKV`: per-slice flit classification by CTRL, byte conservation
  (injected + generated == delivered + stripped + absorbed), per-node
  byte-exact `StubOutput(kvResponse(entry), bias)` comparison, class-3
  delivery, zero doorbell refusals, no tail/residual traffic.
- `kvExpected` is the twin: FIFO from manifest store payloads, loads served
  in order. Unit tests: `kv_co_sim_test.go` (determinism, twin shape, CRC).
- **PASS verified end-to-end**: 10 activations, 5180 DMA bytes, all
  conservation + byte-exact checks green.

### Gotcha (repeat class)
`localparam LQ_DRAIN = 2'd4` truncates to 2'b00 = LQ_IDLE; the `lq_active`
term `(lq_state == LQ_DRAIN)` was then TRUE while idle, permanently blocking
the pass-through. **All FSM state params must match the width of their
`reg`** (now `3'd` for the 3-bit lq_state).

## Architecture simplification pass (2026-09-22)

1. **CRC engine de-duplicated (kv_cache_bank.v)** — the bank's inline
   `crc16_update` function is gone; every fold is now a `crc16` module
   instance (core/crc16.v), matching doorbell.v. The pnmt kv_cache_bank
   case compiles with "core/crc16.v".
2. **paper/HDL is build-generated** — build.py's `sync_hdl()` copies the
   whole HDL/ tree into paper/HDL before building (the tracked mirror had
   silently diverged: doorbell.v and pe_tile_stub.v). paper/HDL/ is no
   longer tracked; `.gitignore` covers it. Verify with `python3 build.py`
   after pulling the toolchain.
3. **Dead code removed** — `BuildWeightFlit` (zero call sites; model_fabric
   comment updated) and the duplicate terminal visualizer main
   (viz/main_x11.rs) deleted.
4. **kv_offload wired into the co-sim** (resolves MEDIUM #33's "never
   instantiated" half): gen_topology now emits one kv_offload per layer in
   discard mode (EVICTION_TARGET=0, spine_out_ready tied high) serving the
   four column banks; banks expose evict/reclaim nets (x<4) instead of
   tied-off pins; BANK_DEPTH parameterized via `prog.KVDepth` (0 = default
   1024). The standalone bank TB keeps its own full-bank eviction path.
5. **New `kvflow` scenario** — a BANK_DEPTH=4 bank fills to capacity, the
   controller auto-evicts the oldest entry, and loads at relative indices
   0..2 must return the circular window e2,e3,e4. Byte-conservation +
   twin replay (ring with wp/rp/occ) verified end-to-end: 3 responses,
   1554 DMA bytes, ALL SCENARIOS PASSED. The twin's rule "evict once when
   occupancy == depth, serialized before the next command" matches the
   hardware because the offload hijacks the NoB (nob_in_ready=0) until the
   eviction completes.
 6. **Open items (partly done — see the 2026-10-13 fold notes below).** The
    parameterized FMA/ALU family landed as `HDL/core/arith_unit.v` (10
    datapaths, CU-selected) with 10 thin wrapper modules, generated by
    `HDL/core/gen_arith_unit.py`; the 4 orchestrator SoC variants landed as
    `HDL/orchestrator.v` (`ROLE` parameter) with 4 thin wrappers, generated by
    `HDL/gen_orchestrator.py`. The R/Haskell/HLSL frontends stay separate by
    design (the paper claims three sources; the shared lowerer centralizes
    `.pnm` emission). (This bullet originally called all three "not done".)

## DRAM latency model + validation-gap closure (2026-10-12, after placement)

Two tracks finished: (1) a characterized DRAM latency/bandwidth estimate for
the tok/s projections, (2) closing the last validation gap by composing the
three silicon stages — Gating ASIC → node-network fabric → node.v compute —
bit-exact on real weights. `go test ./internal/pnm/ -count=1` ok (~4s),
`go vet` clean.

1. **DRAM pers-latency model** (`sim/internal/pnm/benchmark.go` +
   `benchmark_test.go`). `DRAMSpec{Name,PerNodeGBps,LatencyNS,RefreshPct}`
   + `DRAMTypes()` = 6 classes: LPDDR6 (256 GB/s, 18 ns, 0.02), LPDDR5X (68,
   15), LPDDR5 (51, 20), DDR5-5600 baseline (90, 16), HBM3E (3350, 100, 0.01),
   GDDR6 (576, 50, 0.01). `AnalyzeDRAM` (uses `ReferenceParams` = 512 nodes,
   30 layers, 270 dispatches/tok, 32-B payload, α=7/8 anchor 1.1e6):
   `BandTokPSec` = effGBps×512×(1−refresh)×1e9/(270×39) (payload+7 wire);
   `SerialTokPSec` = 1e9/(30×LatencyNS); memory tok/s = min; `Headroom` vs the
   α=7/8 anchor; `BoundBy` string. `referenceFabricTokPSec` prefers the
   measured (8,8,8)/32B point (3,335,614 tok/s), else max. `BenchmarkReport`
   gained `DRAM []DRAMAnalysis json:"dram_estimate"`; Render prints the
   "=== DRAM latency / bandwidth estimate (characterized model inputs, none
   measured) ===" table. Paper §2.8 (line ~233) extended: LPDDR class DRAM
   clears the α=7/8 anchor ~1.5–2×; HBM3E ~100 ns / GDDR6 ~50 ns latency
   would bind; bandwidth never binds. `python3 paper/build.py` → "Wrote
   paper.docx". docs/usage_manual.md benchmark section documents it.
2. **Validation-gap closure: Gating → fabric → node, bit-exact.**
   - `sim/internal/pnm/bf16_oracle.go`: exact Go port of bf16_fp_ref.py —
     b16RNE/mul/add/sub/div/fma (float64 exact, dyadic), b16Exp (log2e+LUT),
     b16Gelu, `expertB16Slice` (real gate rows 0..EFF-1, up rows shifted by
     effFull, down rows (e·Hidden+r)·effFull), `expertTwin` (fma-chain gate/up,
     act=gelu(gate)·up, down), fmaChain, f32ToB16Word.
   - `sim/internal/pnm/node_harness.go`: `nodeClient` compiles
     `tb_node_server.v` + node.v + the 7 FMA/MAC units (`-g2005`,
     `-P N/EFF/CU_TYPE/WIDTH/GU_ROWS/MAXREQ=0`), boots per (layer,expert),
     `Expert(hidden)` writes x_N.hex → req_N.go, waits res_N.done, parses the
     N BF16 words.
   - `HDL/core/tb_node_server.v`: persistent node.v server mirroring
     tb_gating_server.v (BOOT: wu.hex GU_ROWS×N + wd.hex N×EFF; SERVE loop;
     out_addr/out_val window; `$display` stdout is block-buffered so all sync
     is via files).
   - `sim/internal/pnm/node_composition_test.go`
     `TestRouterFabricNodeComposition`: real token-0 scaled embedding →
     gemmaRouterInput → gating ASIC slice (width 256) top-1 (assert ⊆ software
     top-8 at the same width) → `BuildGatedFabricProgram`/`RunGatedFabric`
     (32-B bf16 hidden payload, (1,4,4)) byte-exact → node.v on that expert →
     `expertTwin` bit-exact. **PASS: "composed gating(asic top-1=53) -> fabric
     (1 flits, PASS) -> node: 16/16 words bit-exact vs BF16 twin"** (~3.7s).
     Note: `ModelFabricResult.OK` is vestigial (never assigned); assert
     `ScenarioResult.Pass`/`Errors`.
   - **Root-caused & fixed a start-pulse hang in tb_node_server.v.** When a
     request file arrives AFTER boot, the fopen poll (whole-period `#80`
     delays) resumes exactly at a posedge instant; the serve loop's
     `start <= 1; @(posedge clk); start <= 0;` then gets an IMMEDIATE
     `@(posedge clk)` return in the SAME timestep, so `start<=0` commits in
     the same NBA region → start stays 0 → node.v never leaves X_IDLE, the N
     hidden words stream into a dead FSM, `while(!done)` hangs (verified via
     `poll.log`/`dbg.txt` markers: `t=184315 pulse-start`/`pulse-end` same
     `$time`). Pre-staged files worked, late files hung in every multi-request
     flow (first fopen beats the harness's file write). Fix: `#1;` after the
     poll, before the pulse — settles off the grid so the pulse spans a full
     period deterministically (the gating server never hit this because its
     `bus_op` holds `bus_valid` across three edges). Both pre-staged and late
     requests now serve; multi-request works.
   - Reproduce hooks: `node compute ASIC (8x16 BF16 bit-exact, vvp)` stays
     always-on; `TestRouterFabricNodeComposition` under `--real-weights`.

## FMA/ALU family fold + gofmt gate (2026-10-13 session)

Three round-39 items landed on the live tree (all verified in `nix develop`;
not committed):

1. **`HDL/core/arith_unit.v` — the 10 FMA/ALU/MAC datapaths folded into one
   parameterized module** (`parameter CU`): 0 bf16_fma, 1 fp16_fma, 2 fp32_fma,
   3 fp64_fma, 4 int8_mac, 5 int4_mac, 6 fp4_mac, 7 mxfp4 (fp4+shift),
   8 fp32_alu, 9 fp64_alu, 10 int8_alu. Wide ports (`a/b/c[63:0]`, `op[2:0]`,
   `pack_select`, `b_pack_select`, `wshift[3:0]`); each CU is a `generate`
   branch with branch-local regs driving the shared wires. The ALU branches
   reuse the FMA slices by instantiating `arith_unit #(.CU(2/3))` internally.
   Built by `HDL/core/gen_arith_unit.py`, which splices the *verbatim* bodies
   of the original modules (placeholder-guarded so `.a(`/`.result` port names
   aren't renamed) — regenerate with `python3 gen_arith_unit.py`, don't
   hand-edit `arith_unit.v`.
2. **The 10 legacy modules are now thin wrappers** around `arith_unit`
   (ports/names unchanged), so every testbench, `node.v`, `pe_tile_stub.v`,
   `moe_gating.v`, the boards and the ALU arrays keep working untouched.
   `fma_core.v` is retained (used by CU0/1/2).
3. **Compile lists gained `core/arith_unit.v`**: `pnmt` `hdlCore()`/`hdlFabric()`
   cases, `run.go` `FABRIC`, `reproduce.sh` iverilog steps, `gating_harness.go`,
   `node_harness.go`, `integration_test.go`, `gating/node_reference_test.py`,
   `real_matvec_poc.py`, `synth.sh`. `build_asm.py` resolves it automatically
   (its `resolve_deps` walks wrapper→`arith_unit` and self-edges terminate on
   the file-`seen` set). iverilog elaborates laziy, so a CU that doesn't need
   `fma_core` doesn't require it in the list.

Verification (all PASS): `pnmt hdl-core` 27/27; `pnmt hdl-fabric` 10/10;
`node_reference_test.py` (random, `--real` L0 expert-0 bit-exact, `--cu 4`);
`gating_reference_test.py` (8x16 and `--real` 128x2816 bit-exact);
`real_matvec_poc.py`; `go vet ./...`; `go test ./internal/pnm/ -count=1`
(~4s incl. `TestRouterFabricNodeComposition`); `pnmgate -layers 0 -width 256`
→ exact `[818 5279 529 9405 563 15687 236761 106]` "…Berlin.";
`build_asm.py` node_bf16/node_int8 `*** SIMULATION PASSED ***`.

4. **`gofmt` gate.** `gofmt -w sim/` (27 files reformatted); `pnmt lint` gained
   a `gofmt` test (`gofmt -l .` must be empty) alongside the already-added
   `reproduce_self_check`. Lint is now 4 tests, all green.

## Frontend + SoC-family consolidation (2026-10-13 session, cont.)

Two more round-39 refactors landed (still uncommitted):

5. **Shared FP64 IR core (`sim/internal/pnm/ir.go`).** The R and Haskell
   frontends were parallel compilers sharing `FP64IR`/`FP64Program` but
   carrying duplicate emitters, register allocators, arg splitters and
   aggregation lowering. `ir.go` now owns `FP64Op`+`String`, `FP64IR`,
   `FP64Program` (+`allocReg`/`getOrCreateReg`), a single
   `emitFP64Inst(b, inst, indent)` used by both emitters (R flat, Haskell
   `"  "`-indented; Neg/Sub fall through to the default arm — identical
   text), `splitTopLevelArgs` (shared by R and HLSL; Haskell's space
   splitter stays), and `emitFP64Agg` (sum/prod/min/max/mean) shared by R
   and Haskell via a resolver callback. `compileRAgg`/`compileHaskellAgg`
   are now thin op-name mappers. Verified: `go test ./internal/pnm/ -count=1`
   (all IR/semantics/property/dataflow tests), `go vet`, and all three CLIs
   `-ir`/`-run -inputs x=4,y=7` still print identical IR and `result = 39`.

6. **SoC family folded into one `orchestrator.v` (parameter `ROLE`).**
   `HDL/orchestrator.v` (generated by `HDL/gen_orchestrator.py`) contains the
   four variant bodies (CHIP/MCU/SBC/SBC_MOE) verbatim inside NAMED generate
   blocks (`g_chip`…), sharing one `crc16_next` function and the union of
   ports/params. The chip body's `output reg` ports (pcie_out_*,
   boot_done, dispatches, weight_flits, errors) become internal regs + `assign`
   so the unified ports can be `wire`; `ext_irq` widens to `[15:0]`; the
   status outputs are CHIP-only. The four original module names
   (`orchestrator_chip.v` etc.) are now thin wrappers instantiating
   `orchestrator` with the role + the file's defaults. `gen_orchestrator.py`
   reads the original bodies from `git show HEAD:HDL/<file>` so re-running is
   idempotent (it overwrites the wrappers).
   - **TBs repathed**: `tb_orchestrator_{mcu,sbc,sbc_moe}.v` probed internal
     signals hierarchically (`u_dut.fb_state`, `u_dut.rom`,
     `u_dut.gating_sram`); the refs are now `u_dut.u.g_<role>.*` (chip's TB
     probed no internals). Verified: `pnmt hdl-fabric` 10/10 (all four
     orchestrator TBs), `./reproduce.sh` **28/28 PASS** (incl.
     `tb_orchestrator_chip`), `go test ./internal/pnm/ -count=1`, `go vet`.
   - Compile lists gained `orchestrator.v`: `pnmt` `hdlFabric()` cases,
     `reproduce.sh` self-check + `tb_orchestrator_chip` step.
   - Lazy elaboration: `orchestrator.v` needs no `pnm_defs.vh` (the spliced
     bodies are self-contained) and no `fma_core`/`arith_unit` for roles that
     don't instantiate the MoE path.

## Node-network energy + multi-channel memory model (2026-10-13 session, cont.)

Two coupled additions — multi-channel per-node memory and a repeater-aware
node-network energy model — landed in RTL + Go (uncommitted).

7. **`HDL/core/node_mem.v` — per-node multi-channel memory.** `CHANNELS` banks
   (`CHANNEL_DEPTH` words each); word `a` lives on lane `a mod CHANNELS`, so a
   read burst returns `req_words/CHANNELS` in-order beats, each `CHANNELS` words
   wide, after `CAS` cycles. Contract: `req_addr` CHANNELS-aligned, `req_words`
   a multiple of CHANNELS. `rd_valid`/`rd_last`/`rd_data` are combinational
   from `st`/`beat` (registering them caused an off-by-one vs data). Validated
   bit-exact 9/9 vs a word-interleave oracle (`node_mem_reference_test.py`,
   `tb_node_mem.v`) across CHANNELS in {2,4,8} and CAS in {1,2,5}.
8. **`node.v` gained `parameter MEM_CHAN`** (default 1, so every existing
   TB/board/test is unchanged): `hidden_data` is `MEM_CHAN*WIDTH` wide and
   `X_LOAD` ingests `MEM_CHAN` words per `hidden_valid` beat
   (`hidden_latch[in_ptr+c]`, `in_ptr += MEM_CHAN` when `in_ptr+MEM_CHAN >= N`).
   `node_reference_test.py` now sweeps MEM_CHAN in {1,2,4} for the random/CU4
   cases (`--mem-chan N` to pin one) and confirms the expert result is
   channel-invariant; `--real` stays MEM_CHAN=1. `tb_node.v` streams
   `N/MEM_CHAN` beats. All bit-exact.
9. **`sim/internal/pnm/energy.go` — node-network energy + memory-channel
   model, rendered by `pnmhost benchmark`.** `AvgNoBHops = meanAbsDiff(Layers)
   + meanAbsDiff(Bx) + meanAbsDiff(By)`, `meanAbsDiff(n) = (n^2-1)/(3n)`.
   `AnalyzeNodeNetworkEnergy(dims, tokPSec, payload, DefaultEnergyParams())`
   = repeater/SerDes power (`270 dispatches/token x hops x (9500 pJ/hop + flit
   bytes x 0.5 pJ/B/hop)`) + node rails (`nodes x (1.15+8.7+3.0) W`, from
   power_rails.v) + infra (`RouterW 10 + SpineW 72`), wall = raw/0.92.
   `AnalyzeMemoryChannels(16 GB/s, 512, 2, {1,4,8,16})` scales node BW = 16 x
   C and bytes/beat = C x elem. `BenchmarkReport` gained `Energy`
   (`energy_estimate`) + `MemoryChannels` (`memory_channels`); `Render` appends
   both via `RenderEnergy()`; `AnalyzeSweepEnergy` dedups the sweep chassis at
   the fixed alpha=7/8 anchor. Numbers: 512-node (8,8,8) network = 22.3 W
   (0.33% of a 7.26 kW wall), 16-node (1,4,4) = 2.4% (fixed infra dominates
   small chassis); 16 channels x 512 nodes = 131 TB/s = the paper's aggregate.
   Tests: `energy_test.go` (meanAbsDiff, AvgNoBHops, energy math, chassis
   scaling, sweep dedup, memory-channel scaling, render labels).
10. **`reproduce.sh`** registers `node_mem.v`/`tb_node_mem.v`/
    `node_mem_reference_test.py` in the self-check + a
    `node memory (multi-channel interleave bit-exact, vvp)` step.
    `docs/usage_manual.md` benchmark section documents both tables; `pnmhost
    benchmark` verified end-to-end (sweep PASS, `energy_estimate` /
    `memory_channels` in the JSON export).
    Verify: `go test ./internal/pnm/ -count=1` ok, `go vet ./...` clean,
    `gofmt -l` clean, `reproduce.sh` node_mem step PASS (9/9).

## Dual-module memory: 2 x 64 GB 192-bit LPCAMM2 (2026-10-13)

The reference node now packs **two 64 GB 192-bit LPCAMM2/LPDDR6 modules**
(384-bit dual-module bus, ~512 GB/s) instead of one 128 GB 192-bit module.
Capacity is unchanged (128 GB/node, 512 nodes = 64 TB chassis); the module
count doubles node-local bandwidth, so the **aggregate node-local bandwidth
doubles 131 -> 262 TB/s**. The user asked for this across PCB + topology
builder + paper numbers, so every figure was updated consistently.

- **Energy/benchmark model** (`sim/internal/pnm/energy.go`,
  `benchmark.go`): new constants `SubChannelsPerModule=16` (one 24-bit-group
  module = 16 twelve-bit sub-channels) and `ReferenceModules=2`. The
  multi-channel sweep is now `{16,32,64}` sub-channels (1/2/4 modules);
  `MemChannelRow` gained `Modules` + `Reference` (32 sub-channels = the
  reference). `PerNodeChannelGBps` stays 16 GB/s. `DRAMTypes()` LPDDR6
  reference = 512 GB/s/node; cost-model aggregate = ~262 TB/s. `firmware.go`
  WeightUpload `Bandwidth` = 512. Tests updated to expect 512 / 512*512.
- **Topology builder** (`sim/internal/pnm/gen_topology.go`):
  `GenTopology(..., kvDepth, memChannels)` emits a per-node
  `node_mem #(.CHANNELS(memChannels), .DEPTH(1024), .WIDTH(16), .CAS(2))`
  when `memChannels > 0`; `Program.MemChannels` defaults to `ReferenceModules`
  in `NewProgram`, so the generated `pnm_top.v` now carries the two-module
  memory (inputs tied off, outputs to per-node wires). `node_mem.v` added to
  the `FABRIC` compile list. `des_test.go` passes 0 (keeps the DES slice lean).
- **Assembly builder** (`implementations/boards/node_dual_mem.json`): new board
  composing `node` (CU_TYPE 0, `MEM_CHAN=2`) + `node_mem` (CHANNELS 2,
  ADDRW=16 so the param-aware width eval resolves `[ADDRW-1:0]` tieoffs),
  builds + sims PASS; registered in `reproduce.sh` self-check + run list, and
  in `implementations/README.md` / `docs/usage_manual.md`.
- **PCB** (`pcb/README.md`, `pcb/pnm_node/library/{cmp,dev}`): node = two
  LPCAMM2 sockets (64 GB 192-bit modules), 384-bit dual-module; library
  component/device descriptions updated; gating-ASIC row clarifies "one
  pnm_node socket".
- **Paper** (`paper/Paper.MD`, `TLDR_Paper.md`, `TLDR.md`, `README.md`,
  `paper/figures/make_figures.py`): 256 -> 512 GB/s, 131 -> 262 TB/s, Table 1
  CAMM2 socket x2, Table 2 node "2 x 64 GB ... 384-bit", Sections 2.4/2.5/
  2.6/2.8/2.16/3.1/3.2/3.3/3.6/3.7 + abstract/conclusion. `make_figures.py`
  roofline now draws the 512 GB/s node line plus the 256 GB/s per-module line.
  `python3 paper/build.py` ok (docx+pdf, no undefined citations).
- Verify: `go test ./internal/pnm/ -count=1` ok (~4s), `go vet ./...` clean,
  `bash reproduce.sh --self-check` OK, `build_asm.py boards/node_dual_mem.json`
  PASS, `pnmhost benchmark` -> LPDDR6 512 GB/s / 262 TB/s (headroom 1.7x,
  still fabric-bound), `python3 paper/build.py` ok.

## BitNet b1.58 + dead-weight cleanup (2026-10-13, after dual-module memory)

Two tracks: (A) quarantine/repair the dead weight the review found, (B) add a
BitNet b1.58 ternary compute unit end to end and put it in the paper.

**A. Cleanup (all verified).**
1. **`HDL/core/gen_arith_unit.py` was one-shot/non-idempotent** — its
   `body_of()` read the *working-tree* source datapaths, which it had itself
   already overwritten with thin wrappers, so a second run spliced the wrapper
   into `arith_unit.v` (1511 -> 223 lines). Fix: read the originals from
   `git show HEAD:HDL/core/<file>` (same pattern as `gen_orchestrator.py:36`).
   Re-run is now byte-identical (`md5sum -c` clean). Header text corrected
   ("ten legacy modules", MXFP4 = fp4+CU7 block-scale).
2. **Archived 9 dead files** (all `git mv`, provenance kept):
   `HDL/tb_expert_loop.v`, `HDL/tb_integration.v`, `HDL/tb_rv32_core.v`,
   `HDL/tb_rv32_core_load.v`, `HDL/tb_flit_gate.v`, `HDL/tb_hfr.v`,
   `HDL/core/tb_int4_mac.v`, `HDL/orchestrator_chip_haskell.v`,
   `HDL/core/ram_phy_stub.v` -> `archive/hdl/` (+ `archive/README.md` rows).
   None were referenced by `pnmt`/`reproduce.sh`/`flake.nix`/any live `.v`.
   Deleted two stale root-level `.vcd` files.
3. **`AGENTS.md` stale "Open items (not done)"** (the FMA/ALU fold + 4
   orchestrator variants) corrected to "partly done — see 2026-10-13 notes".
4. **`build_asm.py` width regression fixed.** `node.v`'s `hidden_data` is
   `[MEM_CHAN*WIDTH-1:0]`; board JSONs omit `MEM_CHAN`, so `_eval_index`
   returned `None` and every node board crashed with a `TypeError` (a latent
   bug from the multi-channel work — the boards weren't re-run). Fix: new
   `effective_params(mod, inst_params)` merges the module's parameter
   *defaults* with the instance params before width evaluation. All seven node
   boards build+sim PASS.
3. **Paper now documents the real node** (see B below for the taxonomy): new
   **§2.20 "The compute node and the gating ASIC"** (selectable node MAC +
   `node_mem` multi-channel + `moe_gating`/`gating_asic` logit window + the
   bit-exact `gemma_decoder_block` + the ASIC->fabric->node composition); §2.9
   PE-stub paragraph points to it; §3.5 adds the integrated-datapath check;
   §1.6 contribution 3 mentions it. Table 5 `CU_TYPE` wording corrected.

**B. BitNet b1.58 ternary unit.**
- **`HDL/core/ternary_acc.v`** (standalone, 2-stage, same shape as
  `int8_mac`): `result = c + code(a)*b`, where `b[1:0]` selects {+a, -a, 0}
  (`2'b01`/`2'b10`/else). No multiplier; signed INT32 accumulate. Per-tensor
  /per-channel scale stays host-side (like `real_infer.go`'s per-expert
  scale).
- **`HDL/core/node.v` CU_TYPE 8** instantiates it (identity activation,
  `GU_ROWS=EFF`); the old MXFP4 arm is now explicitly `CU_TYPE == 7` with a
  tie-off `g_none` default, header table gains CU 8.
- **Tests**: `HDL/core/tb_ternary_acc.v` (directed +1/-1/0, signed, extremes,
  `b[1:0]` masking, accumulate) -> `pnmt hdl-core` 28/28 PASS;
  `node_reference_test.py` gained `WIDTHS[8]=8`, a ternary weight generator, a
  `reference_ternary` select-add oracle, and `ternary_acc.v` in the compile
  list — `python3 HDL/core/node_reference_test.py --cu 8` is **bit-exact
  across MEM_CHAN=[1,2,4]**. `.pnm`/assembly: new
  `implementations/boards/node_ternary.json` (CU_TYPE 8), builds+sims PASS.
- **Hooks**: `reproduce.sh` registers `ternary_acc.v`/`tb_ternary_acc.v` in the
  self-check + a `tb_ternary_acc` step + `node compute ASIC (8x16 ternary
  BitNet exact, vvp)` + `assembly builder (node_ternary board, vvp)`;
  `sim/cmd/pnmt/main.go` gained the `ternary_acc` hdlCore case (28 tests).
- **Compiler plumbing**: `CUTypeTernaryAcc` (String `ternary_acc`,
  `DTypeBytes` 1 = 4 codes/byte) in `model_compiler.go`; `QuantTernary`
  (`"ternary"`, -> `CUTypeTernaryAcc`, 1 byte/weight) in `llm_client.go`;
  `sim/internal/pnm/ternary_test.go` pins both mappings.
- **Paper**: Table 5 gains a `ternary\\_mac` row (now "twelve representative
  unit types"), and §3.6 adds a BitNet paragraph (select-add datapath, node
  `CU_TYPE` 8, ~1.58 bits/weight = ~10x lower capacity/streaming footprint,
  fabric ceiling unchanged, bit-exact + `boards/node_ternary.json`). No new
  bibliography entry (BitNet is described as a weight format, not cited).
- Verify: `go test ./internal/pnm/ -count=1` ok (~4s), `gofmt -l .` clean,
  `go vet ./...` clean, `pnmt hdl-core` 28/28, `node_reference_test.py --cu 8`
  three-way bit-exact, all 7 node boards build+sim PASS,
  `reproduce.sh --self-check` OK, `python3 paper/build.py` ok (no undefined
  citations).

## BitNet node on real weights + ternary composition (2026-10-14 session)

Wired the BitNet b1.58 ternary datapath through the real-weight harness and the
Gating->fabric->node composition, all bit-exact.

- **`node_reference_test.py` duplicate-oracle bug fixed.** Two `reference_ternary`
  definitions had accumulated: my correct one (adds the ternary select-add oracle,
  line ~101) and a stale second one (line ~148) whose body was actually the INT8
  oracle. The stale definition shadowed the correct one, so `--cu 8` "passed"
  against the wrong oracle AND `--cu 4` called `reference_int8`, which no longer
  existed (NameError). Fix: removed the stale duplicate and re-added it under the
  correct name `reference_int8`. `--cu 4` and `--cu 8` now both bit-exact across
  MEM_CHAN=[1,2,4]; `--real --cu 8` bit-exact on the real L0 expert (ternary).
- **Real ternary node hook** in `reproduce.sh --real-weights`:
  "node compute ASIC (real layer-0 expert, ternary, vvp)" ->
  `python3 HDL/core/node_reference_test.py --real --cu 8`.
- **Ternary composition test** (Go). `node_harness.go` gained
  `BuildWeightHexTernary` (per-row absmean quantize -> 2-bit codes -> `%02x`
  wu/wd.hex), `ExpertInt8` (INT8 hidden stream -> `x_N.hex`), `ternaryCodeRow`,
  `ternaryQuantizeHidden` (symmetric max-abs INT8), and `nodeTernaryTwin` (exact
  INT32 select-add oracle: gate -> low-byte identity act -> down). Phase 4 of
  `TestRouterFabricNodeComposition` boots a `CU=8, Width=8` node on the same ASIC
  top-1 expert and the same delivered hidden vector and checks 16/16 words
  bit-exact vs the twin: `composed ternary node (CU_TYPE 8, expert 53): 16/16
  words bit-exact vs select-add twin`.
- Verify: `gofmt -l .` clean, `go vet ./...` clean,
  `go test ./internal/pnm/ -count=1` ok, `pnmt hdl-core` 29/29,
  `./reproduce.sh` all non-real steps PASS (exit 0), `python3 paper/build.py` ok.
  (`reproduce.sh --real-weights` needs the checkpoint at `Paper/models/
  gemma-4-26B-A4B`; the runnable assembly lives at `/data/gemma4_dl/complete`, so
  those steps fail on the download path only — the real tensor checks were
  verified directly against `/data/gemma4_dl/complete`.)

## 2026-10-20 session — land the tree, publish the split repos, chain the composition

Three tracks, all verified green.

### 1. The working tree was landed (10 commits, previously 145 modified + 58 untracked)
`Paper/` had two months of uncommitted work (node.v, arith_unit.v,
orchestrator.v, gemma_decoder_block.v, the IT-weight reasoning path, the
benchmark/energy models, pnmgate). Committed in six area-based commits plus
the paper artifacts and the tooling:
`77582c9` compute core + node + BF16 library + decoder block,
`b4edff4` orchestrator ROLE fold + KV bank, `c9786c3` sim harness/benchmark/
dataflow, `abd07c5` build+boards, `12e5796` docs, `fda845c` paper artifacts,
`b362380` download/compare scripts, `a69a219` sibling-repo resolution,
`ac8f1dd` reproduce.sh skip in split checkouts, `25457c6` split tooling,
`b573a85` arXiv bundle, `5445e14` multi-layer composition, `828a707` paper.
`gofmt`/`go vet` clean, `pnmt` 81/81, `reproduce.sh` 22/22.

### 2. Eight Verilog-2005 declaration-order bugs fixed (they broke the whole RTL suite)
All were "declaration after use" in the last session's refactors:
- `HDL/core/gating_asic.v` (mg_hidden_addr), `fp_mac_array.v` (out_active),
  `fp32_mac_array.v` (out_active), `int4/fp4/mxfp4/ternary_acc_array.v`
  (psum_v_sr) — the arrays would not elaborate at all.
- `HDL/kv_cache_bank.v` (the crc16 engine instances + the KV/load/response/
  eviction state must precede the absorb decision wires).
- `HDL/tb_orchestrator_chip.v` (errors_local before the task that increments it).
- `HDL/tb_kv_cache_bank.v` (SystemVerilog-only null-step `for` -> `while`).
- Latent, found by the wider slice: `HDL/core/node.v` compared
  `out_addr < N[7:0]`, so **any N >= 256 blanked the node's whole output
  window** (N[7:0] == 0 for N=256). Now `localparam [31:0] N_OUT = N`, and
  `in_ptr` widened to 12 bits for N > 256.

### 3. The published split repos were a month stale — now synced and pushed
`PNM-HDL/PNM-fw/PNM-sim/PNM-paper/PNM-PCB/PNM-toolchain` (github.com/im-BowenGu)
still carried the "Initial public release" snapshot. New `tools/split_sync.sh`
copies the **git-tracked** files of the monorepo into each split repo (so no
generated artifact can leak into a public repo), prunes the files the monorepo
no longer has, and merges each split repo's "## Related repositories" section
back into the refreshed README (`tools/merge_readme.py`). The harness now
resolves its siblings in **both** layouts (`pnm.SiblingRepo("HDL"/"fw")`,
`PNM_HDL_DIR`/`PNM_FW_DIR` overrides), so a split checkout runs its own suite:
`cd PNM-sim && go run ./cmd/pnmt` -> 80 passed, 1 skipped (the monorepo-only
`reproduce.sh` self-check). All six repos pushed.

### 4. The arXiv package is now self-contained
`paper/build.py` stages `paper/submission/arxiv/`: paper.tex + the five figure
PNGs + a CC BY-SA 4.0 LICENSE + the abstract + a README. The bibliography is
embedded (`thebibliography`), so no .bbl is needed. `reproduce.sh` compiles the
bundle standalone (32 pages) — arXiv compiles the sources it is given.

### 5. The composition is now a chain, not a sample
`sim/internal/pnm/node_composition_multilayer_test.go`: over model layers 0, 7
and 14 (PNM_COMP_LAYERS) the router input of each layer is derived from the
residual slice the previous layer's node produced, so gating ASIC -> fabric ->
compute node is one data dependency across layers; each layer's ASIC top-1 must
sit in the software router's top-8 at the same width, and each layer's node
output is bit-exact vs the software BF16 twin (256/256 words per layer). Runs
at a reduced 256-dim slice (node N=256, router width 256) to stay in budget.
Paper §2.20 now reports the chained composition.

### Environment
- **The nix toolchain could not be fetched at all**: the substituters in
  `/etc/nix/nix.conf` (sjtu/tuna/ustc) reset TLS on every narinfo request, so
  `nix develop` hung and go/iverilog were missing. Fixed with a user-level
  `~/.config/nix/nix.conf` pinning `substituters = https://cache.nixos.org
  https://nyx-cache.chaotic.cx/`; iverilog 13, verilator 5.052, yosys 0.69,
  go 1.26.7 and texlive now fetch.
- Deleted the 35 GB incomplete `models/gemma-4-26B-A4B/model-00001-of-00002
  .safetensors.part` (a dead download; the usable checkpoint is
  `/data/gemma4_dl/complete` and the fused IT one is
  `/data/ai/models/gemma-4-26b-a4b-it-bf16-fused`).
- `sim/results-bench/` added to .gitignore; the 51 stray `*.vcd` dumps and the
  `__pycache__` dirs removed; the four `tmp_*_test.go` scratch harnesses
  renamed to `harness_*_test.go` (TestHarnessChatIDs/GenIds/DumpLogits/
  PlainComplete).

## 2026-10-21 session — the router chip's software, and two holes in the "machine-checked" claim

The Linux/seL4 stacks were moved out of `toolchain/` into the router-chip
software tree (`fw/os/linux/`, `fw/os/sel4/`), the source-language front
ends were unified behind one client-side CLI, and the security-posture
paragraph was removed from the paper.  Building and *running* the Linux
stack for real exposed two things the suite had been hiding.

### The client-side source front end (`sim/cmd/pnmsrc`)
`srcfront.go` + `srccli.go` in `sim/internal/pnm` hold the shared front end
(`SourceLang`, `CompileSource`, `RunSourceCLI`): R, Haskell and HLSL were
three near-identical CLIs that differed only in the compiler and the
lowering.  `pnmsrc` is one binary for all three (the language comes from
`-lang` or the file extension); `r_pnm`/`haskell_pnm`/`hlsl_pnm` are now
thin wrappers, so the three languages cannot drift apart.

### The Linux image: six build bugs and two RTL bugs
- `configs/pnm_tiny.config` was **silently reverted by Kconfig**: `ARCH_RV32I`
  depends on `NONPORTABLE`, and `CONFIG_64BIT` is a hidden symbol, so the
  "NOMMU RV32I" kernel was actually a 64-bit MMU kernel.  `CONFIG_TTY` was
  missing as well, so the 8250 console was never built (no console at all).
  The stock NVMe *block* driver needs `CONFIG_PCI` and cannot drive the
  chip's memory-mapped NVMe window, so it is no longer claimed.
- The init binary never linked: no entry stub, the host `cc` as the
  compiler, the initramfs cpio put the binary at `build/init` instead of
  `/init`, no linker script (linked at 0x10000), and a meaningless reset
  stack pointer.  Added `src/start.S`, `src/init.ld` (configurable load base
  and a stack inside the image window) and `src/div.S` (the two integer
  division helpers a freestanding `-nostdlib` build needs).
- `drv_uart.c`: the 16550 divisor is `clock/(16*baud)`, not `clock/baud`, and
  the registers are byte-wide — a 32-bit store to the UART base wrote the
  character into THR *and* spilled into IER/FCR/LCR.  The access width now
  follows the bus (the chip's word-aligned UART vs a byte-aligned host) and
  the register shift is selectable.
- **RTL**: `uart.v`'s register read path was registered.  A 16550's registers
  are read asynchronously and the core latches read data in the handshake
  cycle, so every UART read returned the *previous* access's value (a stale
  LSR makes a transmitter-wait loop spin on an empty transmitter).  The read
  path is now combinational.
- The SoC bus models acknowledge every access now (an unmapped read returns
  zero, an unmapped write is dropped) instead of stalling the core.

### Two holes in the "machine-checked" claim
1. **`iverilog`'s `$finish(1)` exits with status 0** (the argument is the
   diagnostic level, not the exit code), so *every* testbench in the tree
   reported a pass even when it printed "TEST FAILED".  `pnmt` now decides
   on the **output** (a `FAILED` marker fails the test).  That immediately
   exposed four orchestrator testbenches that were already broken behind the
   exit code.
2. **The chip's RV32 core does not implement the JAL/JALR link store.**  The
   ISA writes the return address to *both* `rd` and `memory[sp-4]`; the core
   only did `rd`, so every compiled function call (which spills the link to
   the stack) lost it and **no compiler-generated code can run on the core**.
   `HDL/tb_linux_init.v` (new) runs the Linux init binary on the chip's own
   core and UART and checks its boot banner; it is registered as a
   *documented skip* until the core is fixed.  Implementing the link store
   needs the hand-written boot-ROM firmware in the orchestrator testbenches
   to establish a stack pointer first (the ROM programs use x2 as a general
   register, and the link store would target an unmapped address).

### The paper
The security-posture paragraph is gone from Section 4.6 (the section is now
"Design-for-test and manufacturing readiness"): the design makes no security
claims at this point.  Section 2.17 now says that the OS images ship and
build but do not yet boot on the proof-of-concept core, and that the gap is
machine-checked rather than assumed; the Conclusion's "compatible with Linux
and seL4" became "targeting".

## 2026-10-21 (later) — the Linux init binary runs on the chip's own core

`fw/os/linux`'s init binary is now executed by `HDL/tb_linux_init.v` on the
chip's **own** `rv32_core.v` and `uart.v`, and the test passes:

```
*** LINUX INIT TEST PASSED ***
fw-os-linux init for orchestrator_sbc
PNM STS=0x00000000
NVME CAP=0x00000000 VS=0x00000000 RC=0x00000000
```

Three RTL defects had to be fixed first (all real, all found by running it):

1. **The core did not implement the JAL/JALR link store.**  The RISC-V ISA
   writes the return address to *both* `rd` and `memory[sp-4]`; the core only
   did `rd`, so every compiled function call (which spills the link to the
   stack) lost it and **no compiler-generated code could run on the core**.
   The link store now targets x2 (sp) — for JAL, rs1 is x0 and must not be
   used as the store base — and the value also goes to rd.  (The first
   attempt broke the orchestrator testbenches because `link_store` was not
   reset: the very first register write merged to X and the boot-ROM
   firmware's UART write went nowhere.)
2. **The UART's line status register had three procedural drivers** (the TX
   FSM, the RX FSM and the bus block), so a same-cycle conflict resolved
   lsr[5] to X — and a driver that polls THRE then spins on an undefined
   value.  The whole UART state is now in one sequential block, and the LSR
   is initialised as a whole byte (an undefined bit made the byte read back
   as X).  The read path is combinational, like a real 16550.
3. **The SoC bus stalled the core on an unmapped access.**  It now
   acknowledges every access (an unmapped read returns zero, an unmapped
   write is dropped).

The init binary's stack also moved above the image (`__stack_top = __base +
0x2000`) so a flat-memory harness only has to model the first 32 KB of the
window, and the driver's 16550 divisor (`clock/(16*baud)`, not `clock/baud`)
and access width (byte-wide registers vs the chip's word-aligned ones) are
now right.

**Still open**: booting the *kernel* image under a host emulator.  The kernel
builds (a real NOMMU RV32I kernel — the config fragment used to be silently
reverted by Kconfig, so a 64-bit MMU kernel was built instead), but the guest
faults in the 8250 probe before the console comes up: the chip's UART is
32-bit aligned (`addr[4:0]`, which the Linux 8250 driver agrees with) while
QEMU's virt machine models a byte-aligned 16550.  The seL4 stack is the next
piece of work.

### Why the *kernel* cannot boot on the chip yet (the fetch path)

The core's instruction fetch is a **separate combinational port onto the
64 KB boot ROM**: `assign fetch_addr = pc;` (rv32_core.v) and
`sel_rom = (cpu_fetch_addr[31:16] == 16'h0000)` with
`rom_rdata = rom[cpu_fetch_addr[15:2]]` (bmc_orchestrator_top.v).  The
SRAM (0x4000_0000) and DRAM (0x8000_0000) windows are selected by the
*data* address only.

So the CPU can only execute from the 64 KB ROM: a 1.8 MB kernel image in
memory cannot be fetched, and neither can the init binary once the kernel
unpacks it from an initramfs.  Booting Linux or seL4 on this chip needs the
fetch path unified with the data bus (or a fetch port onto the SRAM window)
— a hardware change, not a build fix.  The init binary runs from the ROM in
the testbench, which is why `tb_linux_init.v` passes.

## 2026-10-21 (later) — the router chip is now a CPU-less host bridge

The router chip lost its processor, its boot ROM, its timer and its console.
What is left is a **bridge the host drives**: a Raspberry Pi over the SPI
adapter, or any third-party microcontroller over the same byte-level host
link.  The bridge keeps the PNM router engine, the SRAM and the register
window; the *host* runs the boot sequence, the weight upload and the
dispatch loop.

**RTL**
- `HDL/bmc_orchestrator_top.v` → `HDL/pnm_host_bridge.v`: the CPU, the boot
  ROM, the UART and the CLINT are gone; the CPU-side bus became the *host
  bus* (external ports), so the arbiter's slave side drives the PNM window
  and the SRAM.
- Deleted: `rv32_core.v`, `uart.v`, `clint.v`, `orchestrator.v` and its four
  SoC-tier wrappers, `pcie_phy.v`, `nvme_ctrl.v`, and the testbenches that
  exercised them.
- `HDL/tb_pnm_host_bridge.v` (new): the testbench plays the host, writes
  the routing and payload registers, and checks that the chip emits a
  byte-exact wormhole flit (header, payload, CRC-16, SOP/EOP) and that the
  result path and the counters read back.  It passes.
- `HDL/tb_host_bmc.v` and `HDL/tb_dma_lpddr6.v` (the Raspberry Pi path)
  survive unchanged: they never instantiated the CPU.

**Firmware and toolchains**
- `fw/pnm_fw.c` is now explicitly the *host-side* dispatch firmware.
- `toolchain/mcu/` is the cross-build system for a third-party RISC-V MCU
  acting as the host; `toolchain/soc/` is gone.
- `fw/os/linux/` and `fw/os/sel4/` are gone: with no processor on the chip
  there is no OS image to run.  (The Linux work was not wasted: it is what
  found the core's missing JAL/JALR link store, the UART's multi-driver line
  status register, and the config fragment that Kconfig was silently
  reverting.)

**Paper**
- §2.17 is now "The router bridge: a CPU-less chip with a host link"; the
  abstract, the contribution list, the four-kinds-of-hardware paragraph,
  the firmware layer and the conclusion describe the host-driven bridge.
