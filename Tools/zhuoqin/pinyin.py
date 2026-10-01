"""Pinyin rules shared by every stage of 斫琴 (the model workshop).

The same three rules decide what a key sequence may spell, everywhere:

* a syllable is typed **in full** (`zhong`), or
* as an **initial** (`z`, or `zh` for the retroflex initials) — but only when
  the full spelling does not match at that position, so `dan` is never
  大 + 安 while `dg` is 大哥, or
* as a **prefix** of itself, only at the very end of the keys — the syllable
  the user is still typing.

The typing simulator produces only keys these rules can read back, the
constrained decoder admits only tokens these rules allow, and the Swift
engine (`Sources/ZhiyinKit/Strings`) implements the same three rules. If any
of the three drifts, training data stops matching what the decoder can say.
"""

from __future__ import annotations

import json
import random
import unicodedata
from functools import lru_cache
from pathlib import Path

from pypinyin.pinyin_dict import pinyin_dict

# Readings pypinyin knows that nobody types in an input method.
_EXCLUDED = {"hng", "hm", "m", "n", "ng", "ê"}

# Interjections whose dictionary reading is not what people type.
_OVERRIDES = {
    "嗯": ["en"],
    "呣": ["mu"],
    "噷": ["hen"],
    "哼": ["heng"],
    "唔": ["wu"],
}

# ü is typed v, and many people also type u after l/n.
_ALIASES = {"lve": ["lue"], "nve": ["nue"]}


def toneless(marked: str) -> str:
    decomposed = unicodedata.normalize("NFD", marked.lower())
    # ü may arrive precomposed with a tone (ǜ): decomposition leaves u + U+0308.
    decomposed = decomposed.replace("u\u0308", "v")
    plain = "".join(c for c in decomposed if unicodedata.category(c) != "Mn")
    return plain.replace("u:", "v")


def _build_inventory() -> set[str]:
    out: set[str] = set()
    for code, readings in pinyin_dict.items():
        if 0x4E00 <= code <= 0x9FFF:
            for reading in readings.split(","):
                s = toneless(reading)
                if s.isalpha() and s.isascii() and s not in _EXCLUDED:
                    out.add(s)
    for readings in _OVERRIDES.values():
        out.update(readings)
    return out


SYLLABLES: frozenset[str] = frozenset(_build_inventory())
RETROFLEX = ("zh", "ch", "sh")


_TABLE_PATH = Path(__file__).resolve().parents[2] / "Resources" / "Data" / "char_readings.json"
_TABLE: dict[str, list[str]] | None = (
    json.loads(_TABLE_PATH.read_text(encoding="utf-8")) if _TABLE_PATH.exists() else None
)


@lru_cache(maxsize=None)
def char_readings(ch: str) -> tuple[str, ...]:
    """The readings of one character people actually type, most common first.

    Comes from `Resources/Data/char_readings.json` (see build_readings.py),
    which drops archaic readings; falls back to every pypinyin reading.
    """
    if ch in _OVERRIDES:
        return tuple(_OVERRIDES[ch])
    if _TABLE is not None:
        return tuple(_TABLE.get(ch, ()))
    raw = pinyin_dict.get(ord(ch))
    if raw is None:
        return ()
    seen: list[str] = []
    for reading in raw.split(","):
        s = toneless(reading)
        if s in SYLLABLES and s not in seen:
            seen.append(s)
    return tuple(seen)


def spellings(syllable: str) -> tuple[str, ...]:
    """Full spellings a person may type for one syllable."""
    return (syllable, *_ALIASES.get(syllable, ()))


def initials(syllable: str) -> tuple[str, ...]:
    """Abbreviated spellings: the first letter, plus zh/ch/sh in full."""
    if syllable[:2] in RETROFLEX:
        return (syllable[0], syllable[:2])
    return (syllable[0],)


# ---------------------------------------------------------------------------
# 走音 · slips of the finger. Mirrors KeyReader.slips / cleanlyReadable.

