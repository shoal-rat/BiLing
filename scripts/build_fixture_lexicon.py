#!/usr/bin/env python3
"""Build the small fixture lexicon that CI tests run against.

The production lexicon (Sources/BackboneEngine/Resources/lexicon.sqlite3) is
a 168+ MB Git LFS object, so CI checks out without LFS and points
BILING_LEXICON_PATH at the file this script produces. The fixture carries the
exact production schema — entries with key/text/weight/pinyin/abbrev/mixed and
the partial index on `mixed`, bigrams, trigrams, surnames, given_chars, and a
metadata table with format_version 3 — over a hand-chosen vocabulary of about
two hundred words, so structural tests (engine init, exact lookup,
abbreviation, sentence lattice, name model, determinism) exercise every code
path without the real data.

Standard library only; no pip dependencies. Output is checked into git as a
regular blob (see the .gitattributes exception), so re-run this script and
commit the result whenever the schema changes:

    python3 scripts/build_fixture_lexicon.py
"""

from __future__ import annotations

import math
import sqlite3
import sys
from pathlib import Path

# Sentence-start context marker; must match DictTrie.sentenceStart ("\u{2}").
START = "\x02"

# (text, tone-free pinyin with spaces, corpus-style weight). Weights are
# plausible relative frequencies, not measurements: common function words in
# the millions, ordinary words in the hundreds of thousands, rare fillers in
# the thousands. What matters is the ordering they induce, not the values.
WORDS: list[tuple[str, str, float]] = [
    # --- multi-syllable vocabulary ---
    ("你好", "ni hao", 3_200_000),
    ("我们", "wo men", 8_000_000),
    ("中国", "zhong guo", 6_000_000),
    ("吉林", "ji lin", 400_000),
    ("大学", "da xue", 2_500_000),
    ("垃圾", "la ji", 600_000),
    ("学校", "xue xiao", 1_800_000),
    ("吉林大学", "ji lin da xue", 120_000),
    ("中国人民", "zhong guo ren min", 90_000),
    ("人民", "ren min", 2_000_000),
    ("谢谢", "xie xie", 2_200_000),
    ("上海", "shang hai", 2_400_000),
    ("朋友", "peng you", 2_100_000),
    ("工作", "gong zuo", 3_000_000),
    ("时间", "shi jian", 3_100_000),
    ("问题", "wen ti", 2_900_000),
    ("学习", "xue xi", 2_200_000),
    ("计算机", "ji suan ji", 400_000),
    ("输入法", "shu ru fa", 150_000),
    ("银行", "yin hang", 1_400_000),
    ("行走", "xing zou", 300_000),
    ("重要", "zhong yao", 2_600_000),
    ("重新", "chong xin", 1_200_000),
    ("唱歌", "chang ge", 500_000),
    ("快乐", "kuai le", 1_600_000),
    ("绿色", "lv se", 800_000),
    ("利息", "li xi", 300_000),
    ("力系", "li xi", 1_500),
    ("没有", "mei you", 5_000_000),
    ("还有", "hai you", 2_500_000),
    ("空调", "kong tiao", 400_000),
    ("北京", "bei jing", 2_600_000),
    ("电脑", "dian nao", 900_000),
    ("手机", "shou ji", 1_600_000),
    ("今天", "jin tian", 2_800_000),
    ("明天", "ming tian", 1_900_000),
    ("现在", "xian zai", 3_200_000),
    ("知道", "zhi dao", 3_400_000),
    ("可以", "ke yi", 4_500_000),
    ("什么", "shen me", 5_000_000),
    ("怎么", "zen me", 2_500_000),
    ("时候", "shi hou", 2_400_000),
    ("老师", "lao shi", 1_700_000),
    ("同学", "tong xue", 800_000),
    ("天气", "tian qi", 700_000),
    ("高兴", "gao xing", 900_000),
    ("喜欢", "xi huan", 1_800_000),
    ("东西", "dong xi", 1_900_000),
    ("事情", "shi qing", 1_600_000),
    ("生活", "sheng huo", 1_800_000),
    ("世界", "shi jie", 2_000_000),
    ("因为", "yin wei", 2_700_000),
    ("所以", "suo yi", 2_500_000),
    ("但是", "dan shi", 2_600_000),
    ("如果", "ru guo", 2_200_000),
    ("已经", "yi jing", 2_600_000),
    ("非常", "fei chang", 1_800_000),
    ("觉得", "jue de", 1_900_000),
    ("开始", "kai shi", 2_100_000),
    ("需要", "xu yao", 2_400_000),
    ("中文", "zhong wen", 600_000),
    ("汉字", "han zi", 300_000),
    ("拼音", "pin yin", 200_000),
    ("词典", "ci dian", 150_000),
    ("大家", "da jia", 2_300_000),
    ("学生", "xue sheng", 1_600_000),
    ("专业", "zhuan ye", 800_000),
    ("经济", "jing ji", 1_400_000),
    ("建设", "jian she", 1_200_000),
    ("学院", "xue yuan", 600_000),
    ("图书馆", "tu shu guan", 300_000),
    ("食堂", "shi tang", 200_000),
    ("宿舍", "su she", 250_000),
    # --- single characters, so the sentence lattice and the name model have
    # character edges for every syllable the words above use ---
    ("你", "ni", 5_000_000),
    ("我", "wo", 9_000_000),
    ("他", "ta", 6_000_000),
    ("她", "ta", 3_000_000),
    ("好", "hao", 4_000_000),
    ("的", "de", 15_000_000),
    ("是", "shi", 9_000_000),
    ("了", "le", 8_000_000),
    ("了", "liao", 200_000),
    ("在", "zai", 6_000_000),
    ("有", "you", 7_000_000),
    ("人", "ren", 5_000_000),
    ("们", "men", 3_000_000),
    ("中", "zhong", 4_000_000),
    ("国", "guo", 4_000_000),
    ("吉", "ji", 200_000),
    ("林", "lin", 600_000),
    ("大", "da", 5_000_000),
    ("学", "xue", 3_000_000),
    ("垃", "la", 100_000),
    ("圾", "ji", 100_000),
    ("校", "xiao", 500_000),
    ("小", "xiao", 4_000_000),
    ("王", "wang", 800_000),
    ("望", "wang", 400_000),
    ("建", "jian", 700_000),
    ("见", "jian", 1_500_000),
    ("明", "ming", 800_000),
    ("华", "hua", 700_000),
    ("李", "li", 700_000),
    ("张", "zhang", 700_000),
    ("刘", "liu", 500_000),
    ("陈", "chen", 500_000),
    ("爱", "ai", 1_200_000),
    ("饭", "fan", 800_000),
    ("范", "fan", 200_000),
    ("凡", "fan", 150_000),
    ("翻", "fan", 300_000),
    ("蓝", "lan", 400_000),
    ("兰", "lan", 300_000),
    ("男", "nan", 600_000),
    ("难", "nan", 700_000),
    ("银", "yin", 300_000),
    ("行", "xing", 2_000_000),
    ("行", "hang", 800_000),
    ("重", "zhong", 1_000_000),
    ("重", "chong", 400_000),
    ("唱", "chang", 300_000),
    ("歌", "ge", 600_000),
    ("快", "kuai", 1_200_000),
    ("乐", "le", 800_000),
    ("乐", "yue", 200_000),
    ("绿", "lv", 300_000),
    ("色", "se", 800_000),
    ("利", "li", 800_000),
    ("息", "xi", 400_000),
    ("第", "di", 2_000_000),
    ("电", "dian", 1_500_000),
    ("脑", "nao", 400_000),
    ("手", "shou", 1_500_000),
    ("机", "ji", 2_000_000),
    ("老", "lao", 2_000_000),
    ("师", "shi", 1_000_000),
    ("同", "tong", 1_500_000),
    ("东", "dong", 1_500_000),
    ("西", "xi", 1_500_000),
    ("事", "shi", 2_000_000),
    ("情", "qing", 1_200_000),
    ("生", "sheng", 2_500_000),
    ("活", "huo", 1_000_000),
    ("世", "shi", 800_000),
    ("界", "jie", 800_000),
    ("专", "zhuan", 500_000),
    ("业", "ye", 1_500_000),
    ("经", "jing", 1_800_000),
    ("济", "ji", 600_000),
    ("京", "jing", 800_000),
    ("北", "bei", 1_200_000),
    ("还", "hai", 2_500_000),
    ("还", "huan", 500_000),
    ("没", "mei", 2_500_000),
    ("空", "kong", 800_000),
    ("调", "tiao", 500_000),
    ("调", "diao", 300_000),
    ("和", "he", 4_000_000),
    ("就", "jiu", 4_000_000),
    ("说", "shuo", 3_500_000),
    ("想", "xiang", 2_500_000),
    ("会", "hui", 4_000_000),
    ("能", "neng", 3_000_000),
    ("来", "lai", 4_000_000),
    ("去", "qu", 3_000_000),
    ("看", "kan", 3_000_000),
    ("吃", "chi", 1_500_000),
    ("喝", "he", 500_000),
    ("水", "shui", 1_500_000),
    ("火", "huo", 800_000),
    ("山", "shan", 1_000_000),
    ("口", "kou", 1_000_000),
    ("日", "ri", 1_500_000),
    ("月", "yue", 1_200_000),
    ("年", "nian", 3_000_000),
    ("心", "xin", 1_800_000),
    ("新", "xin", 2_000_000),
    ("音", "yin", 800_000),
    ("词", "ci", 600_000),
    ("典", "dian", 300_000),
    ("汉", "han", 500_000),
    ("字", "zi", 1_500_000),
    ("拼", "pin", 300_000),
    ("输", "shu", 500_000),
    ("入", "ru", 1_200_000),
    ("法", "fa", 2_000_000),
    ("计", "ji", 800_000),
    ("算", "suan", 800_000),
    ("一", "yi", 8_000_000),
    ("不", "bu", 7_000_000),
    ("谢", "xie", 900_000),
    ("朋", "peng", 400_000),
    ("友", "you", 800_000),
    ("工", "gong", 1_500_000),
    ("作", "zuo", 2_000_000),
    ("时", "shi", 2_500_000),
    ("间", "jian", 1_500_000),
    ("问", "wen", 1_500_000),
    ("题", "ti", 1_000_000),
    ("习", "xi", 800_000),
    ("上", "shang", 4_000_000),
    ("海", "hai", 1_500_000),
    ("天", "tian", 3_000_000),
    ("气", "qi", 1_500_000),
]

