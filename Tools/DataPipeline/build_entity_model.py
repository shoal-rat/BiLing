#!/usr/bin/env python3
"""Extract non-person named entities into the lexicon.

The name model (build_name_model.py) covers people. This adds the other entity
classes the plan calls for — places and organisations (which include
universities, companies and government bodies) — located the same way: jieba's
part-of-speech tags over corpus text, `ns` for places and `nt` for
organisations. Tagging real usages beats importing a gazetteer for the same
reason it did for names: it yields frequencies, not just membership, and its
provenance is a corpus whose licence is recorded in data/manifests rather than
a database with unclear terms.

The output feeds two consumers:

* entries already in the lexicon get their entity type recorded, which becomes
  candidate provenance the UI and diagnostics can show;
* multi-word entities absent from the lexicon are added as new entries (with
  pinyin from pypinyin), which is how 中国工程院-class compounds stop failing
  as unreachable.

Usage:
    python3 Tools/DataPipeline/build_entity_model.py \\
        --source ~/.cache/biling-corpus/zho_news_2020_300K-sentences.txt \\
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

HAN = re.compile(r"^[一-鿿]+$")


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
    parser.add_argument("--min-count", type=int, default=5)
    # Tagging takes tens of minutes; applying takes seconds. The cache lets the
    # slow half run while other jobs still hold the lexicon read-only, with the
    # write deferred to --apply.
    parser.add_argument("--counts-cache", type=Path)
    parser.add_argument("--tag-only", action="store_true")
    args = parser.parse_args()

    try:
        import jieba
        import jieba.posseg as posseg
        from pypinyin import Style, lazy_pinyin
    except ImportError:
        sys.exit("Missing jieba/pypinyin.")
    jieba.setLogLevel(60)

    counts: dict[str, Counter[str]] = {"place": Counter(), "org": Counter()}
    tag_to_type = {"ns": "place", "nt": "org"}

    if args.counts_cache and args.counts_cache.exists():
        import json

        cached = json.loads(args.counts_cache.read_text())
        for entity_type, entries in cached.items():
            counts[entity_type].update(entries)
    else:
        for source in args.source:
            for sentence in sentences(source):
                for token, flag in posseg.cut(sentence):
                    entity_type = tag_to_type.get(flag)
                    if entity_type is None:
                        continue
                    if not (2 <= len(token) <= 8) or not HAN.match(token):
                        continue
                    counts[entity_type][token] += 1
        if args.counts_cache:
            import json

            args.counts_cache.write_text(
                json.dumps({k: dict(v) for k, v in counts.items()}, ensure_ascii=False)
            )
    if args.tag_only:
        print(f"tagged: {sum(len(c) for c in counts.values())} distinct entities cached")
        return

    database = sqlite3.connect(args.lexicon)
    database.executescript(
        """
        DROP TABLE IF EXISTS entities;
        CREATE TABLE entities (
            text TEXT NOT NULL,
            type TEXT NOT NULL,
            logp REAL NOT NULL,
            PRIMARY KEY (text, type)
        ) WITHOUT ROWID;
        """
    )

    known = {
        row[0] for row in database.execute("SELECT DISTINCT text FROM entries;")
    }
    # The Leipzig news collections mix simplified and traditional text (美國
    # next to 美国). A traditional entity must not enter a simplified lexicon,
    # and script conversion is out of scope here, so the inventory of the
    # lexicon itself is the filter: every character of a new entry must already
    # occur in some existing entry. 國/黨/etc. never do.
    inventory = {char for text in known for char in text}
    added_entries = 0
    entity_rows = []
    for entity_type, counter in counts.items():
        total = max(1, sum(counter.values()))
        for text, count in counter.items():
            if count < args.min_count:
                continue
            if text in known:
                entity_rows.append((text, entity_type, math.log(count / total)))
                continue
            if any(char not in inventory for char in text):
                continue
            entity_rows.append((text, entity_type, math.log(count / total)))
            # An entity the corpus uses repeatedly but the lexicon cannot
            # produce as a unit. Add it, with a weight proportional to its
            # observed count scaled into the lexicon's weight regime (the
            # median lexicon weight is ~1e3; a min-count entity lands low but
            # reachable, and the transition model does the rest).
            readings = lazy_pinyin(text, style=Style.NORMAL)
            if len(readings) != len(text):
                continue
            if not all(r.isalpha() and r.isascii() for r in readings):
                continue
            key = "".join(readings)
            abbrev = "".join(r[0] for r in readings)
            mixed = readings[0] + "".join(r[0] for r in readings[1:])
            database.execute(
                "INSERT OR IGNORE INTO entries(key, text, weight, pinyin, abbrev, mixed) "
                "VALUES (?,?,?,?,?,?);",
                (key, text, float(count) * 50.0, " ".join(readings), abbrev, mixed),
            )
            added_entries += 1

    database.executemany(
        "INSERT OR REPLACE INTO entities VALUES (?,?,?);", entity_rows
    )
    database.execute(
        "INSERT OR REPLACE INTO metadata(name, value) VALUES ('entity_model_version','1');"
    )
    database.commit()
    database.execute("ANALYZE;")
    database.commit()
    database.close()

    print(
        f"entities kept: {len(entity_rows)} "
        f"({sum(1 for r in entity_rows if r[1] == 'place')} places, "
        f"{sum(1 for r in entity_rows if r[1] == 'org')} orgs); "
        f"new lexicon entries: {added_entries}"
    )


if __name__ == "__main__":
    main()
