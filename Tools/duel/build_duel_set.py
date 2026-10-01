#!/usr/bin/env python3
"""对弈集 · the duel corpus: what both input methods are measured on.

Built to be larger and more like real typing than the news-clause corpus
inherited from BiLing (Tests/Corpus/derived-test.tsv, kept for continuity):

* sources nobody trained on — LCCC's *test* split (chat; training used only
  the train split), Leipzig news 2020 (training used news 2007–2009), and a
  hand-written set of current usage (Tests/Corpus/modern-heldout.txt, never
  in training; reported apart because its author also built the system);
* two span types — a short phrase (2–6 syllables: how most people commit)
  and a whole clause (4–20 characters);
* four ways of typing — full pinyin, light and heavy abbreviation, and a
  slip of the finger;
* the text before the span, in the same sentence, as context.

Keys come from pypinyin and a plain typing model written here, deliberately
*not* from 知音's own simulator or matcher, so the corpus does not lean
toward the system under test. Items 知音 cannot even spell still count.

    python Tools/duel/build_duel_set.py --out Tests/Corpus
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import random
import re
from pathlib import Path

import jieba
from pypinyin import Style, lazy_pinyin

jieba.setLogLevel(60)
ROOT = Path(__file__).resolve().parents[3]
HAN = re.compile(r"^[一-鿿]+$")
LATIN = re.compile(r"^[A-Za-z]+$")
SPLIT = re.compile(r"[，。！？；：、,.!?;:\s（）()「」“”\"'《》【】\[\]…—\-~～]+")
SPACE = re.compile(r"(?<=[^\x00-\x7f])\s+|\s+(?=[^\x00-\x7f])")
NEAR = {
    "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh", "u": "yihj",
    "i": "uojk", "o": "ipkl", "p": "ol", "a": "qwsz", "s": "awedzx", "d": "serfxc",
    "f": "drtgcv", "g": "ftyhvb", "h": "gyujbn", "j": "huiknm", "k": "jiolm", "l": "kop",
    "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb", "b": "vghn", "n": "bhjm", "m": "njk",
}


def gb2312(text: str) -> bool:
    try:
        text.encode("gb2312")
        return True
    except UnicodeEncodeError:
        return False


def words_of(clause: str):
    """[(word, syllables or [] for Latin)] or None if anything is untypeable."""
    out = []
    for w in jieba.cut(clause):
        if HAN.match(w):
            syl = lazy_pinyin(w, style=Style.NORMAL, errors="ignore")
            if len(syl) != len(w) or not all(s.isascii() and s.isalpha() for s in syl):
                return None
            out.append((w, syl))
        elif LATIN.match(w):
            out.append((w, []))
        else:
            return None
    return out


def initials(s: str) -> str:
    return s[0]


def typed(rng: random.Random, words, form: str) -> str:
    pieces = []
    for w, syl in words:
        if not syl:
            pieces.append(w.lower())
            continue
        if form in ("full", "slip") or len(syl) == 1:
            pieces.append("".join(syl))
            continue
        weights = {"light": (0.70, 0.20, 0.10), "heavy": (0.30, 0.30, 0.40)}[form]
        mode = rng.choices(["full", "mixed", "initials"], weights=weights)[0]
        if mode == "full":
            pieces.append("".join(syl))
        elif mode == "mixed":
            pieces.append(syl[0] + "".join(initials(s) for s in syl[1:]))
        else:
            pieces.append("".join(initials(s) for s in syl))
    keys = "".join(pieces)
    if form == "slip" and len(keys) >= 3:
        i = rng.randrange(1, len(keys))
        c = keys[i]
        roll = rng.random()
        if roll < 0.5:
            keys = keys[:i] + rng.choice(NEAR[c]) + keys[i + 1:]
        elif roll < 0.7 and i + 1 < len(keys) and keys[i + 1] != c:
            keys = keys[:i] + keys[i + 1] + c + keys[i + 2:]
        elif roll < 0.85:
            keys = keys[:i] + keys[i + 1:]
        else:
            keys = keys[:i + 1] + c + keys[i + 1:]
    return keys


def lccc_test():
    path = ROOT / "work/corpora/lccc_base_test.jsonl.gz"
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            for u in json.loads(line):
                yield SPACE.sub("", u.strip())


def news_2020():
    seen = set()
    for name in ("zho_news_2020_10K", "zho_news_2020_300K"):
        path = ROOT / f"work/corpora/{name}/{name}-sentences.txt"
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        random.Random(2020).shuffle(lines)
        for line in lines:
            s = SPACE.sub("", line.partition("\t")[2].strip())
            if s not in seen:
                seen.add(s)
                yield s


def modern():
    for line in (ROOT / "Zhiyin/Tests/Corpus/modern-heldout.txt").read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            yield line.strip()


def items_from(rng: random.Random, sentence: str, source: str, allow_latin: bool):
    """One item from a sentence: a span inside one of its clauses."""
    if not gb2312("".join(ch for ch in sentence if not ch.isascii())):
        return None
    clauses = []
    offset = 0
    for part in SPLIT.split(sentence):
        start = sentence.find(part, offset) if part else -1
        if part and start >= 0:
            clauses.append((start, part))
            offset = start + len(part)
    rng.shuffle(clauses)
    for start, clause in clauses:
        if not (2 <= len(clause) <= 24):
            continue
        if not allow_latin and not HAN.match(clause):
            continue
        ws = words_of(clause)
        if not ws:
            continue
        span_kind = rng.choice(["phrase", "clause"])
        if span_kind == "clause":
            if len(clause) < 4 or len(clause) > 20:
                continue
            i, j = 0, len(ws)
        else:
            # A run of words worth 2–6 syllables, from any word.
            i = rng.randrange(len(ws))
            j, syl = i, 0
            budget = rng.randint(2, 6)
            while j < len(ws) and syl < budget:
                syl += max(1, len(ws[j][1]))
                j += 1
            if syl < 2 or syl > 7:
                continue
        span = ws[i:j]
        text = "".join(w for w, _ in span)
        before = sentence[:start] + "".join(w for w, _ in ws[:i])
        form = rng.choices(["full", "light", "heavy", "slip"], weights=[58, 22, 10, 10])[0]
        keys = typed(rng, span, form)
        if not keys.isascii() or not keys.isalpha() or not keys.islower():
            continue
        if form != "full" and keys == "".join("".join(s) if s else w.lower() for w, s in span):
            form = "full"
        context = before[-60:]
        return {
            "category": f"{source}/{span_kind}/{form}",
            "context": context,
            "keys": keys,
            "expected": text,
        }
    return None


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=ROOT / "Zhiyin/Tests/Corpus")
    p.add_argument("--chat", type=int, default=500)
    p.add_argument("--news", type=int, default=500)
    p.add_argument("--dev", type=int, default=600)
    p.add_argument("--seed", type=int, default=20261002)
    a = p.parse_args()
    rng = random.Random(a.seed)
    test, dev = [], []
    for source, it, n_test in (("chat", lccc_test(), a.chat), ("news", news_2020(), a.news)):
        n_dev = a.dev // 2
        t = d = 0
        for sentence in it:
            if t >= n_test and d >= n_dev:
                break
            bucket = "dev" if hashlib.sha256(sentence.encode()).digest()[0] < 80 else "test"
            if (bucket == "test" and t >= n_test) or (bucket == "dev" and d >= n_dev):
                continue
            item = items_from(rng, sentence, source, allow_latin=False)
            if not item:
                continue
            if bucket == "test":
                test.append(item)
                t += 1
            else:
                dev.append(item)
                d += 1
    for sentence in modern():
        item = items_from(rng, sentence, "modern", allow_latin=True)
        if item:
            test.append(item)
    order = random.Random(a.seed + 1)
    order.shuffle(test)  # Apple learns while it is measured: never in source order.
    for name, rows in (("duel-test.tsv", test), ("duel-dev.tsv", dev)):
        with (a.out / name).open("w", encoding="utf-8") as f:
            f.write(f"# 对弈集 · generated by Tools/duel/build_duel_set.py --seed {a.seed}\n")
            f.write("# category<TAB>context<TAB>pinyin<TAB>expected\n")
            for r in rows:
                f.write("\t".join([r["category"], r["context"] or "-", r["keys"], r["expected"]]) + "\n")
        cats: dict[str, int] = {}
        for r in rows:
            k = r["category"].split("/")
            for key in (k[0], k[1], k[2], "ctx" if r["context"] else "cold"):
                cats[key] = cats.get(key, 0) + 1
        print(name, len(rows), dict(sorted(cats.items())))


if __name__ == "__main__":
    main()
