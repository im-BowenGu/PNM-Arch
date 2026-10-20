#!/usr/bin/env bash
# =============================================================================
# split_sync.sh — publish the monorepo into the six public split repos.
#
# The working tree (Paper/) is the canonical source. The public repos live
# beside it:
#
#   ../PNM-HDL        <- HDL/*  (contents) + implementations/
#   ../PNM-fw         <- fw/*
#   ../PNM-sim        <- sim/*
#   ../PNM-paper      <- paper/*
#   ../PNM-PCB        <- pcb/*
#   ../PNM-toolchain  <- toolchain/*
#
# Only files that are *tracked by git* in Paper/ are copied, so generated
# artifacts (stimulus files, vvp binaries, vcd dumps, board netlists, the
# model checkpoint) can never leak into a public repo. Files the split repo
# still carries but Paper/ no longer has are pruned, so the split repos
# cannot rot behind the monorepo.
#
# Each split repo keeps its own README.md, LICENSE and .gitignore.
#
# Usage:
#   tools/split_sync.sh            # report what would change (dry run)
#   tools/split_sync.sh --apply    # copy + prune
#   tools/split_sync.sh --apply --commit "message"   # ... and commit in each repo
# =============================================================================
set -euo pipefail

PAPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(dirname "$PAPER")"

APPLY=0
COMMIT_MSG=""
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --commit) shift; COMMIT_MSG="${1:-}" ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# repo | "srcprefix:dstsubdir" pairs (comma separated) | kept per-repo files
LAYOUT=(
    "PNM-HDL|HDL:,implementations:implementations|README.md LICENSE .gitignore"
    "PNM-fw|fw:|README.md LICENSE .gitignore"
    "PNM-sim|sim:|README.md LICENSE .gitignore"
    "PNM-paper|paper:|README.md LICENSE .gitignore"
    "PNM-PCB|pcb:|README.md LICENSE .gitignore"
    "PNM-toolchain|toolchain:|README.md LICENSE .gitignore"
)

copied=0
removed=0
repos=()

