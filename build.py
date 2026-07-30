#!/usr/bin/env python3
"""Build a single DOCX from Paper.MD using standard LaTeX."""
from __future__ import annotations
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TITLE = "Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing"

# ── References (Chicago style, same as refs.py) ──────────────────────────
REFS = [
    "W. A. Wulf, S. A. McKee. Hitting the memory wall: implications of the obvious. \\textit{ACM SIGARCH Computer Architecture News}. Vol. 23, pg. 20-24, 1995.",
    "J. Choquette. Nvidia hopper h100 gpu: scaling performance. \\textit{IEEE Micro}. Vol. 43, pg. 9-17, 2023.",
    "N. Shazeer, A. Mirhoseini, K. Maziarz, A. Davis, Q. Le, G. Hinton, J. Dean. Outrageously large neural networks: the sparsely-gated mixture-of-experts layer. \\textit{arXiv preprint} arXiv:1701.06538, 2017.",
    "W. Fedus, B. Zoph, N. Shazeer. Switch transformers: scaling to trillion parameter models with simple and efficient sparsity. \\textit{Journal of Machine Learning Research}. Vol. 23, pg. 1-39, 2022.",
    "S. Williams, A. Waterman, D. Patterson. Roofline: an insightful visual performance model for multicore architectures. \\textit{Communications of the ACM}. Vol. 52, pg. 65-76, 2009.",
    "J. Backus. Can programming be liberated from the von Neumann style? a functional style and its algebra of programs. \\textit{Communications of the ACM}. Vol. 21, pg. 613-641, 1978.",
    "M. D. McIlroy, E. N. Pinson, B. A. Tague. Unix time-sharing system: forward. \\textit{Bell System Technical Journal}. Vol. 57, pg. 1899-1904, 1978.",
    "J. Liedtke. On micro-kernel construction. Proceedings of the fifteenth ACM symposium on Operating systems principles. pg. 237-250, 1995.",
    "G. Klein, K. Elphinstone, G. Heiser, J. Andronick, D. Cock, P. Derrin, D. Elkaduwe, K. Engelhardt, R. Kolanski, M. Norrish, T. Sewell, H. Tuch, S. Winwood. seL4: formal verification of an OS kernel. Proceedings of the ACM SIGOPS 22nd symposium on Operating systems principles. pg. 207-220, 2009.",
    "N. P. Jouppi et al. In-datacenter performance analysis of a tensor processing unit. Proceedings of the 44th annual international symposium on computer architecture. pg. 1-12, 2017.",
    "J. B. Dennis. First version of a data flow procedure language. Programming Symposium. pg. 362-376, 1974.",
    "I. Barron, P. Cavill, D. May, P. Wilson. Transputer does 5 or more MIPS even when not used in parallel. \\textit{Electronics}. Vol. 56, pg. 109-115, 1983.",
    "W. J. Dally, C. L. Seitz. Deadlock-free message routing in multiprocessor interconnection networks. \\textit{IEEE Transactions on Computers}. Vol. C-36, pg. 547-553, 1987.",
    "W. J. Dally, C. L. Seitz. The torus routing chip. \\textit{Distributed Computing}. Vol. 1, pg. 187-196, 1986.",
    "JEDEC Solid State Technology Association. High bandwidth memory (HBM) DRAM standard. JESD235D, 2021.",
    "JEDEC Solid State Technology Association. Compression attached memory module (CAMM2) common standard. JESD318, 2023.",
    "JEDEC Solid State Technology Association. Low power double data rate 6 (LPDDR6) SDRAM standard. JESD209-6, 2025.",
    "C. Lattner et al. MLIR: scaling compiler infrastructure for domain specific computation. 2021 IEEE/ACM International Symposium on Code Generation and Optimization (CGO). pg. 2-14, 2021.",
    "Message Passing Interface Forum. MPI: a message-passing interface standard, version 4.0. 2021.",
    "CERN. CERN open hardware licence version 2 - strongly reciprocal (CERN-OHL-S). 2020.",
]

def main():
    md = ROOT / "Paper.MD"
    text = md.read_text(encoding="utf-8")

    # Strip metadata header
    start = text.find("Abstract")
    if start >= 0:
        text = text[start:]

    # {c(n)} → \cite{n}
    text = re.sub(r'\{c\(([^)]+)\)\}', r'\\cite{\1}', text)

    # Collapse doubled braces from f-string escaping: {{ → {, }} → }
    text = re.sub(r'\{\{', '{', text)
    text = re.sub(r'\}\}', '}', text)

    # Fix common escaped sequences: \\X → \X
    text = text.replace("\\\\", "\\")

    # Build thebibliography
    bib = "\n".join(f"\\bibitem{{{i+1}}} {r}" for i, r in enumerate(REFS))

    latex = rf"""\documentclass[10pt,twocolumn]{{article}}
\usepackage[margin=0.85in]{{geometry}}
\usepackage{{times}}
\usepackage{{setspace}}
\singlespacing
\usepackage{{amsmath,amssymb}}
\usepackage{{array}}
\usepackage{{booktabs}}
\usepackage[hidelinks]{{hyperref}}
\usepackage{{microtype}}

\setlength{{\parskip}}{{0.3em}}
\setlength{{\parindent}}{{0em}}

\title{{{TITLE}}}
\author{{Bowen Gu}}
\date{{July 30, 2026}}

\begin{{document}}
\maketitle
\thispagestyle{{empty}}

{text}

\begin{{thebibliography}}{{20}}
{bib}
\end{{thebibliography}}

\end{{document}}
"""

    tex_path = ROOT / "submission" / "paper.tex"
    tex_path.parent.mkdir(parents=True, exist_ok=True)
    tex_path.write_text(latex, encoding="utf-8")

    # Compile PDF
    for _ in range(2):
        r = subprocess.run(
            ["pdflatex", "-interaction=nonstopmode", "-halt-on-error",
             str(tex_path)],
            cwd=tex_path.parent,
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(r.stdout[-3000:])
            print(r.stderr[-3000:])
            sys.exit(1)

    # Convert to DOCX via pandoc (latex → docx)
    docx_path = tex_path.with_suffix(".docx")
    subprocess.run(
        ["pandoc", str(tex_path), "-o", str(docx_path),
         "-f", "latex", "-t", "docx"],
        cwd=tex_path.parent,
        capture_output=True, text=True,
    )
    print(f"Wrote {docx_path.name}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
