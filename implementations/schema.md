# PNM Assembly Schema (`pnm-assembly/v1`)

The assembly schema composes verified modules from `HDL/` into a complete,
simulable assembly: a PCB model with chips, traces, clock gating, reset
synchronization, and external connectors. It is the RTL analogue of a board
netlist — components are silicon, connections are copper, and traces carry
the paper's §2.18 electrical profiles.

## File format

One JSON file per assembly. See `boards/*.json` for working examples.

```json
{
  "schema":   "pnm-assembly/v1",
  "name":     "node_board",
  "description": "One compute node: ingress trace, MAC stub, egress trace",
  "clock":    { "period_ns": 10 },
  "reset_cycles": 4,
  "run_cycles": 2000,

  "external": [
    { "name": "clk",       "dir": "input",  "width": 1 },
    { "name": "in_tdata",  "dir": "input",  "width": 8 },
    { "name": "out_tdata", "dir": "output", "width": 8 }
  ],

  "components": [
    { "instance": "u_in_trace", "module": "pcb_link",
      "params": { "WIDTH": 8, "DELAY_NS": 40 } }
  ],

  "connections": [
    { "from": "ext.clk", "to": ["u_in_trace.clk"] },
    { "from": "u_in_trace.rx_data", "to": ["ext.out_tdata"] }
  ],

  "tieoffs": [
    { "to": "u_pe.routing_bitmap", "value": "11'h080" }
  ]
}
```

## Sections

### `schema`, `name`, `description`
Identity. `schema` must be exactly `pnm-assembly/v1`; the builder rejects
other versions rather than guessing.

### `clock.period_ns`, `reset_cycles`, `run_cycles`
Simulation envelope emitted into the generated testbench: clock half-period
is `period_ns/2` ns, `rst_n` is held low for `reset_cycles` rising edges, and
the simulation ends after `run_cycles` cycles with a PASS banner.

### `external[]`
Top-level ports of the generated wrapper. Each entry: `name` (Verilog
identifier), `dir` (`input`|`output`), `width` (bits). External inputs drive
internal loads; internal drivers feed external outputs. Referenced from
connections as `ext.<name>`.

### `components[]`
Silicon instances. Each entry:
- `instance`: unique Verilog identifier for the instantiation.
- `module`: a module defined somewhere under `HDL/`. The builder scans all
  `HDL/*.v` files, parses ANSI port lists and parameters, and resolves the
  module to its source file automatically.
- `params` (optional): synthesis-time overrides. Values may be numbers
  (`40`) or raw Verilog literals (`"8'h07"`). Numeric params are also used
  to evaluate parameterized port widths (`[WIDTH-1:0]` with `WIDTH=8`).

Traces are components too: `pcb_link`, `pcb_si_link`, `optical_link`, and
`pcb_triple_link` are the copper/fiber between chips. A `pcb_link` with
`DELAY_NS=40, WIDTH=8` *is* the 40 mm motherboard profile of Paper §2.18.

### `connections[]`
Point-to-point nets. `from` is a single driver endpoint
(`<instance>.<port>` or `ext.<name>`); `to` is a list of load endpoints.
The builder enforces:
- endpoints exist (port names checked against parsed modules),
- direction legality (component output / external input drives;
  component input / external output loads),
- width equality (parameter-aware),
- one driver per load port.

Unconnected component inputs are reported as warnings so dangling brings-up
surface early; unconnected outputs are legal and left floating.

### `tieoffs[]`
Constant drivers for configuration inputs: `{ "to": "<inst>.<port>",
"value": "<verilog literal>" }`. A tieoff and a connection targeting the
same port is rejected.

## Generated artifacts

`build_asm.py boards/<x>.json` writes into `implementations/build/<x>/`:

| Artifact | Contents |
|----------|----------|
| `<x>_top.v` | Wrapper: external ports, wires, tieoffs, instances |
| `tb_<x>.v` | Clock/reset generator, idle-run testbench with PASS banner |
| `filelist.f` | Source files (+ `-I` include dir) for iverilog/verilator |
| `<x>_top.out` | Compiled simulation binary |

Exit code 0 means: schema valid, all endpoints resolved, compile clean,
simulation ran to completion. The same filelist feeds
`verilator --lint-only` via `--lint`.

## Conventions honored

The schema assumes the repository's link convention
(`*_data/_valid/_sop/_eop/_ready` groups, `clk`/`rst_n` first), but nothing
is hard-coded: any module with parseable ANSI ports participates, including
the DFT primitives (`rst_sync.v`, `clk_gate.v`) — gate a domain by
instantiating `clk_gate` and driving downstream `clk` ports from its `gclk`;
 synchronize resets with `rst_sync` chains.
