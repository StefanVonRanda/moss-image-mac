"""Prompt enhancement with a local MLX chat model. Usage: enhance_local.py MODEL SYSTEM_FILE USER_TEXT"""
import sys

from mlx_lm import load, generate

model_id, system_file, user = sys.argv[1], sys.argv[2], sys.argv[3]
model, tok = load(model_id)
messages = [{"role": "system", "content": open(system_file).read()}, {"role": "user", "content": user}]
try:
    prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
except TypeError:  # templates without a thinking switch
    prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
print(generate(model, tok, prompt=prompt, max_tokens=1500, verbose=False))
