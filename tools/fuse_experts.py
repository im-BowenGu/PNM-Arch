#!/usr/bin/env python3
"""Convert the dequantized per-expert IT bf16 checkpoint into the fused MoE
layout our engine was built for (base model): experts.gate_up_proj
[numExp, 2*moeInter, H] = per-expert [gate; up], experts.down_proj
[numExp, H, moeInter], plus a synthesized router.per_expert_scale (=1.0, the
RedHat FP8 export dropped it). lm_head is dropped (tied embeddings)."""
import json, struct, os, re, shutil, sys
import numpy as np

SRC = "/data/ai/models/gemma-4-26b-a4b-it-bf16"
DST = sys.argv[1] if len(sys.argv) > 1 else "/data/ai/models/gemma-4-26b-a4b-it-bf16-fused"

fin = open(os.path.join(SRC, "model.safetensors"), "rb")
hdr_len = struct.unpack("<Q", fin.read(8))[0]
J = json.loads(fin.read(hdr_len))
BASE = 8 + hdr_len
NAMES = [k for k in J if k != "__metadata__"]
EXP = re.compile(r"^(model\.language_model\.layers\.\d+)\.experts\.(\d+)\.(gate|up|down)_proj\.weight$")

# group per-expert tensors
per_expert = {}
drop = set()
for k in NAMES:
    m = EXP.match(k)
    if m:
        per_expert.setdefault(m.group(1), {})[(int(m.group(2)), m.group(3))] = k
        drop.add(k)
    if k == "lm_head.weight":
        drop.add(k)

H, moeInter = 2816, 704


def read_tensor(name):
    d = J[name]
    fin.seek(BASE + d["data_offsets"][0])
    return fin.read(d["data_offsets"][1] - d["data_offsets"][0])


# build output entry list: (out_name, kind, payload)
entries = []  # each: dict(name, shape, data_iter or bytes)
for k in NAMES:
    if k in drop:
        continue
    if k in ("__metadata__",):
        continue
    entries.append({"name": k, "shape": J[k]["shape"], "src": k})
for L, exps in sorted(per_expert.items()):
    nE = max(e for e, _ in exps) + 1
    entries.append({"name": L + ".experts.gate_up_proj", "shape": [nE, 2 * moeInter, H], "fuse": (L, exps, "gu")})
    entries.append({"name": L + ".experts.down_proj", "shape": [nE, H, moeInter], "fuse": (L, exps, "d")})
    entries.append({"name": L + ".router.per_expert_scale", "shape": [nE], "ones": nE})

# compute offsets
off, total = {}, 0
for e in entries:
    n = int(np.prod(e["shape"])) * 2
    off[e["name"]] = [total, total + n]
    total += n
hdr = {e["name"]: {"dtype": "BF16", "shape": e["shape"], "data_offsets": off[e["name"]]} for e in entries}
hb = json.dumps(hdr, separators=(",", ":")).encode()
hb += b" " * ((8 - len(hb) % 8) % 8)

os.makedirs(DST, exist_ok=True)
fout = open(os.path.join(DST, "model.safetensors"), "wb")
fout.write(struct.pack("<Q", len(hb)))
fout.write(hb)


def ones_bf16(n):
    return np.full(n, 0x3F80, dtype=np.uint16).tobytes()


for i, e in enumerate(entries):
    if "src" in e:
        fout.write(read_tensor(e["src"]))
    elif "ones" in e:
        fout.write(ones_bf16(e["ones"]))
    else:
        L, exps, kind = e["fuse"]
        nE = int(e["shape"][0])
        if kind == "gu":
            arr = np.empty((nE, 2 * moeInter, H), dtype=np.uint16)
            for ee in range(nE):
                g = np.frombuffer(read_tensor(exps[(ee, "gate")]), dtype=np.uint16).reshape(moeInter, H)
                u = np.frombuffer(read_tensor(exps[(ee, "up")]), dtype=np.uint16).reshape(moeInter, H)
                arr[ee, :moeInter] = g
                arr[ee, moeInter:] = u
        else:
            arr = np.empty((nE, H, moeInter), dtype=np.uint16)
            for ee in range(nE):
                arr[ee] = np.frombuffer(read_tensor(exps[(ee, "down")]), dtype=np.uint16).reshape(H, moeInter)
        fout.write(arr.tobytes())
    if i % 100 == 0:
        print("  [%d/%d] %s" % (i, len(entries), e["name"]), flush=True)
fout.close()
print("wrote", DST, "tensors", len(entries), "bytes", total, flush=True)

idx = {"metadata": {"total_size": total}, "weight_map": {e["name"]: "model.safetensors" for e in entries}}
json.dump(idx, open(os.path.join(DST, "model.safetensors.index.json"), "w"))
for fn in ("config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
           "processor_config.json", "chat_template.jinja"):
    s = os.path.join(SRC, fn)
    if os.path.exists(s):
        shutil.copy2(s, os.path.join(DST, fn))
print("done", flush=True)
