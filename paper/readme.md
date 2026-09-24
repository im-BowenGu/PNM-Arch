# The Paper

> *Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory
> Architecture using DUV ASICs and Deterministic Routing*

## Manuscript

| File | Description |
|------|-------------|
| [`Paper.MD`](Paper.MD) | Source of truth (Markdown with LaTeX-escape conventions) |
| [`TLDR_Paper.md`](TLDR_Paper.md) | Architecture brief |
| `build.py` | Build pipeline → `submission/*.docx` |

## Building the paper

Requires [Nix](https://nixos.org) with flake support (`nix develop`).

```bash
cd paper
nix develop                      # enter environment (pdflatex, pandoc)
python3 build.py                 # → submission/paper.docx + .pdf + .tex
python3 build.py --review        # → submission/paper_review.pdf (11pt single-column)
```

`build.py` strips everything before the `Abstract` header, converts
`{c(n)}` → `\cite{n}`, runs pdflatex twice, then pandoc to DOCX.
The bibliography is hardcoded in `build.py` (Chicago style, 30 entries).

## What the paper proves

Five properties are machine-checked on every co-simulation run:

1. **Byte-exact delivery** — bytes delivered to each node equal bytes
   injected; no loss, no duplication, no reorder
2. **Zero drops and zero misroutes** — every injected flit reaches its
   declared destination; dimension-order routing leaves no residual
3. **Doorbell accounting** — hardware verdicts (activations, refusals,
   `corrupt_out` pulses) match the three-condition fire logic message
   by message
4. **Kernel correctness** — each resident kernel executes on what the
   hardware delivered and matches the golden model
5. **Latency bounds** — sweep checks every packet against the closed
   form (hop count × per-hop delay + serialization) exactly

## Verifying the fabric (paper proofs)

The paper-verification subset of HDL testbenches lives in `paper/HDL/`.
These are the exact tests cited in the paper:

```bash
cd paper/HDL

# 500-packet load test: byte-exact delivery, zero drops, zero misroutes
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out

# doorbell discipline: six activations, two refusals, two corrupt_out pulses
# (paper/HDL is regenerated in full from HDL/ by paper/build.py, so every
# compute-unit primitive is bundled here and the command runs in place)
iverilog -g2005 -o tb_doorbell.out core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v && vvp tb_doorbell.out

# full fabric smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && vvp tb_fabric.out
```

Expect `*** LOAD TEST PASSED (500 packets) ***` and 6 doorbell fires
(2 rejections, 2 `corrupt_out` pulses). The full test suite lives in
[`HDL/`](../HDL/) (30+ testbenches).

## License

The `paper/` directory (manuscript, build pipeline, submission artifacts)
is licensed under [CC BY-SA 4.0](../LICENSE). The HDL testbenches in
`paper/HDL/` are [CERN-OHL-S v2](../LICENSE).
