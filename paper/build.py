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
    "F. Devaux. The true processing in memory accelerator. \\textit{2019 IEEE Hot Chips 31 Symposium (HCS)}. pg. 1-24, 2019.",
    "Y.-C. Kwon, S. H. Lee, J. Lee, et al. A 20nm 6GB function-in-memory DRAM, based on HBM2 with a 1.2TFLOPS programmable computing unit using bank-level parallelism, for machine learning applications. \\textit{2021 IEEE International Solid-State Circuits Conference (ISSCC)}. pg. 350-352, 2021.",
    "J. H. Kim, S. Kang, S. Lee, et al. Aquabolt-XL: Samsung HBM2-PIM with in-memory processing for ML accelerators and beyond. \\textit{2021 IEEE Hot Chips 33 Symposium (HCS)}. pg. 1-26, 2021.",
    "J. H. Kim, et al. Aquabolt-XL HBM2-PIM, LPDDR5-PIM with in-memory processing, and AXDIMM with acceleration buffer. \\textit{IEEE Micro}. Vol. 42, pg. 20-30, 2022.",
    "S. Ghose, A. Boroumand, J. S. Kim, J. Gomez-Luna, O. Mutlu. Processing-in-memory: A workload-driven perspective. \\textit{IBM Journal of Research and Development}. Vol. 63, pg. 3:1-3:19, 2019.",
    "J. Ahn, S. Yoo, O. Mutlu, K. Choi. PIM-enabled instructions: A low-overhead, locality-aware processing-in-memory architecture. \\textit{Proceedings of the 42nd Annual International Symposium on Computer Architecture (ISCA '15)}. pg. 336-348, 2015.",
    "J. Gomez-Luna, I. E. Hajj, I. Fernandez, C. Giannoula, G. F. Oliveira, O. Mutlu. Benchmarking a new paradigm: Experimental analysis and characterization of a real processing-in-memory system. \\textit{IEEE Access}. Vol. 10, pg. 52565-52608, 2022.",
    "T. Mann. Why did Nvidia really drop \\$20B on Groq? \\textit{The Register}. December 31, 2025.",
    "Cerebras Systems. CS-3: the WSE-3 wafer-scale engine. Vendor product documentation. 2025.",
    "T. P. Morgan. Taalas etches AI models onto transistors to rocket-boost inference. \\textit{The Next Platform}. February 19, 2026.",
    "T. Mann. AMD acquires AI chip startup Taalas to boost inference performance by etching models into silicon. \\textit{The Register}. August 6, 2026.",
    "S. Ma, H. Wang, L. Ma, L. Wang, W. Wang, S. Huang, L. Dong, R. Wang, J. Xue, F. Wei. The era of 1-bit LLMs: all large language models are in 1.58 bits. \\textit{arXiv preprint} arXiv:2402.17764, 2024.",
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


def convert_tables(text: str) -> str:
    """Turn `Table N. caption` + pipe rows into booktabs tabularx floats.

    Must run last (after brace/backslash collapsing): the emitted LaTeX is
    final --- single braces, literal `\\\\` row separators.
    """
    lines = text.split("\n")
    out = []
    cap_re = re.compile(r"^Table (\d+)\. (.*)$")
    i = 0
    while i < len(lines):
        m = cap_re.match(lines[i])
        j = i + 1
        if m and j < len(lines) and lines[j].strip() == "":
            j += 1
        rows = []
        if m:
            while j < len(lines) and lines[j].strip() and "|" in lines[j]:
                cells = [c.strip() for c in lines[j].split("|")]
                if not all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
                    rows.append(cells)
                j += 1
        if not m or len(rows) < 2:
            out.append(lines[i])
            i += 1
            continue
        num, caption = m.group(1), m.group(2)
        ncol = max(len(r) for r in rows)
        rows = [r + [""] * (ncol - len(r)) for r in rows]
        weights = []
        for c in range(ncol):
            w = max(len(r[c]) for r in rows)
            weights.append(min(max(w, 6), 64))
        total = sum(weights)
        specs = []
        for w in weights:
            h = ncol * w / total
            specs.append(f">{{\\hsize={h:.4f}\\hsize}}X")
        wide = ncol >= 4
        env = "table*" if wide else "table"
        target = "\\textwidth" if wide else "\\columnwidth"
        body = [
            f"\\begin{{{env}}}[t]",
            "\\centering",
            "\\footnotesize",
            f"\\caption{{{caption}}}\\label{{tab:{num}}}",
            f"\\begin{{tabularx}}{{{target}}}{{{''.join(specs)}}}",
            "\\toprule",
            " & ".join(rows[0]) + " \\\\",
            "\\midrule",
        ]
        for r in rows[1:]:
            body.append(" & ".join(r) + " \\\\")
        body += ["\\bottomrule", "\\end{tabularx}", f"\\end{{{env}}}", ""]
        out.append("\n".join(body))
        i = j
    return "\n".join(out)


