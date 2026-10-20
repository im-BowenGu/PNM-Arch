#!/usr/bin/env python3
"""Merge a split repo's '## Related repositories' section into a refreshed README.

The public split repos (PNM-HDL, PNM-PCB, ...) carry a README that is the
monorepo README plus a repo-family cross-link section and a repo-specific
title.  Copying the monorepo README over it would drop those, so this
merges them instead:

    merge_readme.py <monorepo-readme> <split-readme> <out>

If the split README has no cross-link section, the monorepo README is used
unchanged.
"""
import re
import sys


def extract_related(text: str):
    m = re.search(r"^## Related repositories\n.*?(?=^## |\Z)", text, re.S | re.M)
    return m.group(0).rstrip() + "\n" if m else None


def extract_title(text: str):
    for line in text.splitlines():
        if line.startswith("# "):
            return line
    return None


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    mono_path, split_path, out_path = sys.argv[1:4]

    new = open(mono_path, encoding="utf-8").read()
    try:
        old = open(split_path, encoding="utf-8").read()
    except OSError:
        old = ""

    block = extract_related(old)
    if block:
        # insert the cross-link section before the first level-2 heading
        m = re.search(r"^## ", new, re.M)
        if m:
            new = new[: m.start()] + block + "\n" + new[m.start():]
        else:
            new = new.rstrip() + "\n\n" + block

    # keep the split repo's own title (it names the repo, not the monorepo dir)
    old_title = extract_title(old)
    new_title = extract_title(new)
    if old_title and new_title and old_title != new_title:
        new = new.replace(new_title, old_title, 1)

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(new)
    return 0


if __name__ == "__main__":
    sys.exit(main())