MAX_SLIPS = 2
_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
_NEAR: set[tuple[str, str]] = set()
for _r, _row in enumerate(_ROWS):
    for _i, _ch in enumerate(_row):
        if _i + 1 < len(_row):
            _NEAR |= {(_ch, _row[_i + 1]), (_row[_i + 1], _ch)}
        if _r + 1 < len(_ROWS):
            _below = _ROWS[_r + 1]
            for _j in (_i, _i - 1):
                if 0 <= _j < len(_below):
                    _NEAR |= {(_ch, _below[_j]), (_below[_j], _ch)}


def near(a: str, b: str) -> bool:
    return (a, b) in _NEAR


def slip_ends(keys: str, q: int, limit: int, sp: str) -> list[int]:
    """Ends of one-slip spellings of `sp` at q (never across `limit`)."""
    L = len(sp)
    out: list[int] = []
    if L < 2:
        return out
    if q + L <= limit:
        diffs = [i for i in range(L) if keys[q + i] != sp[i]]
        if len(diffs) == 1 and near(keys[q + diffs[0]], sp[diffs[0]]):
            out.append(q + L)
        elif (len(diffs) == 2 and diffs[1] == diffs[0] + 1
              and keys[q + diffs[0]] == sp[diffs[1]] and keys[q + diffs[1]] == sp[diffs[0]]):
            out.append(q + L)
    if L >= 3 and q + L - 1 <= limit:
        for skip in range(1, L):
            if keys[q:q + L - 1] == sp[:skip] + sp[skip + 1:]:
                out.append(q + L - 1)
                break
    if q + L + 1 <= limit:
        for extra in range(1, L + 1):
            if keys[q:q + extra] == sp[:extra] and keys[q + extra + 1:q + L + 1] == sp[extra:]:
                x = keys[q + extra]
                before = sp[extra - 1]
                after = sp[extra] if extra < L else ""
                if x in (before, after) or near(x, before) or (after and near(x, after)):
                    out.append(q + L + 1)
                    break
    return out


def cleanly_readable(keys: str) -> bool:
    """Do the keys read as complete full syllables end to end?"""
    n = len(keys)
    reach = [False] * (n + 1)
    reach[0] = True
    for q in range(n):
        if not reach[q]:
            continue
        if keys[q] == "'":
            reach[q + 1] = True
            continue
        for s in SYLLABLES:
            for sp in spellings(s):
                if keys.startswith(sp, q):
                    reach[q + len(sp)] = True
    return reach[n]


def match_char_kinds(keys: str, pos: int, readings: tuple[str, ...], slips: bool) -> list[tuple[int, int]]:
    """(end, kind) for one character: kind 0 full, 1 initial/prefix, 2 slip.

    The same rules as match_char, plus 走音 when `slips` is on.
    """
    n = len(keys)
    if pos < n and keys[pos] == "'":
        pos += 1
    if pos >= n:
        return []
    best: dict[int, int] = {}

    def add(end: int, kind: int) -> None:
        if end <= n and (end not in best or kind < best[end]):
            best[end] = kind

    spelled = False
    for syllable in readings:
        for sp in spellings(syllable):
            if keys.startswith(sp, pos):
                add(pos + len(sp), 0)
                spelled = True
    if not spelled:
        for syllable in readings:
            for initial in initials(syllable):
                if keys.startswith(initial, pos):
                    add(pos + len(initial), 1)
    rest = keys[pos:]
    if "'" not in rest:
        for syllable in readings:
            for sp in spellings(syllable):
                if len(rest) < len(sp) and sp.startswith(rest):
                    add(n, 1)
    if slips:
        limit = keys.find("'", pos)
        limit = n if limit < 0 else limit
        for syllable in readings:
            for end in slip_ends(keys, pos, limit, syllable):
                add(end, 2)
    return sorted(best.items())


