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
  ];

  shellHook = ''
    echo "Paper build environment"
    echo "  pdflatex: $(command -v pdflatex)"
    echo "  pandoc:   $(command -v pandoc)"
    echo "  pdfinfo:  $(command -v pdfinfo)"
    echo ""
    echo "Build: cd submission && python3 build_manuscripts.py"
  '';
}