PDF_SUBJECT = (
    "Distributed spatial Processing-Near-Memory architecture: commodity LPDDR6 "
    "CAMM2 modules, mature-node DUV MAC ASICs, and a deterministic single-spine "
    "wormhole fabric with machine-checked transport claims"
)
PDF_KEYWORDS = (
    "Processing-Near-Memory; Wormhole Switching; Deterministic Routing; "
    "Dimension-Order Routing; Spatial Computing; LPDDR6 CAMM2; DUV ASIC; "
    "Mixture-of-Experts Transformers; Stencil Computation; Roofline Analysis; "
    "RISC-V; BMC; High-Performance Computing"
)

# Review copy defaults: a working copy for annotation, not a submission
# artifact. Double spacing and 2-inch margins leave room to write between the
# lines and in the margin; the line numbers give the reviewer something to
# cite ("see line 412").
REVIEW_SPACING = 2.0
REVIEW_MARGIN = "2.0in"


def stage_figures() -> None:
    """Copy manuscript figures next to the generated .tex.

    Paper.MD references ``../figures/fig_*.png`` (paths relative to
    ``paper/``). Rewriting those to ``figures/...`` after staging the PNGs
    into ``submission/figures/`` makes ``paper.tex`` a self-contained arXiv
    source package without editing the manuscript source.
    """
    src = ROOT / "figures"
    dst = ROOT / "submission" / "figures"
    dst.mkdir(parents=True, exist_ok=True)
    for png in sorted(src.glob("fig_*.png")):
        shutil.copy2(png, dst / png.name)


