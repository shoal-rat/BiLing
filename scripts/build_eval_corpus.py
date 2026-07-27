#!/usr/bin/env python3
"""Derive an evaluation corpus from real Chinese sentences.

The point of this script is that *nobody chooses the test items*. Sentences
come from a public news corpus, are segmented by jieba and read by pypinyin —
neither of which knows anything about BiLing's lexicon — and the keystrokes are
sampled from a typing model. The engine then has to invert a process it had no
hand in. That is the opposite of writing test cases by hand, where the author
unconsciously picks examples the system already handles.

Each sentence yields items in several conditions:

  full            every word spelled out, no preceding context
  full-ctx        the sentence's first half is already committed; convert the rest
  abbrev          per word, a form sampled from the typing model
  abbrev-ctx      the same, with the first half as context

Items are split into dev and test by hashing the sentence, so parameters can be
tuned on dev and reported on test without contaminating the comparison.

Usage:
    python3 scripts/build_eval_corpus.py --fetch --limit 800
    python3 scripts/build_eval_corpus.py --source path/to/sentences.txt

Requires pypinyin and jieba (see --help for the venv one-liner). The source
corpus is *not* committed: it is third-party text under its own licence, so this
script downloads it on demand and writes only the derived TSV, which is also
gitignored. Regenerating with the same --seed reproduces the corpus exactly.

Source: Leipzig Corpora Collection, zho_news_2020_10K
        https://wortschatz.uni-leipzig.de/en/download/Chinese
        Cite: D. Goldhahn, T. Eckart, U. Quasthoff, LREC 2012.
"""

from __future__ import annotations

import argparse
import hashlib
import random
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

CORPUS_URL = (
    "https://downloads.wortschatz-leipzig.de/corpora/zho_news_2020_10K.tar.gz"
)
CJK = re.compile(r"^[一-鿿]+$")
# Clauses are cut at punctuation; only fully-Han runs are usable, because a
# digit or Latin run would test the mixed-script path rather than conversion.
SPLIT = re.compile(r"[，。！？；：、,.!?;:\s（）()「」“”\"'《》【】\[\]…—\-]+")


def fetch_sentences(cache: Path) -> Path:
    """Download and unpack the source corpus if it is not already present."""
    target = cache / "zho_news_2020_10K-sentences.txt"
    if target.exists():
        return target
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "zho_news_2020_10K.tar.gz"
    if not archive.exists():
        print(f"Downloading {CORPUS_URL} …", file=sys.stderr)
        urllib.request.urlretrieve(CORPUS_URL, archive)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if member.name.endswith("-sentences.txt"):
                member.name = Path(member.name).name
                tar.extract(member, cache)
    return target


def clauses(path: Path, min_len: int, max_len: int):
    """Yield pure-Han clauses of a workable length, in file order."""
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            _, _, sentence = line.partition("\t")
            for clause in SPLIT.split(sentence.strip()):
                if min_len <= len(clause) <= max_len and CJK.match(clause):
                    yield clause


