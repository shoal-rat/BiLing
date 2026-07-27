#!/usr/bin/env python3
"""Compile attributed Rime dictionaries into BiLing's indexed lexicon database."""

from __future__ import annotations

import argparse
import math
import re
import sqlite3
import unicodedata
from pathlib import Path


PINYIN_TOKEN = re.compile(r"^[a-zv]+$")
U_UMLAUT_FORMS = str.maketrans({character: "v" for character in "üǖǘǚǜÜǕǗǙǛ"})


def tone_free_pinyin(value: str) -> list[str]:
    """Convert marked Pinyin (for example, `jí lín`) to ASCII lookup syllables."""
    value = value.translate(U_UMLAUT_FORMS).lower()
    decomposed = unicodedata.normalize("NFD", value)
    unmarked = "".join(
        character
        for character in decomposed
        if unicodedata.category(character) != "Mn"
    )
    return [
        token
        for token in unmarked.replace("u:", "v").split()
        if PINYIN_TOKEN.fullmatch(token)
    ]


def rows(path: Path):
    in_body = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not in_body:
            if raw.strip() == "...":
                in_body = True
            continue
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) < 2:
            continue
        text, pinyin = fields[0].strip(), fields[1].strip()
        if not text or not pinyin:
            continue
        syllables = tone_free_pinyin(pinyin)
        if not syllables:
            continue
        key = "".join(syllables)
        abbrev = "".join(syllable[0] for syllable in syllables)
        # "First syllable in full, the rest as initials" — how people actually
        # abbreviate mid-sentence (没有 → meiy, 空调 → kongt, 学的 → xued).
        # Single-syllable words would only duplicate `key`, so they store "".
        mixed = (
            syllables[0] + "".join(syllable[0] for syllable in syllables[1:])
            if len(syllables) > 1
            else ""
        )
        try:
            weight = float(fields[2]) if len(fields) > 2 and fields[2] else 1.0
        except ValueError:
            weight = 1.0
        yield key, text, max(0.0, weight), " ".join(syllables), abbrev, mixed


def parse_source(value: str) -> tuple[Path, float]:
    path_text, separator, boost_text = value.rpartition(":")
    if separator:
        try:
            return Path(path_text), float(boost_text)
        except ValueError:
            pass
    return Path(value), 1.0


def prepare_database(path: Path) -> sqlite3.Connection:
    if path.exists():
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(path)
    database.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        PRAGMA locking_mode = EXCLUSIVE;
        CREATE TABLE entries (
            key TEXT NOT NULL,
            text TEXT NOT NULL,
            weight REAL NOT NULL,
            pinyin TEXT NOT NULL,
            abbrev TEXT NOT NULL,
            mixed TEXT NOT NULL,
            PRIMARY KEY (key, text)
        ) WITHOUT ROWID;
        -- (code, weight) lets `WHERE code = ? ORDER BY weight DESC` run as a
        -- backwards index scan with no sort step.
        CREATE INDEX entries_abbrev ON entries(abbrev, weight);
        CREATE INDEX entries_mixed ON entries(mixed, weight) WHERE mixed <> '';
        CREATE TABLE metadata (
            name TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        """
    )
    return database


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        action="append",
        required=True,
        help="Rime YAML path, optionally followed by :WEIGHT_BOOST",
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    sources = [parse_source(value) for value in args.source]
    database = prepare_database(args.output)
    upsert = """
        INSERT INTO entries(key, text, weight, pinyin, abbrev, mixed)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(key, text) DO UPDATE SET
            weight = excluded.weight,
            pinyin = excluded.pinyin,
            abbrev = excluded.abbrev,
            mixed = excluded.mixed,
            abbrev = excluded.abbrev
        WHERE excluded.weight > entries.weight;
    """

    seen_rows = 0
    for source, boost in sources:
        if not source.is_file():
            raise SystemExit(f"Missing dictionary source: {source}")
        batch: list[tuple[str, str, float, str]] = []
        for key, text, weight, pinyin, abbrev, mixed in rows(source):
            batch.append((key, text, weight * boost, pinyin, abbrev, mixed))
            if len(batch) == 20_000:
                database.executemany(upsert, batch)
                database.commit()
                seen_rows += len(batch)
                batch.clear()
        if batch:
            database.executemany(upsert, batch)
            database.commit()
            seen_rows += len(batch)

    count = database.execute("SELECT COUNT(*) FROM entries;").fetchone()[0]
    database.executemany(
        "INSERT INTO metadata(name, value) VALUES (?, ?);",
        [
            ("entry_count", str(count)),
            # log of the summed corpus weight: the normaliser that turns a raw
            # weight into a unigram log-probability, and therefore the cost of
            # introducing one more segment into a segmentation.
            (
                "log_max_weight",
                repr(
                    math.log(
                        database.execute(
                            "SELECT MAX(weight) FROM entries;"
                        ).fetchone()[0]
                        or 1.0
                    )
                ),
            ),
            (
                "log_total_weight",
                repr(
                    math.log(
                        database.execute(
                            "SELECT SUM(weight) FROM entries;"
                        ).fetchone()[0]
                        or 1.0
                    )
                ),
            ),
            (
                "sources",
                ";".join(f"{path.name}:{boost:g}" for path, boost in sources),
            ),
            ("format_version", "3"),
        ],
    )
    database.execute("ANALYZE;")
    database.commit()
    database.execute("VACUUM;")
    database.close()

    print(
        f"Read {seen_rows:,} rows and wrote {count:,} unique entries "
        f"to {args.output}"
    )


if __name__ == "__main__":
    main()