# P(next | prev) rows, enough to give the decoder real transition evidence on
# the fixture vocabulary (including the installer's release-gate sentence).
BIGRAMS: list[tuple[str, str, float]] = [
    (START, "你好", 0.02),
    (START, "我们", 0.03),
    (START, "中国", 0.02),
    (START, "吉林大学", 0.002),
    (START, "今天", 0.02),
    ("吉林", "大学", 0.30),
    ("吉林大学", "垃圾", 0.001),
    ("垃圾", "学校", 0.05),
    ("中国", "人民", 0.20),
    ("人民", "银行", 0.10),
    ("我们", "的", 0.20),
    ("你", "好", 0.10),
    ("没", "有", 0.30),
    ("学习", "中文", 0.01),
    ("北京", "还有", 0.01),
    ("今天", "天气", 0.05),
    ("天气", "非常", 0.05),
    ("非常", "好", 0.10),
    ("大学", "学生", 0.02),
    ("学生", "宿舍", 0.02),
]

# P(next | first, second) rows for the rescoring pass.
TRIGRAMS: list[tuple[str, str, str, float]] = [
    (START, "吉林大学", "垃圾", 0.40),
    ("吉林大学", "垃圾", "学校", 0.60),
    (START, "我们", "的", 0.20),
    ("中国", "人民", "银行", 0.30),
    (START, "今天", "天气", 0.10),
    ("今天", "天气", "非常", 0.10),
]

