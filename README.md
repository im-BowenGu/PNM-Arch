# PNM-Arch Paper

Manuscript: *Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing*

Submitted to the NHSJS (National High School Journal of Science).

## Directory structure

| Path | Contents |
|------|----------|
| `Paper.MD` | Manuscript source (master copy) |
| `submission/` | Build artifacts for NHSJS submission |
| `submission/build_manuscripts.py` | Python build script → LaTeX, PDF, DOCX, Markdown |
| `submission/refs.py` | Reference database (20 entries) |
| `HDL/` | Verilog modules: HFR, ingress gate, XY turn, node eject, testbenches |
| `shell.nix` | Nix environment with pdflatex + pandoc + poppler-utils |

## Build

```bash
nix-shell
python3 submission/build_manuscripts.py
```

Output in `submission/`: PDF, LaTeX, DOCX (standard + online citations), Markdown.
