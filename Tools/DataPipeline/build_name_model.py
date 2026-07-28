#!/usr/bin/env python3
"""Derive a Chinese personal-name model and store it in the lexicon.

Character-level fallback makes unlisted names *constructible*, but without a
name model it constructs the wrong ones: for `wangjianlin` the most frequent
character per syllable gives 望见林, while the intended 王建林 uses characters
that are ordinary in names and unremarkable elsewhere. The engine needs to know
that a surname followed by one or two given-name characters is a likely reading.

Two tables are produced:

  surnames(char, logp)        how likely a character is to open a personal name
  given_chars(char, position, logp)
                              how likely a character is at given-name position
                              1 or 2

**Provenance.** The surname inventory is the conventional 百家姓 set — the fact
that 王, 李, 张 and so on are Chinese surnames is public factual information, not
a copyrightable dataset. Their *relative* frequencies, and the entire given-name
character distribution, are estimated from the corpora named on the command
line, so the numbers are reproducible from sources whose licences are recorded
in data/manifests/. Nothing here is copied from a proprietary name database.

Estimation method. Person names are located with jieba's part-of-speech
tagger, which labels them `nr`. Counting every occurrence of a surname
*character* instead does not work and was tried first: 王 also means "king" and
方 opens 方面 and 方式, so ordinary text following them is counted as if it were
a name. Measured, that produced 面, 式 and 的 as the likeliest given-name
characters. Correcting with pointwise mutual information overshot in the other
direction and produced rare characters such as 乂 and 偲. Only tagging actual
names gives a usable distribution.

Usage:
    python3 Tools/DataPipeline/build_name_model.py \\
        --source ~/.cache/biling-corpus/zho_news_2007-2009_1M-sentences.txt \\
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

# The conventional Chinese surname inventory. Membership is public factual
# information; the weights below are estimated from the corpus, not taken from
# any dataset.
SURNAMES = (
    "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤"
)
HAN = re.compile(r"[一-鿿]")


def sentences(path: Path):
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            _, _, sentence = line.partition("\t")
            yield sentence.strip()


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--source", type=Path, action="append", required=True)
    parser.add_argument("--lexicon", type=Path, required=True)
    parser.add_argument("--min-count", type=int, default=20)
    args = parser.parse_args()

    database = sqlite3.connect(args.lexicon)
    # Only characters the lexicon can actually emit are useful as name parts.
    known = {
        row[0]
        for row in database.execute(
            "SELECT DISTINCT text FROM entries WHERE length(text) = 1;"
        )
    }

    try:
        import jieba.posseg as posseg
        import jieba
    except ImportError:
        sys.exit("Missing jieba.")
    jieba.setLogLevel(60)

    surname_count: Counter[str] = Counter()
    given: list[Counter[str]] = [Counter(), Counter()]
    names_seen = 0

    for source in args.source:
        for sentence in sentences(source):
            for token, flag in posseg.cut(sentence):
                # `nr` is jieba's person-name tag. Two to four characters keeps
                # the ordinary Han naming pattern and drops transliterated
                # foreign names, which follow different character statistics.
                if flag != "nr" or not (2 <= len(token) <= 4):
                    continue
                if not all(HAN.match(c) for c in token):
                    continue
                surname, rest = token[0], token[1:]
                if surname not in SURNAMES:
                    continue
                names_seen += 1
                surname_count[surname] += 1
                for offset, character in enumerate(rest[:2]):
                    if character in known:
                        given[offset][character] += 1

    surname_total = max(1, sum(surname_count.values()))

    surname_rows = [
        (character, math.log(count / surname_total))
        for character, count in surname_count.items()
        if count >= args.min_count
    ]

    given_rows = []
    for offset, counter in enumerate(given):
        total = max(1, sum(counter.values()))
        for character, count in counter.items():
            if count < args.min_count:
                continue
            # Counts now come only from tagged names, so the conditional
            # probability is already name-specific and needs no correction.
            given_rows.append((character, offset + 1, math.log(count / total)))

    database.executescript(
        """
        DROP TABLE IF EXISTS surnames;
        CREATE TABLE surnames (
            char TEXT PRIMARY KEY,
            logp REAL NOT NULL
        ) WITHOUT ROWID;
        DROP TABLE IF EXISTS given_chars;
        CREATE TABLE given_chars (
            char TEXT NOT NULL,
            position INTEGER NOT NULL,
            logp REAL NOT NULL,
            PRIMARY KEY (char, position)
        ) WITHOUT ROWID;
        """
    )
    database.executemany("INSERT OR REPLACE INTO surnames VALUES (?,?);", surname_rows)
    database.executemany(
        "INSERT OR REPLACE INTO given_chars VALUES (?,?,?);", given_rows
    )
    database.execute(
        "INSERT OR REPLACE INTO metadata(name, value) VALUES ('name_model_version','1');"
    )
    database.commit()
    database.execute("ANALYZE;")
    database.commit()
    database.close()

    print(
        f"tagged names: {names_seen:,}\n"
        f"surnames kept: {len(surname_rows)}\n"
        f"given-name characters kept: {len(given_rows)} "
        f"(positions 1 and 2, min count {args.min_count})"
    )


if __name__ == "__main__":
    main()
