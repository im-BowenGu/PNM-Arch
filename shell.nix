{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "pnm-paper-env";
  packages = with pkgs; [
    # LaTeX for PDF build
    texliveSmall
    # Document conversion (md → docx)
    pandoc
    # PDF metadata (page count check)
    poppler-utils
    # Verilog simulation (proves no dropped packets under backpressure)
    iverilog
    # Verilog static lint
    verilator
    # CPython for the gitignored paper build pipeline (build.py, stdlib only)
    python3
    # Go for the co-sim harness (sim/cmd/* + sim/internal/*: stimulus generation,
    # virtual execution units, delivery verification; stdlib only, no runtime deps)
    go
  ];
}
