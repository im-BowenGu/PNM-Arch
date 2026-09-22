#!/usr/bin/env python3
"""Build a single DOCX from Paper.MD using standard LaTeX."""
from __future__ import annotations
import re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TITLE = "Breaking the HBM wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing"

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
    "Deloitte. Why AI's next phase will likely demand more computational power, not less. \\textit{Deloitte Insights, TMT Predictions 2026}. 2025.",
    "Gartner. Gartner says AI-optimized IaaS is poised to become the next growth engine for AI infrastructure. Press release, October 15, 2025.",
    "McKinsey \\& Company. The cost of compute: a \\$7 trillion race to scale data centers. 2025.",
    "R. Raghuram, S. Wang. How to win the largest market in AI. \\textit{a16z}. 2026.",
    "TrendForce. Memory spot price update: DDR5 prices up 307\\% since September as module costs poised to surge. November 19, 2025.",
    "H. Menon. Inference curves: bandwidth, not compute, is the primary serving knob. \\textit{SemiAnalysis InferenceX}. 2026.",
    "Y. Yu, et al. Efficient MoE serving in the memory-bound regime: balance activated experts, not tokens. \\textit{arXiv preprint} arXiv:2512.09277, 2025.",
    "B. Gu. Breaking the HBM wall: Verilog HDL sources, Go co-simulation harness, and manuscript repository. https://github.com/im-BowenGu/PNM-Arch, 2026.",
    "Linux Foundation. Linux kernel RISC-V architecture documentation: NOMMU (no-MMU) support. https://www.kernel.org/doc/html/latest/arch/riscv/, 2025.",
    "JEDEC Solid State Technology Association. Double data rate 5 (DDR5) SDRAM standard. JESD79-5C, 2024.",
]

TOP_SECTIONS = {
    "Abstract": "abstract",
    "Introduction": "introduction",
    "Methods": "methods",
    "Results": "results",
    "Discussion": "discussion",
    "Conclusion": "conclusion",
    "Acknowledgments": "acknowledgments",
}


def link_sections(text: str) -> str:
    """Turn every `Section 2.9` / `Sections 2.15 and 3.5` mention into
    hyperref links pointing at the heading anchors."""
    num = r'\d+(?:\.\d+)*'
    pat = re.compile(rf'\b(Sections?) ((?:{num})(?:\s*(?:,|and|, and)\s*(?:{num}))*)')

    def repl(m):
        word, tail = m.group(1), m.group(2)
        out = []
        for part in re.split(rf'({num})', tail):
            if re.fullmatch(num, part):
                out.append(f'\\hyperref[sec:{part}]{{{part}}}')
            else:
                out.append(part)
        return f'{word} ' + ''.join(out)

    return pat.sub(repl, text)


def label_headings(text: str) -> str:
    """Convert heading lines into starred LaTeX sections with labels so
    internal links and PDF/DOCX navigation work."""
    lines = text.split('\n')
    out = []
    numbered = re.compile(r'^(\d+(?:\.\d+)+) (.+)$')
    for i, line in enumerate(lines):
        prev_blank = i == 0 or lines[i - 1].strip() == ''
        next_blank = i == len(lines) - 1 or lines[i + 1].strip() == ''
        if line.strip() in TOP_SECTIONS and prev_blank:
            slug = TOP_SECTIONS[line.strip()]
            out.append(f'\\section*{{{line.strip()}}}\\label{{sec:{slug}}}')
        elif prev_blank and next_blank and (m := numbered.match(line)):
            depth = m.group(1).count('.')
            cmd = 'subsection*' if depth == 1 else 'subsubsection*'
            out.append(f'\\{cmd}{{{line}}}\\label{{sec:{m.group(1)}}}')
        else:
            out.append(line)
    return '\n'.join(out)


def latex_source(text: str, review: bool) -> str:
    """Wrap the manuscript body in a LaTeX document.

    Default: 10pt, two-column submission copy. Review: 11pt, single column,
    wide margins, ~1.5 line spacing for annotating.
    """
    bib = "\n".join(f"\\bibitem{{{i+1}}} {r}" for i, r in enumerate(REFS))

    if review:
        docclass = "11pt,onecolumn"
        geometry = "margin=1.5in"
        spacing = "\\setstretch{1.5}"
        date = "August 23, 2026 (review copy)"
        head = r"""
\usepackage{fancyhdr}
\pagestyle{fancy}
\fancyhf{}
\fancyhead[L]{\footnotesize Review copy}
\fancyhead[R]{\footnotesize Breaking the HBM wall}
\fancyfoot[C]{\footnotesize\thepage}
"""
    else:
        docclass = "10pt,twocolumn"
        geometry = "margin=0.85in"
        spacing = "\\singlespacing"
        date = "August 23, 2026"
        head = ""

    return rf"""\documentclass[{docclass}]{{article}}
\usepackage[{geometry}]{{geometry}}
\usepackage{{times}}
\usepackage{{setspace}}
{spacing}
\usepackage{{amsmath,amssymb}}
\usepackage{{array}}
\usepackage{{booktabs}}
\usepackage[hidelinks]{{hyperref}}
\usepackage{{microtype}}
{head}
\setlength{{\parskip}}{{0.3em}}
\setlength{{\parindent}}{{0em}}

\title{{{TITLE}}}
\author{{Bowen Gu}}
\date{{{date}}}

\begin{{document}}
\maketitle
\thispagestyle{{empty}}

{text}

\begin{{thebibliography}}{{{len(REFS)}}}
{bib}
\end{{thebibliography}}

\end{{document}}
"""


def sync_hdl() -> None:
    """Refresh the paper/HDL verification mirror from the live HDL/ tree.

    The paper cites testbenches in paper/HDL/ (§4.6).  Tracking a manual
    copy lets it drift (it already diverged in doorbell.v and pe_tile_stub.v);
    regenerating the mirror at build time guarantees the paper proof runs
    the exact RTL the co-simulation harness verifies.
    """
    src = ROOT.parent / "HDL"
    dst = ROOT / "HDL"
    if not src.is_dir():
        return  # paper build from a checkout without HDL: leave mirror alone
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("*.out", "*.vcd"))


def main():
    review = "--review" in sys.argv
    sync_hdl()  # paper/HDL is generated, not tracked
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

    text = link_sections(text)
    text = label_headings(text)

    latex = latex_source(text, review)

    tex_path = ROOT / "submission" / ("paper_review.tex" if review else "paper.tex")
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

    if review:
        print(f"Wrote {tex_path.with_suffix('.pdf').name}")
        return 0

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
