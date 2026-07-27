#!/usr/bin/env python3
"""Build a word-transition model and add it to the lexicon database.

The engine scores a segmentation as a product of independent word
probabilities, which is why it cannot tell 中国工程院·院士 from
中国工程·远远失望: both are sequences of individually plausible words. A
bigram term fixes exactly that class of error, and it is what librime's
octagram and libpinyin's bigram database do.

Probabilities are stored as the conditional c(prev,next)/c(prev). At runtime
the engine interpolates them with the lexicon unigram (Jelinek-Mercer):

    P(w | prev) = λ · P_bigram(w | prev) + (1 − λ) · P_unigram(w)

so an unseen transition degrades to exactly the old behaviour rather than to
zero probability.

**Evaluation hygiene.** Any sentence that also appears in the corpus used to
derive the evaluation set is skipped, so the transition model cannot have
memorised a test item. Pass the eval source with --exclude; the script reports
how many sentences it dropped.

Usage:
    python3 scripts/build_bigrams.py \\
        --source ~/.cache/biling-corpus/zho_news_2020_100K-sentences.txt \\
        --exclude ~/.cache/biling-corpus/zho_news_2020_10K-sentences.txt \\
        --lexicon Sources/BackboneEngine/Resources/lexicon.sqlite3
"""

from __future__ import annotations

import argparse
import math
import re
import sqlite3
import sys
from collections import Counter
from pathlib import Path

CJK = re.compile(r"^[一-鿿]+$")
SPLIT = re.compile(r"[，。！？；：、,.!?;:\s（）()「」“”\"'《》【】\[\]…—\-]+")
START = "\x02"  # sentence-start context, so first words are scored too


def sentences(path: Path):
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            _, _, sentence = line.partition("\t")
            yield sentence.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--exclude", type=Path, action="append", default=[],
                        help="corpus whose sentences must not be trained on")
    parser.add_argument("--lexicon", type=Path, required=True)
    parser.add_argument("--min-count", type=int, default=3,
                        help="prune transitions rarer than this")
    args = parser.parse_args()

    try:
        import jieba
    except ImportError:
        sys.exit("Missing jieba.")
    jieba.setLogLevel(60)

    banned: set[str] = set()
    for path in args.exclude:
        banned.update(sentences(path))

    unigram: Counter[str] = Counter()
    bigram: Counter[tuple[str, str]] = Counter()
    used = skipped = 0

    for sentence in sentences(args.source):
        if sentence in banned:
            skipped += 1
            continue
        used += 1
        for clause in SPLIT.split(sentence):
            if not clause or not CJK.match(clause):
                continue
            words = [w for w in jieba.cut(clause) if w.strip()]
            previous = START
            for word in words:
                unigram[previous] += 1
                bigram[(previous, word)] += 1
                previous = word

    rows = [
        (prev, nxt, count / unigram[prev])
        for (prev, nxt), count in bigram.items()
        if count >= args.min_count and unigram[prev] > 0
    ]

    database = sqlite3.connect(args.lexicon)
    database.executescript(
        """
        DROP TABLE IF EXISTS bigrams;
        CREATE TABLE bigrams (
            prev TEXT NOT NULL,
            next TEXT NOT NULL,
            cond REAL NOT NULL,
            PRIMARY KEY (prev, next)
        ) WITHOUT ROWID;
        """
    )
    database.executemany("INSERT OR REPLACE INTO bigrams VALUES (?,?,?);", rows)
    database.execute(
        "INSERT OR REPLACE INTO metadata(name, value) VALUES ('bigram_count', ?);",
        (str(len(rows)),),
    )
    database.commit()
    database.execute("ANALYZE;")
    database.commit()
    database.close()

    print(
        f"trained on {used:,} sentences (skipped {skipped:,} that appear in the "
        f"evaluation source)\n"
        f"kept {len(rows):,} transitions with count >= {args.min_count} "
        f"out of {len(bigram):,} observed"
    )


if __name__ == "__main__":
    main()
