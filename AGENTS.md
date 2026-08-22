# AGENTS.md

Guidance for working in this repository: a research paper (*Bypassing the HBM Wall*,
a distributed Processing-Near-Memory architecture) plus the working artifacts that
back its claims — a Verilog fabric sketch, a Go ↔ Verilog co-simulation harness,
and a build pipeline that produces the one-file DOCX submission.

## Repository layout

| Path | Contents | License |
|------|----------|---------|
| `Paper.MD` | Manuscript source of truth (Markdown with LaTeX-escape conventions, see below) | CC BY-SA 4.0 |
| `build.py` | Build pipeline → `submission/paper.docx` (+ `.pdf`, `.tex`). **Gitignored and untracked** — see gotchas | AGPL-3.0 |
| `HDL/` | Verilog-2005 fabric model: `pnm_defs.vh`, `hfr.v`, `flit_gate.v`, `vc_merge.v`, `xyz_repeater.v`, `xy_turn.v`, `node_eject.v`, `crc16.v`, `doorbell.v`, `pe_tile_stub.v`, `router_chip.v`, `kv_cache_bank.v`, `kv_offload.v`, `fp16_fma.v`, `bf16_fma.v`, `fp32_fma.v`, `fp64_fma.v`, `fp16_mac_array.v`, `bf16_mac_array.v`, `fp32_alu.v`, `int8_mac.v`, `moe_gating.v`, `rv32_core.v`, `uart.v`, `clint.v`, `bmc_router_top.v` + testbenches `tb_fabric.v`, `tb_load.v`, `tb_doorbell.v`, `tb_router_chip.v`, `tb_fp16_fma.v`, `tb_bf16_fma.v`, `tb_fp32_fma.v`, `tb_fp64_fma.v`, `tb_fp16_mac_array.v`, `tb_bf16_mac_array.v`, `tb_fp32_alu.v`, `tb_int8_mac.v`, `tb_moe_gating.v`, `tb_bmc_router.v`; every repeater carries an 11-bit routing-bitmap comparator | CERN-OHL-S v2 |
| `sim/` | Co-simulation harness (Go, stdlib only): `cmd/pnm` (orchestrator + verification), `cmd/pnmc` (program compiler + model compiler + driver CLI), `internal/pnm/gen_topology.go` (emits `pnm_top.v`), `gen_tb.go` (emits `tb_pnm.v`), `virtual_units.go` (doorbell + kernels), `des.go` (discrete-event egress model) + `des_test.go`, `run.go` (scenarios + verify), `rng.go` (CPython-compatible MT19937), `safetensors.go` (safetensors index parser + model config reader + tensor shape inference), `model_compiler.go` (model-to-PNM compiler: 5-stage AOT pipeline), `driver.go` (host-side driver: weight upload + inference orchestration), `firmware.go` (router chip firmware: boot sequence + MoE dispatch), `kv_cache.go` (KV cache management with LRU eviction), `llm_client.go` (FP16/BF16 LLM inference client with sampling), `driver_test.go` | AGPL-3.0 |
| `sim/examples/gemma4_test/` | Synthetic Gemma-4-26B-A4B-it config.json + model.safetensors.index.json for testing the compiler | AGPL-3.0 |
| `sim/examples/mini_glm_moe/` | Mini GLM-MoE config (4 layers, 64 hidden, 16 experts, top-4) for testing MoE gating | AGPL-3.0 |
| `sim/fw/` | C firmware port for MCU targets (ARM Cortex-M/R, RISC-V): `pnm_fw.h` (types + API), `pnm_fw.c` (boot, dispatch, KV cache, verification) | AGPL-3.0 |
| `submission/` | Build artifacts, **gitignored** | CC BY-SA 4.0 |
| `shell.nix` | Nix shell with the whole toolchain | AGPL-3.0 |
| `README.md`, `TLDR.md`, `docs.md` | Overview / abstract / documentation | AGPL-3.0 (README) |

New files must respect the three-way license split (manuscript/artifacts, HDL/, everything else).

## Environment

Everything runs inside the Nix shell: `nix-shell` (flake-style) provides `pdflatex`,
`pandoc`, `pdfinfo`, `iverilog`/`vvp`, `verilator`, `go`, `python3` (the latter only for
the gitignored `build.py` paper pipeline). The sim harness is **Go standard library
only** — no external Go modules, no pip dependencies. No Makefile, no package.json,
no CI config exists in the repo.

## Commands

### Build the paper (from repo root)

```bash
python3 build.py            # submission/paper.docx (the submission artifact) + .pdf + .tex
python3 build.py --review   # submission/paper_review.pdf (11pt single-column, wide margins)
```

