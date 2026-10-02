#!/usr/bin/env python3
"""Turn plain Chinese text into (context, keys, target) training examples.

Every example is one moment of real typing: the text already in the field
(context), the keys the user has pressed so far (keys), and what they mean
(target). Keys come from the typing simulator in `pinyin.py`, never from a
hand-written table, so the model learns from the same distribution the
decoder will see — full spellings, abbreviations, the half-typed last
syllable, and Latin words typed straight through.

Sources are kept apart on purpose. The evaluation corpus is built from
Leipzig zho_news_2020; that collection never enters training here, so test
numbers measure generalisation rather than recall of near-duplicates.

    python make_dataset.py --out ../../../work/data --per-source 200000
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import multiprocessing as mp
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

HAN = re.compile(r"^[㐀-䶿一-鿿]+$")
LATIN = re.compile(r"^[A-Za-z]+$")
SPACE_BETWEEN_HAN = re.compile(r"(?<=[^\x00-\x7f])\s+|\s+(?=[^\x00-\x7f])")

CONTEXT_CHARS = 48
MAX_SYLLABLES = 24

# How long a stretch people type before choosing: syllable budget weights.
# Weighted toward medium and long spans: the position deep inside a long
# target is where a model learns which keys it has already read, and short
# spans alone never teach it (r1 averaged 2.5 target tokens and could not
# finish a clause).
LENGTH_WEIGHTS = {
    1: 3, 2: 6, 3: 6, 4: 8, 5: 8, 6: 9, 7: 9, 8: 9, 9: 8, 10: 8,
    12: 8, 14: 6, 16: 5, 18: 4, 20: 3, 24: 3,
}
# Share of spans that run a whole clause (up to MAX_SYLLABLES).
CLAUSE_SHARE = 0.45
# Share of examples typed with a slip of the finger (走音), see pinyin.py.
P_SLIP = 0.07
# Extra share of examples whose context is dropped (cold starts).
EMPTY_CONTEXT = 0.12


def leipzig_units(path: Path, seed: int = 11):
    # Leipzig files are sorted by sentence text; reading a prefix would sample
    # only sentences that start with digits and punctuation. Shuffle first.
    with path.open(encoding="utf-8", errors="ignore") as handle:
        lines = handle.readlines()
    random.Random(seed).shuffle(lines)
    if True:
        for line in lines:
            _, _, sentence = line.rstrip("\n").partition("\t")
            # Some Leipzig collections ship pre-segmented ("在 拍摄 取景 时").
            sentence = SPACE_BETWEEN_HAN.sub("", sentence.strip())
            if 4 <= len(sentence) <= 200:
                yield sentence


def lccc_units(path: Path):
    with gzip.open(path, "rt", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            try:
                dialog = json.loads(line)
            except (json.JSONDecodeError, EOFError):
                continue
            for utterance in dialog:
                text = SPACE_BETWEEN_HAN.sub("", utterance.strip())
                if 2 <= len(text) <= 120:
                    yield text


_jieba = None


def _init_worker() -> None:
    global _jieba
    import jieba

    jieba.setLogLevel(60)
    jieba.initialize()
    _jieba = jieba


def analyse(text: str):
    """Words with readings; None marks a barrier (punctuation, digits, …)."""
    from pypinyin import Style, lazy_pinyin

    from pinyin import SYLLABLES, char_readings

    out = []
    for word in _jieba.cut(text):
        if not word.strip():
            out.append((word, None))
            continue
        if HAN.match(word):
            syllables = lazy_pinyin(word, style=Style.NORMAL, errors="ignore")
            if len(syllables) == len(word) and all(
                s in SYLLABLES and s in char_readings(c) for s, c in zip(syllables, word)
            ):
                out.append((word, syllables))
            else:
                out.append((word, None))
        elif LATIN.match(word) and len(word) <= 12:
            out.append((word, []))
        else:
            out.append((word, None))
    return out


def mostly_simplified(text: str) -> bool:
    """Reject traditional-script text: count Han characters outside GB2312."""
    outside = 0
    for ch in text:
        if "\u4e00" <= ch <= "\u9fff":
            try:
                ch.encode("gb2312")
            except UnicodeEncodeError:
                outside += 1
                if outside >= 2:
                    return False
    return True


def examples_for(args):
    text, source, seed = args
    from pinyin import simulate_keys, simulate_with_slips

    if not mostly_simplified(text):
        return []
    rng = random.Random(seed)
    words = analyse(text)
    # Typeable runs: maximal stretches without a barrier.
    runs: list[tuple[int, int]] = []
    start = None
    for i, (_, syl) in enumerate(words):
        if syl is None:
            if start is not None:
                runs.append((start, i))
                start = None
        elif start is None:
            start = i
    if start is not None:
        runs.append((start, len(words)))
    runs = [r for r in runs if any(words[j][1] for j in range(*r))]
    if not runs:
        return []

    results = []
    count = min(4, 1 + len(text) // 25)
    for _ in range(count):
        lo, hi = rng.choice(runs)
        if rng.random() < CLAUSE_SHARE:
            # A whole clause, from its first word.
            budget = MAX_SYLLABLES
            first = lo
        else:
            budget = rng.choices(list(LENGTH_WEIGHTS), weights=LENGTH_WEIGHTS.values())[0]
            first = rng.randrange(lo, hi)
        span: list[tuple[str, list[str]]] = []
        syllables = 0
        j = first
        while j < hi:
            w, syl = words[j]
            cost = len(syl) if syl else 2
            if span and syllables + cost > budget:
                break
            span.append((w, syl))
            syllables += cost
            j += 1
        if not span or syllables > MAX_SYLLABLES or not any(s for _, s in span):
            continue
        # Latin-only spans teach nothing about conversion.
        heavy = rng.choice((0.0, 0.0, 0.0, 0.3, 0.6, 1.0))
        truncate = rng.random() < 0.14
        keys = simulate_with_slips(rng, span, p_slip=P_SLIP, heavy=heavy, truncate_last=truncate)
        if keys is None:
            keys = simulate_keys(rng, span, heavy=0.0, truncate_last=False)
        if keys is None or len(keys) > 64:
            continue
        context = "".join(w for w, _ in words[:first])
        if rng.random() < EMPTY_CONTEXT:
            context = ""
        context = context[-CONTEXT_CHARS:]
        target = "".join(w for w, _ in span)
        results.append({"c": context, "k": keys, "t": target, "s": source})
    return results


def split_of(text: str) -> str:
    digest = hashlib.blake2b(text.encode(), digest_size=4).digest()
    return "dev" if digest[0] < 3 else "train"  # ~1.2% held out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpora", type=Path, default=Path(__file__).resolve().parents[3] / "work" / "corpora")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--per-source", type=int, default=200000, help="units read per source (scaled by share)")
    parser.add_argument("--seed", type=int, default=20261001)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--sources", default="", help="comma-separated subset: chat,news,wiki,web")
    parser.add_argument("--skip", type=int, default=0, help="units to skip per source (scaled by share), for fresh text")
    parser.add_argument("--empty-context", type=float, default=0.12, help="extra share of cold-start examples")
    parser.add_argument("--chat-share", type=float, default=1.6)
    args = parser.parse_args()
    global EMPTY_CONTEXT
    EMPTY_CONTEXT = args.empty_context

    c = args.corpora
    sources = [
        # (name, iterator, share of --per-source)
        ("chat", lccc_units(c / "lccc_base_train.jsonl.gz"), args.chat_share),
        ("news", leipzig_units(c / "zho_news_2007-2009_1M-sentences.txt"), 1.0),
        ("wiki", leipzig_units(c / "zho_wikipedia_2018_300K" / "zho_wikipedia_2018_300K-sentences.txt"), 0.8),
        ("web", leipzig_units(c / "zho-cn_web_2015_30K" / "zho-cn_web_2015_30K-sentences.txt"), 0.3),
    ]
    if args.sources:
        wanted = set(args.sources.split(","))
        sources = [s for s in sources if s[0] in wanted]
    args.out.mkdir(parents=True, exist_ok=True)
    train = (args.out / "train.jsonl").open("w", encoding="utf-8")
    dev = (args.out / "dev.jsonl").open("w", encoding="utf-8")
    stats: dict[str, int] = {}
    rng = random.Random(args.seed)
    with mp.Pool(args.workers, initializer=_init_worker) as pool:
        for name, units, share in sources:
            limit = int(args.per_source * share)
            skip = int(args.skip * share)
            seen: set[int] = set()
            jobs = []
            for index, text in enumerate(units):
                if index < skip:
                    continue
                h = hash(text)
                if h in seen:
                    continue
                seen.add(h)
                jobs.append((text, name, rng.getrandbits(48)))
                if len(jobs) >= limit:
                    break
            n = 0
            for batch in pool.imap_unordered(examples_for, jobs, chunksize=256):
                for ex in batch:
                    handle = dev if split_of(ex["c"] + ex["t"]) == "dev" else train
                    handle.write(json.dumps(ex, ensure_ascii=False) + "\n")
                    n += 1
            stats[name] = n
            print(f"{name}: {len(jobs)} units -> {n} examples", file=sys.stderr)
    train.close()
    dev.close()
    print(json.dumps(stats), file=sys.stderr)


if __name__ == "__main__":
    main()