# Personal-name model: log-probabilities, matching build_name_model.py output.
SURNAMES: list[tuple[str, float]] = [
    ("王", -1.2),
    ("李", -1.4),
    ("张", -1.5),
    ("刘", -2.0),
    ("陈", -2.0),
    ("林", -2.5),
]

GIVEN_CHARS: list[tuple[str, int, float]] = [
    ("建", 1, -2.0),
    ("明", 1, -2.2),
    ("华", 1, -2.4),
    ("林", 1, -2.6),
    ("建", 2, -2.5),
    ("明", 2, -2.4),
    ("华", 2, -2.1),
    ("林", 2, -2.3),
]

MAX_BYTES = 2 * 1024 * 1024


def codes(pinyin: str) -> tuple[str, str, str, str]:
    """key, abbrev, mixed, display — same derivation as build_dictionary.py."""
    syllables = pinyin.split()
    key = "".join(syllables)
    abbrev = "".join(s[0] for s in syllables)
    mixed = (
        syllables[0] + "".join(s[0] for s in syllables[1:])
        if len(syllables) > 1
        else ""
    )
    return key, abbrev, mixed, " ".join(syllables)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output = (
        Path(sys.argv[1])
        if len(sys.argv) > 1
        else root / "Tests" / "Fixtures" / "fixture-lexicon.sqlite3"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()

    database = sqlite3.connect(output)
    # Schema copied verbatim from scripts/build_dictionary.py,
    # scripts/build_bigrams.py and Tools/DataPipeline/build_name_model.py —
    # including the partial index predicate `mixed <> ''` that the engine's
    # mixed-code query repeats so the planner can use the index.
    database.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE entries (
            key TEXT NOT NULL,
            text TEXT NOT NULL,
            weight REAL NOT NULL,
            pinyin TEXT NOT NULL,
            abbrev TEXT NOT NULL,
            mixed TEXT NOT NULL,
            PRIMARY KEY (key, text)
        ) WITHOUT ROWID;
        CREATE INDEX entries_abbrev ON entries(abbrev, weight);
        CREATE INDEX entries_mixed ON entries(mixed, weight) WHERE mixed <> '';
        CREATE TABLE metadata (
            name TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE bigrams (
            prev TEXT NOT NULL,
            next TEXT NOT NULL,
            cond REAL NOT NULL,
            PRIMARY KEY (prev, next)
        ) WITHOUT ROWID;
        CREATE TABLE trigrams (
            first TEXT NOT NULL,
            second TEXT NOT NULL,
            next TEXT NOT NULL,
            cond REAL NOT NULL,
            PRIMARY KEY (first, second, next)
        ) WITHOUT ROWID;
        CREATE TABLE surnames (
            char TEXT PRIMARY KEY,
            logp REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE given_chars (
            char TEXT NOT NULL,
            position INTEGER NOT NULL,
            logp REAL NOT NULL,
            PRIMARY KEY (char, position)
        ) WITHOUT ROWID;
        """
    )

    rows = []
    seen: set[tuple[str, str]] = set()
    for text, pinyin, weight in WORDS:
        key, abbrev, mixed, display = codes(pinyin)
        if (key, text) in seen:
            raise SystemExit(f"duplicate fixture entry: {key} {text}")
        seen.add((key, text))
        rows.append((key, text, float(weight), display, abbrev, mixed))
    database.executemany(
        "INSERT INTO entries(key, text, weight, pinyin, abbrev, mixed)"
        " VALUES (?, ?, ?, ?, ?, ?);",
        rows,
    )
    database.executemany("INSERT INTO bigrams VALUES (?, ?, ?);", BIGRAMS)
    database.executemany("INSERT INTO trigrams VALUES (?, ?, ?, ?);", TRIGRAMS)
    database.executemany("INSERT INTO surnames VALUES (?, ?);", SURNAMES)
    database.executemany("INSERT INTO given_chars VALUES (?, ?, ?);", GIVEN_CHARS)

    count = database.execute("SELECT COUNT(*) FROM entries;").fetchone()[0]
    log_max = math.log(
        database.execute("SELECT MAX(weight) FROM entries;").fetchone()[0]
    )
    log_total = math.log(
        database.execute("SELECT SUM(weight) FROM entries;").fetchone()[0]
    )
    database.executemany(
        "INSERT INTO metadata(name, value) VALUES (?, ?);",
        [
            ("entry_count", str(count)),
            ("log_max_weight", repr(log_max)),
            ("log_total_weight", repr(log_total)),
            ("bigram_count", str(len(BIGRAMS))),
            ("name_model_version", "1"),
            ("sources", "build_fixture_lexicon.py:1"),
            ("format_version", "3"),
        ],
    )
    database.execute("ANALYZE;")
    database.commit()
    database.execute("VACUUM;")
    database.close()

    size = output.stat().st_size
    if size > MAX_BYTES:
        raise SystemExit(f"fixture grew to {size} bytes; the cap is {MAX_BYTES}")
    print(
        f"wrote {count} entries, {len(BIGRAMS)} bigrams, {len(TRIGRAMS)} "
        f"trigrams, {len(SURNAMES)} surnames to {output} ({size:,} bytes)"
    )


if __name__ == "__main__":
    main()
