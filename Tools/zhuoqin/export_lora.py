#!/usr/bin/env python3
"""Ship 听音 (the key-reading ear) as a GGUF LoRA adapter for the base model.

子期 runs one base model with two contexts: 知意 (plain base, never sees the
keys) and 听音 (base + this adapter, reads the keys). Shipping the adapter
instead of a second fused model keeps one copy of the weights in memory.

    python export_lora.py RUN_DIR [--checkpoint stepNNNNNN.safetensors] \
        --out ../../Models/ziqi-tingyin.gguf

MLX LoRA computes  y = xWᵀ + s·(x·a)·b   with a: (in, r), b: (r, out).
PEFT  computes      y = xWᵀ + (α/r)·x·Aᵀ·Bᵀ with A: (r, in), B: (out, r).
So A = aᵀ, B = bᵀ and α = s·r.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import mlx.core as mx
import numpy as np
from safetensors.numpy import save_file

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "work/models/Qwen3-0.6B-Base"
CONVERT = ROOT / "work/llamacpp/llama.cpp-b9890/convert_lora_to_gguf.py"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("run", type=Path)
    p.add_argument("--checkpoint", default="adapters.safetensors")
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()

    config = json.loads((a.run / "adapter_config.json").read_text())
    lora = config["lora_parameters"]
    rank, scale = int(lora["rank"]), float(lora["scale"])
    weights = mx.load(str(a.run / a.checkpoint))
    tensors: dict[str, np.ndarray] = {}
    modules: set[str] = set()
    for name, value in weights.items():
        stem, kind = name.rsplit(".", 1)  # model.layers.0.mlp.down_proj, lora_a
        arr = np.array(value.astype(mx.float32)).T.astype(np.float16)
        suffix = "lora_A.weight" if kind == "lora_a" else "lora_B.weight"
        tensors[f"base_model.model.{stem}.{suffix}"] = np.ascontiguousarray(arr)
        modules.add(stem.split(".")[-1])
    work = Path(tempfile.mkdtemp(prefix="ziqi-lora-"))
    save_file(tensors, str(work / "adapter_model.safetensors"))
    (work / "adapter_config.json").write_text(json.dumps({
        "peft_type": "LORA",
        "task_type": "CAUSAL_LM",
        "r": rank,
        "lora_alpha": scale * rank,
        "lora_dropout": 0.0,
        "bias": "none",
        "target_modules": sorted(modules),
        "base_model_name_or_path": str(BASE),
    }, indent=2))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(CONVERT), str(work), "--base", str(BASE), "--outtype", "f16",
                    "--outfile", str(a.out)], check=True)
    print(f"→ {a.out} ({a.out.stat().st_size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
