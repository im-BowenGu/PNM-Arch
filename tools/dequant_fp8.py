#!/usr/bin/env python3
"""Dequantize the compressed-tensors FP8 E4M3 Gemma-4 IT checkpoint to a plain
BF16 safetensors checkpoint our bf16 engine can load (w = q * per-channel scale;
non-quantized tensors, e.g. the routers, are copied through)."""
import json, struct, os, sys, shutil
import numpy as np

SRC = "/data/ai/models/gemma-4-26b-a4b-it-fp8"
DST = sys.argv[1] if len(sys.argv) > 1 else "/data/ai/models/gemma-4-26b-a4b-it-bf16"

f = open(os.path.join(SRC, "model.safetensors"), "rb")
hdr_len = struct.unpack("<Q", f.read(8))[0]
J = json.loads(f.read(hdr_len))
data = f.read()
print("source header tensors:", len([k for k in J if k != "__metadata__"]), "data bytes:", len(data), flush=True)


def e4m3(u8):
    u = u8.astype(np.uint32)
    s = (u >> 7) & 1
    e = (u >> 3) & 15
    m = u & 7
    val = np.where(e == 0, (m / 8.0) * (2.0 ** -6), (1 + m / 8.0) * np.power(2.0, e.astype(np.float64) - 7))
    val = np.where((e == 15) & (m == 7), np.nan, val)
    return (((-1.0) ** s) * val).astype(np.float32)


def to_bf16(x):
    u = np.ascontiguousarray(x.astype(np.float32)).view(np.uint32)
    lsb = (u >> 16) & 1
    u = u + (0x7FFF + lsb)
    return (u >> 16).astype(np.uint16)


def raw(name):
    d = J[name]
    return data[d["data_offsets"][0]:d["data_offsets"][1]]


def decode(name):
    d = J[name]
    dt, shp = d["dtype"], d["shape"]
    if dt == "F8_E4M3":
        q = np.frombuffer(raw(name), dtype=np.uint8).reshape(shp)
        sc = np.frombuffer(raw(name + "_scale"), dtype=np.uint16)
        sc = ((sc.astype(np.uint32) << 16).view(np.float32))
        w = e4m3(q) * sc.reshape([-1] + [1] * (len(shp) - 1))
        return w
    if dt == "BF16":
        return np.frombuffer(raw(name), dtype=np.uint16).reshape(shp)
    if dt == "F16":
        return np.frombuffer(raw(name), dtype=np.float16).reshape(shp).astype(np.float32)
    if dt == "F32":
        return np.frombuffer(raw(name), dtype=np.float32).reshape(shp)
    raise ValueError("unhandled dtype %s for %s" % (dt, name))


names = [k for k in sorted(J.keys()) if k != "__metadata__"
         and not k.endswith("_scale") and not k.endswith("_input_scale")]

# compute output layout (all BF16 = 2 bytes/elem)
offsets = {}
total = 0
for k in names:
    shp = J[k]["shape"]
    nbytes = int(np.prod(shp)) * 2
    offsets[k] = [total, total + nbytes]
    total += nbytes
header = {k: {"dtype": "BF16", "shape": J[k]["shape"], "data_offsets": offsets[k]} for k in names}
hb = json.dumps(header, separators=(",", ":")).encode()
pad = (8 - (len(hb) % 8)) % 8
hb += b" " * pad
print("output tensors:", len(names), "bf16 bytes:", total, "header:", len(hb), flush=True)

os.makedirs(DST, exist_ok=True)
out = open(os.path.join(DST, "model.safetensors"), "wb")
out.write(struct.pack("<Q", len(hb)))
out.write(hb)
for i, k in enumerate(names):
    arr = decode(k)
    if J[k]["dtype"] == "BF16":
        b = np.ascontiguousarray(arr).tobytes()
    else:
        b = to_bf16(arr).tobytes()
    assert len(b) == offsets[k][1] - offsets[k][0], (k, len(b))
    out.write(b)
    if i % 50 == 0:
        print("  [%d/%d] %s" % (i, len(names), k), flush=True)
out.close()
print("wrote", os.path.join(DST, "model.safetensors"), flush=True)

idx = {"metadata": {"total_size": total}, "weight_map": {k: "model.safetensors" for k in names}}
json.dump(idx, open(os.path.join(DST, "model.safetensors.index.json"), "w"))

# config: drop quantization_config so loaders treat it as a plain bf16 model
cfg = json.load(open(os.path.join(SRC, "config.json")))
cfg.pop("quantization_config", None)
cfg["transformers_version"] = cfg.get("transformers_version", "5.5.0")
json.dump(cfg, open(os.path.join(DST, "config.json"), "w"), indent=2)
for fn in ("generation_config.json", "tokenizer.json", "tokenizer_config.json",
           "processor_config.json", "chat_template.jinja"):
    s = os.path.join(SRC, fn)
    if os.path.exists(s):
        shutil.copy2(s, os.path.join(DST, fn))
print("done", flush=True)