for entry in "${LAYOUT[@]}"; do
    IFS='|' read -r repo pairs keep <<<"$entry"
    dst="$ROOT/$repo"
    if [ ! -d "$dst" ]; then
        printf 'SKIP  %s (not present at %s)\n' "$repo" "$dst"
        continue
    fi
    repos+=("$repo")

    # ---- source set: git-tracked files, mapped to destination-relative paths
    # dest_list holds "<dest-rel>|<paper-rel>" pairs.
    dest_list="$(mktemp)"
    for pair in ${pairs//,/ }; do
        src_prefix="${pair%%:*}"
        dst_sub="${pair##*:}"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rel="${f#"$src_prefix"/}"
            [ "$rel" = "$f" ] && rel=""
            if [ -n "$dst_sub" ]; then
                printf '%s/%s|%s\n' "$dst_sub" "$rel" "$f"
            else
                printf '%s|%s\n' "$rel" "$f"
            fi
        done < <(git -C "$PAPER" ls-files -- "$src_prefix") >>"$dest_list"
    done
    sort -u -o "$dest_list" "$dest_list"

    # paper_path <dest-rel> -> the monorepo path a dest-rel could come from
    paper_path() {
        local want="$1" pair pre sub
        for pair in ${pairs//,/ }; do
            pre="${pair%%:*}"; sub="${pair##*:}"
            if [ -n "$sub" ]; then
                case "$want" in
                    "$sub"/*) printf '%s/%s\n' "$pre" "${want#"$sub"/}"; return 0 ;;
                esac
            else
                printf '%s/%s\n' "$pre" "$want"; return 0
            fi
        done
        return 1
    }

    changed=0
    # ---- copy -------------------------------------------------------------
    while IFS='|' read -r rel paper_rel; do
        [ -n "$rel" ] || continue
        src="$PAPER/$paper_rel"
        out="$dst/$rel"
        [ -f "$src" ] || continue
        # per-repo files (README/LICENSE/.gitignore) are owned by the split
        # repo: the README is *merged* (it carries the repo-family cross-link
        # section), the others are never touched.
        case " $keep " in
            *" $rel "*)
                if [ "$rel" = "README.md" ] && [ -f "$out" ] && [ -f "$src" ]; then
                    merged="$(mktemp)"
                    if python3 "$PAPER/tools/merge_readme.py" "$src" "$out" "$merged"; then
                        if ! cmp -s "$merged" "$out"; then
                            changed=1
                            copied=$((copied + 1))
                            if [ "$APPLY" = 1 ]; then
                                cp -p "$merged" "$out"
                                printf '  MERGE  %s/%s\n' "$repo" "$rel"
                            else
                                printf '  MERGE  %s/%s\n' "$repo" "$rel"
                            fi
                        fi
                    fi
                    rm -f "$merged"
                else
                    printf '  KEEP   %s/%s (per-repo file)\n' "$repo" "$rel"
                fi
                continue
                ;;
        esac
        if [ -f "$out" ] && cmp -s "$src" "$out"; then
            continue
        fi
        changed=1
        copied=$((copied + 1))
        if [ "$APPLY" = 1 ]; then
            mkdir -p "$(dirname "$out")"
            cp -p "$src" "$out"
            printf '  COPY   %s/%s\n' "$repo" "$rel"
        else
            printf '  COPY   %s/%s\n' "$repo" "$rel"
        fi
    done <"$dest_list"

    # ---- prune: files the split repo still has but Paper/ no longer has ---
    # Only files that vanished from the monorepo entirely are pruned; build
    # artifacts that are generated into both trees (staged figures, .aux,
    # .out) are tracked deliberately in the split repo and stay.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case " $keep " in *" $rel "*) continue ;; esac
        grep -qF "$rel|" "$dest_list" && continue
        if p="$(paper_path "$rel")" && [ -e "$PAPER/$p" ]; then
            continue
        fi
        out="$dst/$rel"
        [ -f "$out" ] || continue
        changed=1
        removed=$((removed + 1))
        if [ "$APPLY" = 1 ]; then
            rm -f "$out"
            printf '  PRUNE  %s/%s\n' "$repo" "$rel"
        else
            printf '  PRUNE  %s/%s\n' "$repo" "$rel"
        fi
    done < <(git -C "$dst" ls-files)

    [ "$changed" = 0 ] && printf 'OK     %s (in sync)\n' "$repo"
    rm -f "$dest_list"
done

printf '\nchanged files: %d copied, %d pruned (repos: %s)\n' "$copied" "$removed" "${repos[*]:-none}"

if [ "$APPLY" = 0 ]; then
    echo "dry run — re-run with --apply to write the changes"
    exit 0
fi

# ---- refresh the paper's generated RTL mirror from the HDL sibling --------
if [ -d "$ROOT/PNM-paper" ] && [ -d "$ROOT/PNM-HDL" ]; then
    rm -rf "$ROOT/PNM-paper/HDL"
    mkdir -p "$ROOT/PNM-paper/HDL"
    (cd "$ROOT/PNM-HDL" && tar --exclude=.git --exclude=build --exclude='*.out' --exclude='*.vcd' -cf - .) \
        | (cd "$ROOT/PNM-paper/HDL" && tar -xf -)
    echo "mirror: PNM-paper/HDL refreshed from PNM-HDL"
fi

# ---- optional: commit in each split repo ---------------------------------
if [ -n "$COMMIT_MSG" ]; then
    for repo in "${repos[@]}"; do
        if [ -z "$(git -C "$ROOT/$repo" status --porcelain)" ]; then
            echo "commit: $repo (no changes)"
            continue
        fi
        git -C "$ROOT/$repo" add -A
        git -C "$ROOT/$repo" commit -q -m "$COMMIT_MSG"
        echo "commit: $repo $(git -C "$ROOT/$repo" rev-parse --short HEAD)"
    done
fi