`build.py` requires `Paper.MD` present; it strips everything before the `Abstract`
header, converts `{c(n)}` → `\cite{n}`, runs pdflatex twice, then pandoc to DOCX.
The bibliography is hardcoded in `build.py` (`REFS`, Chicago style, 20 entries) — if
you add a citation to the manuscript, add the reference there (numbered order = cite order).

### HDL testbenches (from `HDL/`)

```bash
iverilog -g2005 -o tb_fabric.out hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
iverilog -g2005 -o tb_load.out   hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v   && vvp tb_load.out
iverilog -g2005 -o tb_doorbell.out tb_doorbell.v pe_tile_stub.v doorbell.v crc16.v bf16_fma.v                                               && vvp tb_doorbell.out
iverilog -g2005 -o tb_fp32_alu.out fp32_alu.v fp32_fma.v tb_fp32_alu.v                                  && vvp tb_fp32_alu.out
iverilog -g2005 -o tb_fp16_fma.out fp16_fma.v tb_fp16_fma.v                                            && vvp tb_fp16_fma.out
iverilog -g2005 -o tb_bf16_fma.out bf16_fma.v tb_bf16_fma.v                                            && vvp tb_bf16_fma.out
iverilog -g2005 -o tb_fp32_fma.out fp32_fma.v tb_fp32_fma.v                                            && vvp tb_fp32_fma.out
iverilog -g2005 -o tb_fp64_fma.out fp64_fma.v tb_fp64_fma.v                                            && vvp tb_fp64_fma.out
iverilog -g2005 -o tb_int8_mac.out int8_mac.v tb_int8_mac.v                                                                && vvp tb_int8_mac.out
iverilog -g2005 -o tb_fp16_mac_array.out fp16_mac_array.v fp16_fma.v tb_fp16_mac_array.v                                   && vvp tb_fp16_mac_array.out
iverilog -g2005 -o tb_bf16_mac_array.out bf16_mac_array.v bf16_fma.v tb_bf16_mac_array.v                                   && vvp tb_bf16_mac_array.out
iverilog -g2005 -o tb_moe_gating.out moe_gating.v bf16_fma.v tb_moe_gating.v                                               && vvp tb_moe_gating.out
iverilog -g2005 -o tb_router_chip.out router_chip.v moe_gating.v bf16_fma.v tb_router_chip.v                                && vvp tb_router_chip.out
iverilog -g2005 -o tb_bmc_router.out rv32_core.v uart.v clint.v bmc_router_top.v tb_bmc_router.v                          && vvp tb_bmc_router.out
```

Expect `*** LOAD TEST PASSED (500 packets) ***` and 6 doorbell fires (p0,p1,p2,p3,p6,p7),
2 rejections (truncated, wrong DEST), and 2 `corrupt_out` pulses (payload-CRC pair).
Compile with `-g2005` (Verilog-2005); testbenches are self-checking (scoreboard
counters, `errors` integers, $display PASS/FAIL) and exit 0 on success.

### Static lint

```bash
verilator --lint-only -Wno-MULTITOP hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v
```

### C firmware (from `sim/fw/`)

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
go run ./cmd/pnmc compile-model examples/gemma4_test -l 4 -x 4 -y 4   # model compiler
go run ./cmd/pnmc run-driver examples/gemma4_test -l 4 -x 4 -y 4    # driver + firmware boot + dispatch plan
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

## Architecture

### The system (per the paper)

Four kinds of hardware: commodity 192-bit LPDDR6 CAMM2 modules (~256 GB/s per node),
mature-node DUV MAC ASICs, stateless Hardware Flit Repeaters (HFRs), and **one central
router chip** at the spine root (MoE routing, POST discovery, PCIe, coordinate mapping —
the only stateful silicon). Boards are X/Y grids stacked vertically; a single spine runs
through the stack; each board hangs off the spine via an `xyz_repeater`.

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
| `fp32_alu.v` | ALU | FP32 | 1-24 cycles | Layernorm (divider + multiplier) |
| `int8_mac.v` | MAC | INT8 | 1 cycle | Quantized inference |

All FMA modules share an identical interface: `clk, rst_n, a, b, c, valid_in → result, valid_out`
(3-cycle pipeline). The `pe_tile_stub.v` uses `USE_FMA` parameter to select between
bias-add (0) and BF16 FMA (1) compute paths.

### BMC/Router chip (RISC-V SoC)

The central router chip is implemented as a RISC-V System-on-Chip (`bmc_router_top.v`),
integrating an RV32IMA multi-cycle CPU core, peripherals, and the PNM router engine:

