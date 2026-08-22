{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "pnm-paper-env";
  packages = with pkgs; [
    # LaTeX for PDF build (needs pdflatex, bibtex, article class)
    texlive.combined.scheme-medium
    # Document conversion (md → docx)
    pandoc
    # PDF metadata (page count check)
    poppler-utils
    # Verilog simulation (proves no dropped packets under backpressure)
    iverilog
    # Verilog static lint
    verilator
    # C compiler (C firmware port for MCU targets: sim/fw/)
    gcc
    # CPython for the gitignored paper build pipeline (build.py, stdlib only)
    python3
    # Go for the co-sim harness (sim/cmd/* + sim/internal/*: stimulus generation,
    # virtual execution units, delivery verification, source-language toolchains;
    # stdlib only, no runtime deps)
    go
  ];

  shellHook = ''
    echo "PNM Paper Environment"
    echo "  python3 build.py          # build submission/paper.docx + .pdf"
    echo "  go test ./internal/pnm/   # run all tests"
    echo "  cd HDL && iverilog ...    # run HDL testbenches"
  '';
}