def match_char(keys: str, pos: int, readings: tuple[str, ...]) -> list[int]:
    """End positions after reading one character (any of its readings).

    The initial-only form is admitted only when *no* reading of the character
    is spelled out in full here: 大 is da/dai/tai, and `dan` must not read as
    大(d) + 安 just because `dai` is not spelled out.
    """
    n = len(keys)
    if pos < n and keys[pos] == "'":
        pos += 1
    if pos >= n:
        return []
    ends: set[int] = set()
    for syllable in readings:
        for spelling in spellings(syllable):
            if keys.startswith(spelling, pos):
                ends.add(pos + len(spelling))
    if not ends:
        for syllable in readings:
            for initial in initials(syllable):
                if keys.startswith(initial, pos):
                    ends.add(pos + len(initial))
    # The syllable still being typed: keys run out inside it.
    rest = keys[pos:]
    if "'" not in rest:
        for syllable in readings:
            for spelling in spellings(syllable):
                if len(rest) < len(spelling) and spelling.startswith(rest):
                    ends.add(n)
    return sorted(ends)


def match_text(keys: str, pos: int, text: str, cap: int = 16) -> list[int]:
    """End positions after reading Han `text` (any reading of each char)."""
    frontier = {pos}
    for ch in text:
        readings = char_readings(ch)
        if not readings:
            return []
        nxt: set[int] = set()
        for p in frontier:
            nxt.update(match_char(keys, p, readings))
        if not nxt:
            return []
        frontier = set(sorted(nxt)[:cap])
    return sorted(frontier)


def match_latin(keys: str, pos: int, text: str) -> list[int]:
    """Latin output must be typed letter for letter (case and spaces free)."""
    letters = "".join(c for c in text.lower() if c != " ")
    if not letters or not letters.isascii() or not letters.isalpha():
        return []
    if pos < len(keys) and keys[pos] == "'":
        pos += 1
    return [pos + len(letters)] if keys.startswith(letters, pos) else []


# ---------------------------------------------------------------------------
# Typing simulator


def _form_for_word(rng: random.Random, syllables: list[str], heavy: float) -> list[str]:
    """Per-syllable typed pieces for one word."""
    if len(syllables) == 1:
        # Single characters are almost always spelled out; a bare initial for
        # a lone character is hopeless and rare in real typing.
        if rng.random() < 0.03 * heavy:
            return [rng.choice(initials(syllables[0]))]
        return [syllables[0]]
    roll = rng.random()
    full_p = max(0.2, 0.78 - 0.45 * heavy)
    mixed_p = 0.12 + 0.12 * heavy
    initials_p = 0.07 + 0.25 * heavy
    out: list[str] = []
    if roll < full_p:
        mode = "full"
    elif roll < full_p + mixed_p:
        mode = "mixed"
    elif roll < full_p + mixed_p + initials_p:
        mode = "initials"
    else:
        mode = "random"
    for i, s in enumerate(syllables):
        if mode == "full" or (mode == "mixed" and i == 0):
            out.append(rng.choice(spellings(s)) if rng.random() < 0.3 else s)
        elif mode == "random" and rng.random() < 0.5:
            out.append(s)
        else:
            choices = initials(s)
            out.append(choices[-1] if len(choices) > 1 and rng.random() < 0.25 else choices[0])
    return out


def simulate_keys(
    rng: random.Random,
    words: list[tuple[str, list[str]]],
    *,
    heavy: float = 0.0,
    truncate_last: bool = False,
    apostrophes: float = 0.02,
) -> str | None:
    """Keys a person might type for `words` [(text, syllables)], or None.

    Han words become per-syllable pieces drawn from the typing model; Latin
    words are typed letter for letter. Every result is checked against the
    matcher, word by word, so the decoder can always read it back.
    """
    pieces: list[str] = []
    for text, syllables in words:
        if not syllables:
            pieces.append("".join(c for c in text.lower() if c != " "))
            continue
        form = _form_for_word(rng, syllables, heavy)
        for piece in form:
            if pieces and rng.random() < apostrophes and piece[0] in "aoe":
                pieces.append("'")
            pieces.append(piece)
    if truncate_last and words and words[-1][1]:
        last = pieces[-1]
        if len(last) > 1:
            pieces[-1] = last[: rng.randint(1, len(last) - 1)]
    keys = "".join(pieces)
    if not readable(keys, words):
        return None
    return keys


