# NHSJS Submission Package

Manuscript title:

> Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing

## Files (no author-identifying information)

| File | Role |
|------|------|
| `Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing.pdf` | **Primary review PDF** — standard superscript citations + References (LaTeX-built, 12 pt, single-spaced) |
| `Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing.tex` | **LaTeX source** — upload as supplementary information |
| `Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing.docx` | **Word version 1** — standard citation style (from Markdown export) |
| `Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing - Online Citations.docx` | **Word version 2** — full citations in double parentheses at each cite site |
| `Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing - Online Citations.md` | Source for the online Word file |

## NHSJS checklist

- [x] No author names, affiliations, or acknowledgements in submission files
- [x] 12 pt, single spacing (LaTeX `article` 12pt + `setspace`)
- [x] Standard citations: superscript numbers before punctuation
- [x] References: numbered list, initials + surname, sentence-case titles, journal format
- [x] Online citations: complete citation in `((...))` with leading space; multi-cites as `((A)), ((B))`
- [ ] **After opening the Online Citations.docx in Word:** Find `)), ((` and replace the comma with a **superscript** comma (NHSJS required step)
- [ ] Confirm PDF ≤ 20 pages (see build log `Pages:`)

## Rebuild

```bash
cd submission
python3 build_manuscripts.py
```

Requires: `python3`, `pdflatex` (TeX Live), `pandoc`.
