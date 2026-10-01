#!/usr/bin/env python3
"""Word frequencies from the training corpora, for pricing 琴谱's words.

    python count_words.py --out ../../../work/word_counts.json
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import re
import sys
from collections import Counter
from itertools import islice
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_dataset as md  # noqa: E402

HAN = re.compile(r"^[㐀-䶿一-鿿]+$")


def count(texts: list[str]) -> Counter:
    c: Counter = Counter()
    for text in texts:
        if not md.mostly_simplified(text):
            continue
        for w in md._jieba.cut(text):
            if HAN.match(w):
                c[w] += 1
    return c


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--per-source", type=int, default=800000)
    a = p.parse_args()
    c = Path(__file__).resolve().parents[3] / "work" / "corpora"
    sources = [
        md.lccc_units(c / "lccc_base_train.jsonl.gz"),
        md.leipzig_units(c / "zho_news_2007-2009_1M-sentences.txt"),
        md.leipzig_units(c / "zho_wikipedia_2018_300K" / "zho_wikipedia_2018_300K-sentences.txt"),
        md.leipzig_units(c / "zho-cn_web_2015_30K" / "zho-cn_web_2015_30K-sentences.txt"),
    ]
    total: Counter = Counter()
    with mp.Pool(6, initializer=md._init_worker) as pool:
        for units in sources:
            texts = list(islice(units, a.per_source))
            chunks = [texts[i:i + 2000] for i in range(0, len(texts), 2000)]
            for part in pool.imap_unordered(count, chunks):
                total.update(part)
            print(len(texts), "units;", len(total), "distinct words", file=sys.stderr)
    kept = {w: n for w, n in total.items() if n >= 2}
    a.out.write_text(json.dumps(kept, ensure_ascii=False))
    print(f"{len(kept)} words -> {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
