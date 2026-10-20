# implementations/ — board-level assemblies of verified HDL modules

This directory turns the repository's module library into *products*: JSON
assembly schemas (`schema.md`) describe a PCB — which silicon sits where,
which traces join them, how clock gating and reset synchronization are
wired — and `build_asm.py` elaborates that description into a complete,
simulable Verilog assembly using only modules already verified under
`HDL/`.

```
implementations/
├── README.md          this file
├── schema.md          the pnm-assembly/v1 format specification
├── build_asm.py       schema → validated wrapper + testbench + iverilog/vvp run
├── boards/*.json      example assemblies
└── build/             generated artifacts (gitignored)
```

## Quick start

```bash
# elaborate, compile, and smoke-run a board (exit 0 = assembly is sound)
python3 implementations/build_asm.py implementations/boards/node_board.json

# static check only (verilator --lint-only on the generated top)
python3 implementations/build_asm.py implementations/boards/node_board.json --lint

# emit wrapper + testbench without running iverilog (schema + port validation only)
python3 implementations/build_asm.py implementations/boards/node_board.json --no-sim

# keep a VCD waveform next to the artifacts
python3 implementations/build_asm.py implementations/boards/node_board.json --waves

# custom output directory
python3 implementations/build_asm.py <schema.json> -o /tmp/myboard
```

## What the builder guarantees

Every connection in an assembly is checked before a line of Verilog is
emitted:

- **existence** — endpoint ports are matched against ANSI port lists parsed
  from the actual `HDL/*.v` sources, so a renamed port fails loudly;
- **direction** — component outputs / external inputs drive; component
  inputs / external outputs load; anything else is rejected;
- **width** — parameter-aware: `[WIDTH-1:0]` with `{"WIDTH": 8}` evaluates
  to 8 bits and mismatches fail;
- **single driver** — no load port may be connected twice or both tied and
  driven.

Dangling component inputs produce warnings naming each one. The generated
testbench runs the assembly for `run_cycles` after reset release and prints
a PASS banner; any elaboration or runtime fault exits nonzero.

## Modeling PCBs

Copper is modeled with the same modules the paper's §2.18 profiles use —
traces are components, not special cases:

| Trace population | Component | Profile |
|------------------|-----------|---------|
| Motherboard P2P (~40 mm) | `pcb_link` | `DELAY_NS=40` |
| CAMM2 socket escape (~20 mm) | `pcb_link` | `DELAY_NS=20` |
| Spine mezzanine (~5 mm) | `pcb_link` | `DELAY_NS=5`, `WIDTH=128` |
| Electrical channel w/ SI | `pcb_si_link` | loss/crosstalk/jitter model |
| Inter-chassis fiber | `optical_link` | async CDC + propagation |

See `boards/node_board.json` for a complete worked example: two timed
traces around a MAC stub whose clock passes through a `clk_gate` cell and
whose reset crosses domains through `rst_sync` — i.e., the DFT discipline
of Paper §4.6 expressed as ordinary wiring.

## Node compute variants

`HDL/core/node.v` is the compute node of the node network (one MoE expert
pass). Its `CU_TYPE` parameter selects the embedded numeric ASIC behind a
shared accumulate interface and FSM, so the same node source builds as
different products:

| Board | `CU_TYPE` / `WIDTH` | Engine |
|-------|---------------------|--------|
| `boards/node_bf16.json` | 0 / 16 | BF16 expert (gate/up → swiglu → down) |
| `boards/node_fp32.json` | 2 / 32 | FP32 MAC (identity activation) |
| `boards/node_int8.json` | 4 / 8 | INT8 MAC, INT32 accumulate |
| `boards/node_ternary.json` | 8 / 8 | BitNet b1.58 ternary {-1,0,+1} x INT8 MAC |
| `boards/node_fp4.json`  | 6 / 8 | FP4 (E2M1) MAC, INT32 accumulate |
| `boards/node_dual_mem.json` | 0 / 16 | Reference node: BF16 expert + dual-module memory (`node_mem.v`, CHANNELS=2 = 2 x 64 GB 192-bit LPCAMM2, 384-bit, ~512 GB/s) |

Each instantiates `rst_sync` + `clk_gate` + `node` and builds/lints/sims
clean. The BF16 (`CU_TYPE 0`) and INT8 (`CU_TYPE 4`) expert passes are
bit-exact validated by `HDL/core/node_reference_test.py` (see `--cu`); the
other formats are validated by their unit testbenches.

## Adding an assembly

1. Copy `boards/node_board.json` and change `name`.
2. List components (any non-testbench module in `HDL/` participates) with
   their parameter overrides.
3. Connect endpoints; consult warnings for dangling inputs.
4. Run the builder; iterate until exit 0.
5. Commit the schema — it regenerates deterministically from sources.