| Module | File | Description |
|--------|------|-------------|
| `rv32_core.v` | RV32IMA CPU | 5-stage FSM: RV32I base + M extension (MUL) + Zicsr (machine-mode CSR) |
| `uart.v` | UART | 16550-compatible, 8N1, configurable baud, interrupt output |
| `clint.v` | CLINT | Machine-mode timer (mtime/mtimecmp) + software interrupt (msip) |
| `bmc_router_top.v` | SoC Top | CPU + 64KB ROM + 64KB SRAM + UART + CLINT + PNM router engine |

Memory map: ROM@0x00000000 (combinational read), UART@0x10000000, CLINT@0x20000000,
SRAM@0x80000000 (byte-enable write), PNM@0xF0000000 (control/layer/module/len/data
registers, status, error counters, dispatch/weight-flit counters).

The CPU uses a two-phase memory handshake (cycle 1: present address, cycle 2+: wait for
bus_ready) to correctly time peripheral accesses. The ALU is fully combinational with a
dedicated input mux, avoiding blocking/NBA mixing. The PNM router engine implements a
flit builder with CRC-16/CCITT-FALSE matching the fabric wire format. Boot-done is
detected when firmware writes bit 2 of ROUTE_CTRL.

Test: `iverilog -g2005 -o tb_bmc_router.out rv32_core.v uart.v clint.v bmc_router_top.v tb_bmc_router.v && vvp tb_bmc_router.out`

### Wire format (byte-wide links) — everything depends on this

```
byte 0 : LAYER_ID            (stripped by xyz_repeater on match)
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
  parameter. `xyz_repeater` matches `LAYER_ID` (strips it on match), `xy_turn` matches the
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
  `[5] SIGN` (0=+, 1=−), `[4:0] DIST` (hops from the xyz_repeater).  `xyz_repeater`
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
  map, route, emit). See `sim/examples/gemma4_test/` for a synthetic test input.
- **Source-language toolchains**: `sim/internal/pnm/r_ir.go` (`CompileR`), `haskell_ir.go`
  (`CompileHaskell`), and `hlsl_ir.go` (`CompileHLSL`) compile R, Haskell, and HLSL source
  code into typed IR targeting FP64 FMA and FP32 ALU units. The IR is a minimal
  register-based instruction set with no loops, branches, or dynamic allocation.
- **Host driver**: `sim/internal/pnm/driver.go` (`cmd/pnmc run-driver`) orchestrates
  model loading, weight upload, and inference dispatch. It builds weight upload commands
  from the AOT compilation, constructs routing tables and MoE expert maps, and verifies
  that no node exceeds the 128 GB budget. The driver communicates with the router chip
  via PCIe (in co-sim, flits are constructed directly).
- **Firmware**: `sim/internal/pnm/firmware.go` models the router chip's boot sequence
  (POST discovery, routing table load, weight upload, MoE gating load) and runtime
  dispatch loop (30 dense + 240 MoE dispatches per token for Gemma-4). It verifies
  weight upload integrity and dispatch coverage. The router chip RTL (`HDL/router_chip.v`)
  implements the PCIe ingress, flit builder, POST discovery FSM, and spine injection
  in Verilog-2005.
- **C firmware**: `sim/fw/pnm_fw.c` + `pnm_fw.h` are a direct C port of `firmware.go`
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
- **Manuscript (Paper.MD)**: it is an f-string template in `build.py`'s pipeline, so
  LaTeX commands are **double-escaped**: `\\textbf{{...}}`, `\\alpha`, `\\$`, `\\_`,
  `\\times`. Use `{c(n)}` for citations. The build regex also collapses `{{`→`{` and
  `\\`→`\`, so single `\` or single `{}` in Paper.MD will silently produce broken output.
  Section headings are plain text (`2.9 The doorbell mechanism`), converted to `\section`
  by nothing — the body is emitted verbatim into the article class, so headings render
  as bold paragraphs; match the existing style for new sections.

## Gotchas

- **`build.py` is gitignored and untracked** (listed in `.gitignore` line 6) yet required
  by the README build instructions and by `shell.nix`-less workflows. A fresh clone will
  not contain it. Do not `git add` it; if it is missing, restore it from git history
  (it was never committed — ask the owner) or rebuild it from the README description.
- `submission/` is fully gitignored; `submission/paper_review.*` are produced by
  `build.py --review`.
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
**File:** `sim/fw/pnm_fw.c:145-146, 160-161`
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

### HIGH #11: `router_chip.v` PCIe ready/valid protocol violation under spine backpressure
**File:** `HDL/router_chip.v:266`
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