def sample_form(rng: random.Random, syllables: list[str], profile: str) -> str:
    """Keystrokes for one word, with its written form drawn from the typing model.

    `full` spells every syllable out, `mixed` spells the first and reduces the
    rest to initials, `initials` keeps only initials. Single-syllable words have
    no mixed form, and reducing them to a bare letter is both unrealistic and
    hopelessly ambiguous, so they are only ever spelled out.
    """
    if len(syllables) == 1:
        return syllables[0]
    weights = {"light": (0.70, 0.20, 0.10), "heavy": (0.30, 0.30, 0.40)}[profile]
    form = rng.choices(["full", "mixed", "initials"], weights=weights)[0]
    if form == "full":
        return "".join(syllables)
    if form == "mixed":
        return syllables[0] + "".join(s[0] for s in syllables[1:])
    return "".join(s[0] for s in syllables)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Install deps: "$HOME/Library/Application Support/BiLing/venv/bin/python3" '
        "-m pip install pypinyin jieba",
    )
    parser.add_argument("--source", type=Path, help="Leipzig *-sentences.txt")
    parser.add_argument("--fetch", action="store_true", help="download the corpus")
    parser.add_argument(
        "--cache", type=Path, default=Path.home() / ".cache" / "biling-corpus"
    )
    parser.add_argument("--out-dir", type=Path, default=Path("Tests/Corpus"))
    parser.add_argument("--limit", type=int, default=800, help="clauses to use")
    parser.add_argument("--min-len", type=int, default=6)
    parser.add_argument("--max-len", type=int, default=20)
    parser.add_argument("--seed", type=int, default=20260727)
    args = parser.parse_args()

    try:
        import jieba
        from pypinyin import Style, lazy_pinyin
    except ImportError:
        sys.exit("Missing pypinyin/jieba — see --help for the install command.")
    jieba.setLogLevel(60)

    if args.source:
        source = args.source
    elif args.fetch:
        source = fetch_sentences(args.cache)
    else:
        sys.exit("Pass --source or --fetch.")

    rng = random.Random(args.seed)
    rows: dict[str, list[tuple[str, str, str, str]]] = {"dev": [], "test": []}
    seen: set[str] = set()
    used = 0

    for clause in clauses(source, args.min_len, args.max_len):
        if used >= args.limit:
            break
        if clause in seen:
            continue
        seen.add(clause)

        words = [w for w in jieba.cut(clause) if w.strip()]
        readings = [lazy_pinyin(w, style=Style.NORMAL) for w in words]
        # A reading is only usable if every syllable came back as plain letters;
        # anything else means pypinyin failed on that character.
        if not all(s.isalpha() and s.isascii() for r in readings for s in r):
            continue
        if sum(len(r) for r in readings) != len(clause):
            # Reading count must match character count, or the expected answer
            # cannot correspond to the keys.
            continue

        used += 1
        # Deterministic split by content, so re-running never reshuffles which
        # items are dev and which are test.
        digest = hashlib.sha256(clause.encode()).hexdigest()
        bucket = "dev" if int(digest[:8], 16) % 2 == 0 else "test"

        full_key = "".join("".join(r) for r in readings)
        rows[bucket].append(("full", "-", full_key, clause))

        for profile, name in (("light", "abbrev"), ("heavy", "abbrev-heavy")):
            key = "".join(sample_form(rng, r, profile) for r in readings)
            if key != full_key:
                rows[bucket].append((name, "-", key, clause))

        # Split on a word boundary near the middle: everything before it is
        # already on screen, the rest is what the user is typing now.
        if len(words) >= 3:
            cut = len(words) // 2
            context = "".join(words[:cut])
            tail_words, tail_readings = words[cut:], readings[cut:]
            tail_text = "".join(tail_words)
            tail_full = "".join("".join(r) for r in tail_readings)
            rows[bucket].append(("full-ctx", context, tail_full, tail_text))
            tail_abbrev = "".join(
                sample_form(rng, r, "light") for r in tail_readings
            )
            if tail_abbrev != tail_full:
                rows[bucket].append(
                    ("abbrev-ctx", context, tail_abbrev, tail_text)
                )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for bucket, items in rows.items():
        path = args.out_dir / f"derived-{bucket}.tsv"
        with path.open("w", encoding="utf-8") as handle:
            handle.write(
                f"# Derived from Leipzig Corpora Collection zho_news_2020_10K\n"
                f"# Generated by scripts/build_eval_corpus.py --seed {args.seed}\n"
                f"# category<TAB>context<TAB>pinyin<TAB>expected\n"
            )
            for row in items:
                handle.write("\t".join(row) + "\n")
        counts: dict[str, int] = {}
        for row in items:
            counts[row[0]] = counts.get(row[0], 0) + 1
        breakdown = "  ".join(f"{k} {v}" for k, v in sorted(counts.items()))
        print(f"{path}: {len(items)} items   ({breakdown})")


if __name__ == "__main__":
    main()