def latex_source(text: str, review: bool, spacing: float = REVIEW_SPACING,
                 margin: str = REVIEW_MARGIN) -> str:
    """Wrap the manuscript body in a LaTeX document.

    Default: 10pt, two-column submission copy. Review: 12pt, single column,
    wide margins, double line spacing and line numbers in the margin — a
    working copy for annotation, not a submission artifact.
    """
    bib = "\n".join(f"\\bibitem{{{i+1}}} {r}" for i, r in enumerate(REFS))

    if review:
        docclass = "12pt,onecolumn"
        geometry = f"margin={margin}"
        spacing = f"\\setstretch{{{spacing}}}"
        date = "October 20, 2026 (review copy — double spaced for annotation)"
        head = r"""
\usepackage{fancyhdr}
\usepackage{lineno}
\pagestyle{fancy}
\fancyhf{}
\fancyhead[L]{\footnotesize Review copy}
\fancyhead[R]{\footnotesize Breaking the HBM wall}
\fancyfoot[C]{\footnotesize\thepage}
\renewcommand{\headrulewidth}{0pt}
\linenumbers
"""
    else:
        docclass = "10pt,twocolumn"
        geometry = "margin=0.85in"
        spacing = "\\singlespacing"
        date = "October 20, 2026"
        head = ""

    return rf"""\documentclass[{docclass}]{{article}}
\usepackage[{geometry}]{{geometry}}
\usepackage{{times}}
\usepackage{{setspace}}
{spacing}
\usepackage{{amsmath,amssymb}}
\usepackage{{array}}
\usepackage{{booktabs}}
\usepackage{{graphicx}}
\usepackage{{tabularx}}
\usepackage[hidelinks]{{hyperref}}
\hypersetup{{
  pdftitle={{{TITLE}}},
  pdfauthor={{Bowen Gu}},
  pdfsubject={{{PDF_SUBJECT}}},
  pdfkeywords={{{PDF_KEYWORDS}}}
}}
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


def stage_arxiv_bundle() -> None:
    """Assemble a self-contained, upload-ready arXiv source package.

    arXiv compiles the uploaded sources itself, so the bundle must contain
    everything the manuscript references: the .tex, the figure PNGs (the
    .tex refers to them as ``figures/fig_*.png``), the license and a short
    README. The bundle is regenerated on every build so it cannot go stale.
    """
    sub = ROOT / "submission"
    bundle = sub / "arxiv"
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)

    tex = sub / "paper.tex"
    if not tex.is_file():
        return
    shutil.copy2(tex, bundle / "paper.tex")

    fig_dst = bundle / "figures"
    fig_dst.mkdir()
    for png in sorted((sub / "figures").glob("fig_*.png")):
        shutil.copy2(png, fig_dst / png.name)

    (bundle / "LICENSE").write_text(
        "Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)\n"
        "\n"
        "SPDX-License-Identifier: CC-BY-SA-4.0\n"
        "\n"
        "This arXiv source package contains the manuscript *Breaking the HBM\n"
        "wall: A Distributed Spatial Processing-Near-Memory Architecture using\n"
        "DUV ASICs and Deterministic Routing* and its figures, both under\n"
        "CC BY-SA 4.0. The full text of the license is available at\n"
        "https://creativecommons.org/licenses/by-sa/4.0/legalcode\n"
        "\n"
        "The open-hardware artifacts that back the paper (Verilog RTL, the Go\n"
        "co-simulation harness, the C firmware, the PCB designs and the\n"
        "cross-compilation toolchains) are published separately under the\n"
        "three-way license split documented in the artifact repository's\n"
        "LICENSE file (CERN-OHL-S v2 for the HDL, AGPL-3.0 for the harness\n"
        "and firmware).\n",
        encoding="utf-8")

    abstract = ""
    meta = sub / "arxiv_abstract.txt"
    if meta.is_file():
        m = re.search(r"^Abstract:\n(.*)$", meta.read_text(encoding="utf-8"), re.S | re.M)
        if m:
            abstract = m.group(1).strip() + "\n"

    (bundle / "README.md").write_text(
        "# arXiv source package\n"
        "\n"
        "Contents:\n"
        "\n"
        "- `paper.tex` — the manuscript (two-column, 10pt), self-contained:\n"
        "  the bibliography is embedded with `thebibliography`, so no `.bbl`\n"
        "  is needed; the figures are referenced as `figures/fig_*.png`.\n"
        "- `figures/` — the five manuscript figures (PNG).\n"
        "- `LICENSE` — CC BY-SA 4.0 for the manuscript and its figures.\n"
        "- `abstract.txt` — the abstract, for the arXiv metadata form.\n"
        "\n"
        "This bundle is generated by `paper/build.py`; do not edit it by hand.\n"
        "Regenerate with:\n"
        "\n"
        "```bash\n"
        "cd paper && python3 build.py\n"
        "```\n"
        "\n"
        "The open-hardware artifact that backs the paper is published at\n"
        "https://github.com/im-BowenGu/PNM-Arch -- one repository holding the\n"
        "manuscript, the RTL, the C firmware, the co-simulation harness, the\n"
        "board designs and the build system.\n"
        + (f"\nAbstract:\n\n{abstract}" if abstract else ""),
        encoding="utf-8")

    if abstract:
        (bundle / "abstract.txt").write_text(abstract, encoding="utf-8")


def main():
    review = "--review" in sys.argv
    spacing = REVIEW_SPACING
    margin = REVIEW_MARGIN
    for arg in sys.argv[1:]:
        if arg.startswith("--spacing="):
            spacing = float(arg.split("=", 1)[1])
        elif arg.startswith("--margin="):
            margin = arg.split("=", 1)[1]
    sync_hdl()  # paper/HDL is generated, not tracked
    fig_script = ROOT / "figures" / "make_figures.py"
    if fig_script.is_file():
        subprocess.run([sys.executable, str(fig_script)], cwd=ROOT,
                       capture_output=True, text=True)  # best effort: PNGs are tracked
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

    # Manuscript figure paths are ../figures/ (from paper/); stage PNGs next
    # to the generated .tex so the arXiv source package is self-contained.
    stage_figures()
    text = text.replace("../figures/", "figures/")

    text = link_sections(text)
    text = label_headings(text)
    text = convert_tables(text)

    latex = latex_source(text, review, spacing, margin)

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
    if not review:
        stage_arxiv_bundle()
        print("Wrote submission/arxiv/ (arXiv source package)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