def simulate_with_slips(rng: random.Random, words, *, p_slip: float = 0.07, **kwargs) -> str | None:
    """simulate_keys, then sometimes a slip or two the decoder can still read."""
    keys = simulate_keys(rng, words, **kwargs)
    if keys is None or rng.random() >= p_slip:
        return keys
    for _ in range(4):
        slipped = inject_slip(rng, keys)
        if rng.random() < 0.2:
            slipped = inject_slip(rng, slipped)
        if slipped != keys and readable(slipped, words):
            return slipped
    return keys


def readable(keys: str, words: list[tuple[str, list[str]]]) -> bool:
    """Can the matcher read `keys` as exactly `words`, end to end?

    With slips allowed exactly when the decoder allows them (keys that are
    not a clean run of complete syllables), at most MAX_SLIPS of them.
    """
    slips = not cleanly_readable(keys)
    frontier = {(0, 0)}  # (position, slips used)
    for text, syllables in words:
        nxt: set[tuple[int, int]] = set()
        for p, used in frontier:
            if syllables:
                states = {(p, used)}
                for ch in text:
                    step: set[tuple[int, int]] = set()
                    for q, u in states:
                        for end, kind in match_char_kinds(keys, q, char_readings(ch), slips):
                            uu = u + (kind == 2)
                            if uu <= MAX_SLIPS:
                                step.add((end, uu))
                    states = set(sorted(step)[:32])
                    if not states:
                        break
                nxt |= states
            else:
                nxt |= {(e, used) for e in match_latin(keys, p, text)}
        if not nxt:
            return False
        frontier = nxt
    return any(p == len(keys) for p, _ in frontier)


def inject_slip(rng: random.Random, keys: str) -> str:
    """One slip of the finger somewhere in `keys` (never the first key)."""
    letters = [i for i, c in enumerate(keys) if c.isalpha()]
    if len(letters) < 3:
        return keys
    i = rng.choice(letters[1:])
    c = keys[i]
    roll = rng.random()
    if roll < 0.5:
        options = [b for (a, b) in _NEAR if a == c]
        return keys[:i] + rng.choice(options) + keys[i + 1:] if options else keys
    if roll < 0.7 and i + 1 < len(keys) and keys[i + 1].isalpha() and keys[i + 1] != c:
        return keys[:i] + keys[i + 1] + c + keys[i + 2:]
    if roll < 0.85:
        return keys[:i] + keys[i + 1:]
    extra = rng.choice([c] + [b for (a, b) in _NEAR if a == c])
    return keys[:i + 1] + extra + keys[i + 1:]


if __name__ == "__main__":
    rng = random.Random(1)
    print(len(SYLLABLES), "syllables")
    print(char_readings("行"), char_readings("嗯"), char_readings("绿"))
    print(match_text("jiaoshi", 0, "教室"), match_text("dan", 0, "大安"), match_text("dg", 0, "大哥"))
    print(match_text("jldx", 0, "吉林大学"), match_text("jilindaxu", 0, "吉林大学"))
    print(match_latin("yongvscode", 4, "VS Code"))
    for k in ("niihao", "nihoa", "zhogguo", "nihap", "nihai"):
        print(k, cleanly_readable(k), readable(k, [("你好", ["ni", "hao"])]), readable(k, [("中国", ["zhong", "guo"])]))

    w = [("吉林", ["ji", "lin"]), ("大学", ["da", "xue"]), ("没有", ["mei", "you"]), ("空调", ["kong", "tiao"])]
    for _ in range(5):
        print(simulate_keys(rng, w, heavy=0.6, truncate_last=True))
    for _ in range(6):
        print("slip:", simulate_with_slips(rng, w, p_slip=1.0))
