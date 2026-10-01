#!/usr/bin/env python3
"""Quick top-1 check of a checkpoint with the reference beam search (MLX).

    python evaluate.py RUN_DIR corpus.tsv [--per-category 30] [--no-context]

For release numbers use `tiaoyin eval` (the shipping decoder, GGUF model);
this exists to watch a run while it trains.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from beam import Listener  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("run", type=Path)
    p.add_argument("corpus", type=Path)
    p.add_argument("--checkpoint", default=None, help="stepNNNNNN.safetensors inside RUN_DIR")
    p.add_argument("--per-category", type=int, default=30)
    p.add_argument("--no-context", action="store_true")
    p.add_argument("--beam", type=int, default=6)
    p.add_argument("--reward", type=float, default=1.0)
    p.add_argument("--hide-keys", action="store_true", help="base LM mode: keys only constrain")
    a = p.parse_args()

    adapter = None if str(a.run) == "none" else a.run
    if a.checkpoint:
        tmp = Path(tempfile.mkdtemp())
        shutil.copy(a.run / "adapter_config.json", tmp / "adapter_config.json")
        shutil.copy(a.run / a.checkpoint, tmp / "adapters.safetensors")
        adapter = tmp
    root = Path(__file__).resolve().parents[3]
    L = Listener(root / "work/models/Qwen3-0.6B-Base", adapter)

    items = []
    taken: dict[str, int] = defaultdict(int)
    for line in a.corpus.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        cat, ctx, keys, expected = line.split("\t")[:4]
        if taken[cat] >= a.per_category:
            continue
        taken[cat] += 1
        items.append((cat, "" if ctx == "-" else ctx, keys, expected))

    hits: dict[str, list[int]] = defaultdict(list)
    t0 = time.time()
    misses = []
    for cat, ctx, keys, expected in items:
        res = L.search("" if a.no_context else ctx, keys, beam=a.beam, reward=a.reward, show_keys=not a.hide_keys)
        texts = [r.text for r in res]
        ok = int(bool(texts) and texts[0] == expected)
        hits[cat].append(ok)
        hits["all"].append(ok)
        if not ok and len(misses) < 25:
            misses.append(f"  {cat:13s} {ctx[-12:]:>12s} | {keys:28s} want {expected}  got {texts[:3]}")
    for cat in sorted(hits):
        h = hits[cat]
        print(f"{cat:14s} n={len(h):4d} top1 {100*sum(h)/len(h):5.1f}%")
    print(f"{time.time()-t0:.0f}s")
    print("\n".join(misses))


if __name__ == "__main__":
    main()
