#!/usr/bin/env python3
"""Which readings of each character people actually use.

pypinyin lists every reading a character has ever had — 洋 is also `xiang`,
大 is also `tai` — and a matcher that admits all of them lets the decoder
spell xiangqi as 洋气. This script weighs each reading by how often the
Rime dictionaries (万象 + pinyin_simp) use it inside real words and keeps the
ones that carry real weight. The result, `char_readings.json`, is the one
reading table shared by training data, the decoder and the Swift engine.
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pinyin import SYLLABLES, toneless  # noqa: E402

from pypinyin.pinyin_dict import pinyin_dict  # noqa: E402

KEEP_SHARE = 0.03  # a reading must carry ≥3% of a character's weight…
KEEP_WORD = 1500.0  # …or appear in at least one word this common (目的 mù dì)


def rime_rows(path: Path):
    body = False
    with path.open(encoding="utf-8") as handle:
        for raw in handle:
            if not body:
                body = raw.strip() == "..."
                continue
            if not raw.strip() or raw.startswith("#"):
                continue
            fields = raw.rstrip("\n").split("\t")
            if len(fields) < 2:
                continue
            text, marked = fields[0].strip(), fields[1].strip()
            try:
                weight = float(fields[2]) if len(fields) > 2 and fields[2] else 1.0
            except ValueError:
                weight = 1.0
            syllables = [toneless(s) for s in marked.split()]
            if len(syllables) != len(text):
                continue
            if not all(s in SYLLABLES for s in syllables):
                continue
            yield text, syllables, weight


def main() -> None:
    lexicon_dir = Path(sys.argv[1])
    out = Path(sys.argv[2])
    weights: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    strongest: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for name in ("wanxiang-jichu.dict.yaml", "pinyin_simp.dict.yaml"):
        for text, syllables, weight in rime_rows(lexicon_dir / name):
            # Log-damp so one runaway entry (the corpus has a few) cannot
            # decide a character's readings on its own.
            w = math.log1p(max(weight, 0.0)) + 1.0
            for ch, s in zip(text, syllables):
                weights[ch][s] += w
                if len(text) > 1 and weight > strongest[ch][s]:
                    strongest[ch][s] = weight
    table: dict[str, list[str]] = {}
    for code, raw in pinyin_dict.items():
        ch = chr(code)
        default = toneless(raw.split(",")[0])
        known = weights.get(ch)
        if not known:
            if default in SYLLABLES:
                table[ch] = [default]
            continue
        total = sum(known.values())
        kept = [s for s, w in sorted(known.items(), key=lambda kv: -kv[1])
                if w >= KEEP_SHARE * total or strongest[ch][s] >= KEEP_WORD]
        if default in SYLLABLES and default not in kept and known.get(default, 0) > 0:
            kept.append(default)
        table[ch] = kept
    out.write_text(json.dumps(table, ensure_ascii=False, separators=(",", ":")))
    multi = sum(1 for v in table.values() if len(v) > 1)
    print(f"{len(table)} characters, {multi} with several readings -> {out}")
    for ch in "洋大行长了的得地重还都乐和要":
        print(ch, table.get(ch))


if __name__ == "__main__":
    main()
