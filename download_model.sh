#!/usr/bin/env bash
# download_model.sh — fetch a real Gemma 4 26B-A4B checkpoint for the
# real-weight inference engine (docs/real_weights.md) and for
# `reproduce.sh --real-weights`.
#
# Two checkpoints are pinned: the base/pretrained `google/gemma-4-26B-A4B`
# (used by the numeric benchmark) and the instruction-tuned
# `google/gemma-4-26B-A4B-it` (ships the native chat template).  Neither is
# gated.  Every file is verified against a pinned hash --- SHA-256 for LFS
# objects, the git blob SHA-1 for small repo files; a partial download is
# resumed (curl -C -) and a corrupt one re-fetched, so re-running is safe.
#
# Usage:
#   ./download_model.sh [--repo ID] [--out DIR]
#
# Defaults: REPO=google/gemma-4-26B-A4B, OUT=$ROOT/models/$(basename REPO).
set -euo pipefail

REPO="google/gemma-4-26B-A4B"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT=""

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "download_model.sh: unknown argument: $1" >&2; usage 2 ;;
    esac
done

[ -n "$OUT" ] || OUT="$ROOT/models/$(basename "$REPO")"

# name algo hash — algo is sha256 (LFS object) or git (git blob SHA-1).
# The shards are ~50 GB each; hashes match the upstream blobs exactly.
manifest() {
    case "$1" in
    google/gemma-4-26B-A4B)
        cat <<'EOF'
config.json sha256 0364256c5de7863a22b5dd666043d542d42b681c02fd83eb67dc7b483d859e96
generation_config.json sha256 de16fa1d777387d5fe6df54a9565d9c0f1213f7b31f2a2cf44805e27686d9c7c
model.safetensors.index.json sha256 907826a6e46ff454272bd6db1fee629d5531a2303be22986d825a0871d7dc7a7
processor_config.json sha256 32bdf45d2ad4cc29a0822ddd157a182de76644f0419a6228d151495256e9813c
tokenizer_config.json sha256 6a9383197f000d2723684efd2210f5bf217bc29fa2cf360ae1574201b47af060
tokenizer.json sha256 12bac982b793c44b03d52a250a9f0d0b666813da566b910c24a6da0695fd11e6
model-00001-of-00002.safetensors sha256 a0e671c5e81ce9a8fd151e60676e7b3a7f2e9ec685a1e8b6b504de2082453f96
model-00002-of-00002.safetensors sha256 dda6797de622b19c46320bb31073323d06a3444a149d4e0e028a3dbd682e0364
EOF
        ;;
    google/gemma-4-26B-A4B-it)
        cat <<'EOF'
config.json git f42adcca257bb0865c506947671e7d0af52ac9c4
generation_config.json git e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6
model.safetensors.index.json git 889ab10e12aca96c43c9804a041fb1780de1e5ca
processor_config.json git 5465974d23e1eca2c46c2809b26c997946ce0d90
tokenizer_config.json git 6068e357379d36f823c377e30efb101fa2c67fe4
chat_template.jinja git 4741bf6e4132ba23a5537f9d6e74e9a6d613d7cd
tokenizer.json sha256 cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f
model-00001-of-00002.safetensors sha256 1127684971bbca40465435a5cad69d67ad603bf5e61c6dfd5561fae4a3bcfdb3
model-00002-of-00002.safetensors sha256 aab47033e1e8a492ef8e581efae1cf36478d0433567e7729b3c1728bc8970db7
EOF
        ;;
    *) return 1 ;;
    esac
}

# Extra repo metadata, fetched best-effort (not needed by the engine).
EXTRA=( ".gitattributes" "README.md" )

if ! FILES_RAW="$(manifest "$REPO")"; then
    echo "download_model.sh: no pinned manifest for '$REPO'" >&2
    echo "  supported: google/gemma-4-26B-A4B, google/gemma-4-26B-A4B-it" >&2
    exit 1
fi
mapfile -t FILES <<< "$FILES_RAW"

# --- hash tools -------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
    sha1_raw()  { sha1sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
    sha1_raw()  { shasum -a 1 "$1" | awk '{print $1}'; }
else
    echo "download_model.sh: need sha256sum or shasum" >&2
    exit 1
fi

# Git blob hash: SHA-1 over "blob <bytelen>\0<contents>".
git_sha1_of() {
    local size
    size=$(wc -c < "$1")
    { printf 'blob %d\0' "$size"; cat "$1"; } | sha1_raw /dev/stdin
}

verify() { # file algo expected
    case "$2" in
        sha256) [ "$(sha256_of "$1")" = "$3" ] ;;
        git)    [ "$(git_sha1_of "$1")" = "$3" ] ;;
        *)      return 1 ;;
    esac
}

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER=wget
else
    echo "download_model.sh: need curl or wget" >&2
    exit 1
fi

TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}}"
if [ -z "$TOKEN" ] && [ -f "${HF_HOME:-$HOME/.cache/huggingface}/token" ]; then
    TOKEN="$(tr -d '\n' < "${HF_HOME:-$HOME/.cache/huggingface}/token")"
fi

url_of() { printf 'https://huggingface.co/%s/resolve/main/%s?download=true' "$REPO" "$1"; }

fetch() { # name dest
    local url
    url="$(url_of "$1")"
    if [ "$DOWNLOADER" = curl ]; then
        if [ -n "$TOKEN" ]; then
            command curl -fL --retry 5 --retry-delay 5 -C - \
                -H "Authorization: Bearer $TOKEN" -o "$2" "$url"
        else
            command curl -fL --retry 5 --retry-delay 5 -C - -o "$2" "$url"
        fi
    else
        if [ -n "$TOKEN" ]; then
            command wget -c --header="Authorization: Bearer $TOKEN" -O "$2" "$url"
        else
            command wget -c -O "$2" "$url"
        fi
    fi
}

mkdir -p "$OUT"

echo "==> model:  $REPO"
echo "==> output: $OUT"

for entry in "${FILES[@]}"; do
    name="${entry%% *}"; rest="${entry#* }"
    algo="${rest%% *}"; want="${rest##* }"
    dest="$OUT/$name"
    if [ -f "$dest" ] && verify "$dest" "$algo" "$want"; then
        printf '  ok       %s\n' "$name"
        continue
    fi
    printf '  fetch    %s ...\n' "$name"
    fetch "$name" "$dest.part"
    if ! verify "$dest.part" "$algo" "$want"; then
        echo "  ERROR    $name: $algo mismatch" >&2
        echo "           want $want" >&2
        echo "           got  $([ "$algo" = git ] && git_sha1_of "$dest.part" || sha256_of "$dest.part")" >&2
        rm -f "$dest.part"
        exit 1
    fi
    mv -f "$dest.part" "$dest"
    printf '  verified %s\n' "$name"
done

for name in "${EXTRA[@]}"; do
    [ -f "$OUT/$name" ] && continue
    fetch "$name" "$OUT/$name.part" || true
    [ -f "$OUT/$name.part" ] && mv -f "$OUT/$name.part" "$OUT/$name" || true
done

echo "==> done: $OUT"
echo "    run:  cd sim && go run ./cmd/pnmhost inference \"$OUT\" \"What is the capital of Germany\" -max-tokens 32"
