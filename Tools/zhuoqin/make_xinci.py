#!/usr/bin/env python3
"""新词包 → training examples, oversampled so a few hundred sentences count.

Each sentence yields many examples — different spans, typing forms, and the
earlier part of the sentence as context — so the model learns the words
(绝绝子, 情绪价值, 这个PR先merge一下) rather than the sentences.

    python make_xinci.py --out ../../../work/data_xinci --per-sentence 16
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_dataset as md  # noqa: E402

HERE = Path(__file__).resolve().parent / "xinci"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--per-sentence", type=int, default=16)
    p.add_argument("--seed", type=int, default=7)
    a = p.parse_args()
    md._init_worker()
    for line in (HERE / "words.txt").read_text(encoding="utf-8").splitlines():
        w = line.split()[0] if line.strip() and not line.startswith("#") else ""
        if w:
            md._jieba.add_word(w, freq=20000)
    sentences = []
    for name in ("slang.txt", "mixed.txt", "recent.txt"):
        for line in (HERE / name).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                sentences.append((name.split(".")[0], line))
    rng = random.Random(a.seed)
    out = []
    for source, text in sentences:
        seen = set()
        for _ in range(a.per_sentence):
            for ex in md.examples_for((text, "xinci-" + source, rng.getrandbits(48))):
                key = (ex["c"], ex["k"], ex["t"])
                if key not in seen:
                    seen.add(key)
                    out.append(ex)
    rng.shuffle(out)
    a.out.mkdir(parents=True, exist_ok=True)
    with (a.out / "train.jsonl").open("w", encoding="utf-8") as f:
        for ex in out:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    latin = sum(1 for ex in out if any(c.isascii() and c.isalpha() for c in ex["t"]))
    print(f"{len(sentences)} sentences -> {len(out)} examples ({latin} with Latin)")
    for ex in out[:12]:
        print(ex)


if __name__ == "__main__":
    main()
