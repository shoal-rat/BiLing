#!/usr/bin/env python3
"""Compile the two character tries the runtime walks against the keys.

* `qinpu.trie` — 琴谱, the score: dictionary words with unigram log-probs.
* `ziqi-vocab.trie` — 子期's vocabulary: every Han token of the model, plus
  a table of Latin tokens (letters → token ids).

Both use one binary layout, read by `Sources/ZhiyinCore/Score/Trie.swift`
straight from a memory map — no parsing at launch:

    header   "ZYTR" u32 version u32 kind u32 nodes u32 entries u32 pool
             u32 strings u32 latin u32 syllableBytes
    syllables  newline-separated inventory (index = syllable id)
    nodes      [char, firstChild, childCount, firstEntry, entryCount,
                readingStart, readingCount] × u32, node 0 is the root;
                children of a node are contiguous and sorted by char
    entries    [payload u32, logp f32]   payload = token id | string offset
    pool       u16 syllable ids (each node's readings)
    rootIndex  (syllables+1) u32 offsets, then u32 root-child node indices:
               which first characters can carry each syllable
    strings    [len u8][utf8] for word entries
    latin      [string offset u32, token u32] sorted by letters

All integers little-endian; every section starts 4-byte aligned.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import struct
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pinyin import SYLLABLES, char_readings, toneless  # noqa: E402

HAN = re.compile(r"^[㐀-䶿一-鿿]+$")
LATIN = re.compile(r"^ ?[A-Za-z]+$")
INVENTORY = sorted(SYLLABLES)
SID = {s: i for i, s in enumerate(INVENTORY)}


_SIMPLIFIED: set[str] | None = None


def simplified(ch: str) -> bool:
    """A character 知音 may write: GB2312, or common in our (simplified) corpora.

    The model's vocabulary and the Rime tables both carry traditional forms;
    without this the decoder happily writes 發佈會 for fabuhui.
    """
    global _SIMPLIFIED
    if _SIMPLIFIED is None:
        counts_path = Path(__file__).resolve().parents[3] / "work" / "word_counts.json"
        extra: dict[str, int] = {}
        if counts_path.exists():
            for w, n in json.loads(counts_path.read_text()).items():
                for c in w:
                    extra[c] = extra.get(c, 0) + n
        _SIMPLIFIED = {c for c, n in extra.items() if n >= 30}
    try:
        ch.encode("gb2312")
        return True
    except UnicodeEncodeError:
        return ch in _SIMPLIFIED


class Node:
    __slots__ = ("char", "children", "entries")

    def __init__(self, char: str):
        self.char = char
        self.children: dict[str, Node] = {}
        self.entries: list[tuple[int, float]] = []


def insert(root: Node, text: str, payload: int, logp: float) -> None:
    node = root
    for ch in text:
        nxt = node.children.get(ch)
        if nxt is None:
            nxt = node.children[ch] = Node(ch)
        node = nxt
    node.entries.append((payload, logp))


def pad4(b: bytearray) -> None:
    while len(b) % 4:
        b.append(0)


def serialize(root: Node, kind: int, strings: bytes, latin: list[tuple[int, int]], out: Path) -> None:
    # Breadth-first so each node's children are contiguous.
    order: list[Node] = [root]
    first_child: list[int] = []
    i = 0
    while i < len(order):
        node = order[i]
        kids = sorted(node.children.values(), key=lambda n: ord(n.char))
        first_child.append(len(order))
        order.extend(kids)
        i += 1
    index = {id(n): k for k, n in enumerate(order)}
    nodes = bytearray()
    entries = bytearray()
    pool: list[int] = []
    entry_count = 0
    for k, node in enumerate(order):
        readings = [SID[s] for s in char_readings(node.char)] if node.char else []
        ents = sorted(node.entries, key=lambda e: -e[1])
        nodes += struct.pack(
            "<7I",
            ord(node.char) if node.char else 0,
            first_child[k],
            len(node.children),
            entry_count,
            len(ents),
            len(pool),
            len(readings),
        )
        pool.extend(readings)
        for payload, logp in ents:
            entries += struct.pack("<If", payload, logp)
        entry_count += len(ents)
    # Root index: syllable -> root children whose character has that reading.
    by_syllable: dict[int, list[int]] = defaultdict(list)
    for child in root.children.values():
        for s in char_readings(child.char):
            by_syllable[SID[s]].append(index[id(child)])
    root_index = bytearray()
    offsets = [0]
    flat: list[int] = []
    for sid in range(len(INVENTORY)):
        flat.extend(sorted(by_syllable.get(sid, ())))
        offsets.append(len(flat))
    root_index += struct.pack(f"<{len(offsets)}I", *offsets)
    root_index += struct.pack(f"<{len(flat)}I", *flat)

    syllable_bytes = "\n".join(INVENTORY).encode()
    blob = bytearray()
    blob += b"ZYTR"
    blob += struct.pack(
        "<8I", 1, kind, len(order), entry_count, len(pool), len(strings), len(latin), len(syllable_bytes)
    )
    blob += syllable_bytes
    pad4(blob)
    blob += nodes
    blob += entries
    blob += struct.pack(f"<{len(pool)}H", *pool)
    pad4(blob)
    blob += root_index
    blob += strings
    pad4(blob)
    for off, tid in latin:
        blob += struct.pack("<II", off, tid)
    out.write_bytes(bytes(blob))
    print(f"{out.name}: {len(order)} nodes, {entry_count} entries, {len(latin)} latin, {len(blob)/1e6:.1f} MB")


def build_vocab(tokenizer_path: Path, out: Path) -> None:
    from tokenizers import Tokenizer

    tok = Tokenizer.from_file(str(tokenizer_path))
    root = Node("")
    latin_rows: list[tuple[str, int]] = []
    for tid in range(151643):
        s = tok.decode([tid])
        if HAN.match(s) and all(char_readings(c) and simplified(c) for c in s):
            insert(root, s, tid, 0.0)
        elif LATIN.match(s) and (len(s.strip()) >= 2 or s.strip().isupper()):
            # Single letters only in capitals (K歌, B站, 栓Q): a lone lowercase
            # letter is an initial, never Latin output.
            latin_rows.append((s.strip().lower(), tid))
    strings = bytearray()
    latin: list[tuple[int, int]] = []
    for letters, tid in sorted(latin_rows):
        latin.append((len(strings), tid))
        data = letters.encode()
        strings += bytes([len(data)]) + data
    serialize(root, 0, bytes(strings), latin, out)
    # The Swift side also needs each token's text and whether it leads with a
    # space (Latin), to rebuild candidate strings without the tokenizer.


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
            text = fields[0].strip()
            try:
                weight = float(fields[2]) if len(fields) > 2 and fields[2] else 0.0
            except ValueError:
                weight = 0.0
            syllables = [toneless(s) for s in fields[1].split()]
            yield text, syllables, weight


def build_words(lexicon_dir: Path, counts_path: Path | None, out: Path, max_words: int) -> None:
    """Dictionary words, priced by a blend of corpus counts and Rime weights.

    Rime weights are good relative evidence but carry runaway entries
    (李双代数 at 40M, twenty times 就是). Corpus counts from our own
    segmented text are trustworthy where they exist. A word's weight is the
    corpus count when the corpus saw it, otherwise its Rime weight scaled
    onto the corpus range and capped so it can never outrank common words.
    """
    rime: dict[str, float] = {}
    for name, boost in (("wanxiang-jichu.dict.yaml", 1.0), ("pinyin_simp.dict.yaml", 0.25)):
        for text, syllables, weight in rime_rows(lexicon_dir / name):
            if not HAN.match(text) or len(text) > 8 or len(syllables) != len(text):
                continue
            if not all(s in SYLLABLES for s in syllables):
                continue
            if not all(char_readings(c) and simplified(c) for c in text):
                continue
            rime[text] = max(rime.get(text, 0.0), weight * boost)
    corpus: dict[str, float] = {}
    if counts_path and counts_path.exists():
        corpus = {k: float(v) for k, v in json.loads(counts_path.read_text()).items()}
    # Map Rime weights onto the corpus scale by matching medians of the overlap.
    overlap = [(corpus[w], rime[w]) for w in rime if w in corpus and rime[w] > 0]
    if overlap:
        ratios = sorted(c / r for c, r in overlap)
        scale = ratios[len(ratios) // 2]
    else:
        scale = 1.0
    cap = sorted(corpus.values())[-2000] if len(corpus) > 2000 else float("inf")
    weights: dict[str, float] = {}
    for w, r in rime.items():
        if w in corpus:
            weights[w] = corpus[w] + 0.5
        else:
            weights[w] = min(r * scale, cap) + 0.1
    for w, c in corpus.items():
        if w not in weights and HAN.match(w) and len(w) <= 8 and all(char_readings(ch) and simplified(ch) for ch in w):
            weights[w] = c + 0.5
    # 新词包: words people use now that older dictionaries lack.
    xinci = Path(__file__).resolve().parent / "xinci" / "words.txt"
    if xinci.exists():
        floor = sorted(weights.values())[-20000] if len(weights) > 20000 else 1000.0
        for line in xinci.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            word = line.split()[0]
            if HAN.match(word) and all(char_readings(c) for c in word):
                weights[word] = max(weights.get(word, 0.0), floor)
    # Every typeable character is reachable on its own.
    for ch, readings in ((c, char_readings(c)) for c in map(chr, range(0x4E00, 0xA000))):
        if readings and ch not in weights and simplified(ch):
            weights[ch] = 0.05
    ranked = sorted(weights.items(), key=lambda kv: -kv[1])
    singles = [kv for kv in ranked if len(kv[0]) == 1]
    multis = [kv for kv in ranked if len(kv[0]) > 1][: max_words]
    kept = singles + multis
    total = sum(w for _, w in kept)
    root = Node("")
    strings = bytearray()
    for text, w in kept:
        data = text.encode()
        offset = len(strings)
        strings += bytes([len(data)]) + data
        insert(root, text, offset, math.log(w / total))
    serialize(root, 1, bytes(strings), [], out)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--tokenizer", type=Path)
    p.add_argument("--lexicon", type=Path)
    p.add_argument("--counts", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--max-words", type=int, default=400000)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    if a.tokenizer:
        build_vocab(a.tokenizer, a.out / "ziqi-vocab.trie")
    if a.lexicon:
        build_words(a.lexicon, a.counts, a.out / "qinpu.trie", a.max_words)


if __name__ == "__main__":
    main()
