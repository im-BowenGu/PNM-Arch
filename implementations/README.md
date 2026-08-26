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

## Adding an assembly

1. Copy `boards/node_board.json` and change `name`.
2. List components (any non-testbench module in `HDL/` participates) with
   their parameter overrides.
3. Connect endpoints; consult warnings for dangling inputs.
4. Run the builder; iterate until exit 0.
5. Commit the schema — it regenerates deterministically from sources.
