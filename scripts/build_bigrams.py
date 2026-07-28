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
    parser.add_argument("--source", type=Path, action="append", required=True,
                        help="repeatable; all sources are pooled")
    parser.add_argument("--exclude", type=Path, action="append", default=[],
                        help="corpus whose sentences must not be trained on")
    parser.add_argument("--lexicon", type=Path, required=True)
    parser.add_argument("--min-count", type=int, default=3,
                        help="prune transitions rarer than this")
    parser.add_argument("--min-trigram-count", type=int, default=8,
                        help="prune trigrams rarer than this; trigrams are far "
                             "sparser than bigrams and dominate the table size")
    args = parser.parse_args()

    try:
        import jieba
    except ImportError:
        sys.exit("Missing jieba.")
    jieba.setLogLevel(60)

    # Multi-character lexicon words, for splitting compounds the segmenter
    # treats as single tokens. Loaded once from the existing database.
    lexicon_words: set[str] | None = None
    if args.lexicon.exists():
        connection = sqlite3.connect(args.lexicon)
        lexicon_words = {
            row[0]
            for row in connection.execute(
                "SELECT DISTINCT text FROM entries WHERE length(text) BETWEEN 2 AND 4;"
            )
        }
        connection.close()

    banned: set[str] = set()
    for path in args.exclude:
        banned.update(sentences(path))

    unigram: Counter[str] = Counter()
    bigram: Counter[tuple[str, str]] = Counter()
    # Trigram history counts are kept separately so the conditional can be
    # normalised by c(w-2, w-1) rather than by a bigram count.
    history: Counter[tuple[str, str]] = Counter()
    trigram: Counter[tuple[str, str, str]] = Counter()
    used = skipped = 0

    for source in args.source:
      for sentence in sentences(source):
        if sentence in banned:
            skipped += 1
            continue
        used += 1
        for clause in SPLIT.split(sentence):
            if not clause or not CJK.match(clause):
                continue
            words = [w for w in jieba.cut(clause) if w.strip()]
            previous, before = START, START
            for word in words:
                unigram[previous] += 1
                bigram[(previous, word)] += 1
                history[(before, previous)] += 1
                trigram[(before, previous, word)] += 1
                before, previous = previous, word
                # Compound-internal transitions. jieba tokenises 吉林大学 as a
                # single word, so the transition 吉林→大学 is never counted —
                # and at runtime, when the user types the halves separately or
                # abbreviates the second (jilin + dx), the decoder sees no
                # evidence linking them and raw frequency picks 东西 over
                # 大学. Splitting long tokens at their most balanced
                # lexicon-word boundary recovers exactly those transitions.
                if len(word) >= 4 and lexicon_words is not None:
                    best = None
                    for cut in range(2, len(word) - 1):
                        head, tail = word[:cut], word[cut:]
                        if head in lexicon_words and tail in lexicon_words:
                            balance = min(len(head), len(tail))
                            if best is None or balance > best[0]:
                                best = (balance, head, tail)
                    if best is not None:
                        _, head, tail = best
                        unigram[head] += 1
                        bigram[(head, tail)] += 1

    rows = [
        (prev, nxt, count / unigram[prev])
        for (prev, nxt), count in bigram.items()
        if count >= args.min_count and unigram[prev] > 0
    ]

    trigram_rows = [
        (a, b, c, count / history[(a, b)])
        for (a, b, c), count in trigram.items()
        if count >= args.min_trigram_count and history[(a, b)] > 0
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
        DROP TABLE IF EXISTS trigrams;
        CREATE TABLE trigrams (
            first TEXT NOT NULL,
            second TEXT NOT NULL,
            next TEXT NOT NULL,
            cond REAL NOT NULL,
            PRIMARY KEY (first, second, next)
        ) WITHOUT ROWID;
        """
    )
    database.executemany("INSERT OR REPLACE INTO trigrams VALUES (?,?,?,?);", trigram_rows)
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
        f"kept {len(rows):,} bigrams (>= {args.min_count}) of {len(bigram):,} "
        f"observed, and {len(trigram_rows):,} trigrams "
        f"(>= {args.min_trigram_count}) of {len(trigram):,}"
    )


if __name__ == "__main__":
    main()
