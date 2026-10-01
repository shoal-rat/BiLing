"""Reference constrained beam search for 子期 (Python/MLX).

This is the executable specification of the decoder that ships in
`Sources/ZhiyinListener`: the Swift/C version must return the same texts in
the same order for the same model. The search is token-synchronous, so every
live hypothesis has the same length and the KV cache can be re-indexed along
the batch axis when beams fork.

Which tokens may follow is decided by `TokenTrie.allowed`: a character trie
over the vocabulary's Han tokens, walked against the keys with the three
rules in `pinyin.py`. Latin tokens must spell the keys letter for letter.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from pathlib import Path

from pinyin import char_readings, match_char

HAN = re.compile(r"^[㐀-䶿一-鿿]+$")
LATIN = re.compile(r"^ ?[A-Za-z]+$")


class TokenTrie:
    """Character trie over every token the decoder may emit."""

    def __init__(self, decode, vocab_size: int):
        self.root: dict = {}
        self.latin: dict[str, list[int]] = {}
        self.text: dict[int, str] = {}
        for tid in range(vocab_size):
            s = decode(tid)
            if HAN.match(s):
                if not all(char_readings(c) for c in s):
                    continue
                node = self.root
                for c in s:
                    node = node.setdefault(c, {})
                node.setdefault(None, []).append(tid)
                self.text[tid] = s
            elif LATIN.match(s) and len(s.strip()) >= 2:
                letters = s.strip().lower()
                self.latin.setdefault(letters, []).append(tid)
                self.text[tid] = s
        self.max_latin = max(len(k) for k in self.latin)

    def allowed(self, keys: str, pos: int) -> list[tuple[int, int]]:
        """(token id, end position) pairs readable at keys[pos:]."""
        out: list[tuple[int, int]] = []

        def walk(node: dict, p: int):
            for ch, child in node.items():
                if ch is None:
                    continue
                for end in match_char(keys, p, char_readings(ch)):
                    for tid in child.get(None, ()):
                        out.append((tid, end))
                    if end < len(keys):
                        walk(child, end)

        walk(self.root, pos)
        start = pos + 1 if pos < len(keys) and keys[pos] == "'" else pos
        for length in range(2, min(self.max_latin, len(keys) - start) + 1):
            for tid in self.latin.get(keys[start:start + length], ()):
                out.append((tid, start + length))
        return out


@dataclass
class Hyp:
    tokens: list[int]
    pos: int
    logp: float
    chars: int = 0
    row: int = 0  # row in the batch / cache that holds this hypothesis's state


@dataclass
class Result:
    text: str
    logp: float
    tokens: list[int] = field(default_factory=list)


class Listener:
    def __init__(self, model_path: Path, adapter_path: Path | None = None):
        import mlx.core as mx
        from mlx_lm import load

        from fmt import Format

        self.mx = mx
        kwargs = {"adapter_path": str(adapter_path)} if adapter_path else {}
        self.model, _ = load(str(model_path), **kwargs)
        self.fmt = Format(Path(model_path) / "tokenizer.json")
        self.trie = TokenTrie(lambda i: self.fmt.tok.decode([i]), 151643)

    def _logprobs(self, logits):
        mx = self.mx
        logits = logits.astype(mx.float32)
        return logits - mx.logsumexp(logits, axis=-1, keepdims=True)

    def search(self, context: str, keys: str, beam: int = 8, reward: float = 1.0, top: int = 8, show_keys: bool = True):
        from mlx_lm.models.cache import make_prompt_cache

        mx = self.mx
        if show_keys:
            prompt = self.fmt.prompt(context, keys)
        else:
            # Pure language model: the keys only constrain, the model never sees them.
            from fmt import EOS
            prompt = [EOS] + self.fmt.encode(context[-48:])
        cache = make_prompt_cache(self.model)
        logits = self.model(mx.array([prompt]), cache=cache)[:, -1, :]
        logp = self._logprobs(logits)
        mx.eval(logp)
        lp = logp
        live = [Hyp([], 0, 0.0, 0, 0)]
        finished: dict[str, Result] = {}
        allowed_cache: dict[int, list[tuple[int, int]]] = {}
        n = len(keys)
        max_steps = n + 2
        for _ in range(max_steps):
            if not live:
                break
            expansions = []
            for h in live:
                options = allowed_cache.get(h.pos)
                if options is None:
                    options = self.trie.allowed(keys, h.pos)
                    allowed_cache[h.pos] = options
                if not options:
                    continue
                ids = mx.array([t for t, _ in options])
                scores = lp[h.row][ids].tolist()
                for (tid, end), s in zip(options, scores):
                    text = self.trie.text[tid]
                    chars = h.chars + (len(text) if HAN.match(text) else max(1, len(text.strip()) // 3))
                    expansions.append((h.logp + s, chars, end, tid, h))
            if not expansions:
                break
            # Rank partial hypotheses by score plus a per-syllable reward, so a
            # hypothesis that has read more of the keys is not penalised for
            # having paid for it already.
            expansions.sort(key=lambda e: e[0] + reward * e[1], reverse=True)
            best_final = max((r.logp for r in finished.values()), default=-math.inf)
            nxt: list[Hyp] = []
            for score, chars, end, tid, parent in expansions:
                if end == n:
                    tokens = parent.tokens + [tid]
                    text = "".join(self.trie.text[t] for t in tokens)
                    prev = finished.get(text)
                    if prev is None or prev.logp < score:
                        finished[text] = Result(text, score, tokens)
                    continue
                if len(nxt) < beam and score > best_final - 12.0:
                    nxt.append(Hyp(parent.tokens + [tid], end, score, chars, parent.row))
                if len(nxt) >= beam and len(finished) >= top:
                    break
            if not nxt:
                break
            # Stop when nothing live can still beat the best finished result.
            if finished:
                best_final = max(r.logp for r in finished.values())
                if all(h.logp < best_final - 6.0 for h in nxt) and len(finished) >= 3:
                    break
            parent_rows = mx.array([h.row for h in nxt])
            for c in cache:
                c.keys = c.keys[parent_rows]
                c.values = c.values[parent_rows]
            for i, h in enumerate(nxt):
                h.row = i
            step_tokens = mx.array([[h.tokens[-1]] for h in nxt])
            logits = self.model(step_tokens, cache=cache)[:, -1, :]
            lp = self._logprobs(logits)
            mx.eval(lp)
            live = nxt
        results = sorted(finished.values(), key=lambda r: r.logp, reverse=True)
        return results[:top]


if __name__ == "__main__":
    import sys
    import time

    root = Path(__file__).resolve().parents[3]
    adapter = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    L = Listener(root / "work/models/Qwen3-0.6B-Base", adapter)
    for ctx, keys in [("", "jilindaxuelajixuexiao"), ("走进", "jiaoshi"), ("我们的", "jiaoshi"),
                      ("", "jldx"), ("", "nihao"), ("爷爷最喜欢下", "xiangqi")]:
        t = time.time()
        res = L.search(ctx, keys)
        print(f"{ctx}|{keys} -> {[ (r.text, round(r.logp,2)) for r in res[:5]]}  {1000*(time.time()-t):.0f}ms")
