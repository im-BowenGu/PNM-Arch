import os, sys, torch
from transformers import AutoTokenizer
from vllm import LLM, SamplingParams

fp8 = "/data/ai/models/gemma-4-26b-a4b-it-fp8"
prompt = sys.argv[1]
temp = float(sys.argv[2]) if len(sys.argv) > 2 else 0.7
top_k = int(sys.argv[3]) if len(sys.argv) > 3 else 64
top_p = float(sys.argv[4]) if len(sys.argv) > 4 else 0.90
n = int(sys.argv[5]) if len(sys.argv) > 5 else 48

tok = AutoTokenizer.from_pretrained(fp8)
tok.chat_template = open(os.path.join(fp8, "chat_template.jinja")).read()
chat = tok.apply_chat_template([{"role": "user", "content": prompt}], tokenize=False,
                               add_generation_prompt=True, enable_thinking=True)
ids = tok.encode(chat, add_special_tokens=False)

llm = LLM(model=fp8, quantization="compressed-tensors", dtype="auto", max_model_len=1024,
          gpu_memory_utilization=0.92, enforce_eager=True, cpu_offload_gb=24,
          trust_remote_code=True, disable_log_stats=True)
sp = SamplingParams(temperature=temp, top_k=top_k, top_p=top_p, max_tokens=n)
outs = llm.generate([{"prompt_token_ids": ids}], sp)
o = outs[0].outputs[0]
print("PARAMS temp=%g top_k=%d top_p=%g n=%d" % (temp, top_k, top_p, n))
print("IDS   ", list(o.token_ids))
print("TEXT  ", repr(o.text))
