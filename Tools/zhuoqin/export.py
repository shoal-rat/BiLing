#!/usr/bin/env python3
"""Fuse a LoRA run into Qwen3-0.6B-Base and ship it as a quantized GGUF.

    python export.py RUN_DIR [--checkpoint stepNNNNNN.safetensors] [--quant Q4_K_M] \
        --out ../../Models/ziqi.gguf

Steps: mlx_lm fuse (de-quantized bf16 safetensors) → llama.cpp's
convert_hf_to_gguf.py (f16) → llama-quantize. The f16 intermediate is kept
next to the output for exact comparisons with the MLX reference decoder.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "work/models/Qwen3-0.6B-Base"
CONVERT = ROOT / "work/llamacpp/llama.cpp-b9890/convert_hf_to_gguf.py"
QUANTIZE = "/opt/homebrew/opt/llama.cpp/bin/llama-quantize"


def run(cmd: list[str]) -> None:
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("run", type=Path)
    p.add_argument("--checkpoint", default=None)
    p.add_argument("--quant", default="Q4_K_M")
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()

    work = Path(tempfile.mkdtemp(prefix="ziqi-export-"))
    adapter = work / "adapter"
    adapter.mkdir()
    shutil.copy(a.run / "adapter_config.json", adapter / "adapter_config.json")
    shutil.copy(a.run / (a.checkpoint or "adapters.safetensors"), adapter / "adapters.safetensors")
    fused = work / "fused"
    run([sys.executable, "-m", "mlx_lm", "fuse", "--model", str(BASE), "--adapter-path", str(adapter),
         "--save-path", str(fused), "--dequantize"])
    # mlx_lm writes its own tokenizer files; keep the originals for the converter.
    for name in ("tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt", "generation_config.json"):
        if (BASE / name).exists():
            shutil.copy(BASE / name, fused / name)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    f16 = a.out.with_name(a.out.stem + "-f16.gguf")
    run([sys.executable, str(CONVERT), str(fused), "--outtype", "f16", "--outfile", str(f16)])
    if a.quant.upper() == "F16":
        shutil.move(f16, a.out)
    else:
        run([QUANTIZE, str(f16), str(a.out), a.quant])
    shutil.rmtree(work, ignore_errors=True)
    print(f"→ {a.out} ({a.out.stat().st_size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
