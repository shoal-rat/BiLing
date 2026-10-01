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

from pinyin import char_readings, match_char, spellings

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
            elif LATIN.match(s) and (len(s.strip()) >= 2 or s.strip().isupper()):
                letters = s.strip().lower()
                self.latin.setdefault(letters, []).append(tid)
                self.text[tid] = s
        self.max_latin = max(len(k) for k in self.latin)

    def allowed(self, keys: str, pos: int, with_abbr: bool = False):
        """(token id, end position[, abbreviated chars]) readable at keys[pos:]."""
        out = []

        def walk(node: dict, p: int, abbr: int):
            for ch, child in node.items():
                if ch is None:
                    continue
                readings = char_readings(ch)
                for end in match_char(keys, p, readings):
                    q = p + 1 if p < len(keys) and keys[p] == "'" else p
                    full = any(keys.startswith(sp, q) and q + len(sp) == end
                               for r in readings for sp in spellings(r))
                    a = abbr + (0 if full else 1)
                    for tid in child.get(None, ()):
                        out.append((tid, end, a) if with_abbr else (tid, end))
                    if end < len(keys):
                        walk(child, end, a)

        walk(self.root, pos, 0)
        start = pos + 1 if pos < len(keys) and keys[pos] == "'" else pos
        for length in range(1, min(self.max_latin, len(keys) - start) + 1):
            for tid in self.latin.get(keys[start:start + length], ()):
                out.append((tid, start + length, 0) if with_abbr else (tid, start + length))
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


    def search_lm(self, context: str, keys: str, beam: int = 12, per_key: float = 1.2,
                  abbr_cost: float = 2.5, latin_cost: float = 4.0, top: int = 8):
        """Base LM + typing channel: the model never sees the keys.

        score = log P_LM(text | context) - abbr_cost * (chars read by initial
        or prefix) - latin_cost * (Latin tokens). Partial hypotheses are
        ranked by score + per_key * (keys consumed), so hypotheses that have
        read more of the keys are comparable to those that have read less.
        """
        from mlx_lm.models.cache import make_prompt_cache

        from fmt import EOS

        mx = self.mx
        prompt = [EOS] + self.fmt.encode(context[-48:])
        cache = make_prompt_cache(self.model)
        lp = self._logprobs(self.model(mx.array([prompt]), cache=cache)[:, -1, :])
        mx.eval(lp)
        n = len(keys)
        live = [Hyp([], 0, 0.0, 0, 0)]
        finished: dict[str, Result] = {}
        options: dict[int, list] = {}
        for _ in range(n + 2):
            exp = []
            for h in live:
                opts = options.get(h.pos)
                if opts is None:
                    opts = options[h.pos] = self.trie.allowed(keys, h.pos, with_abbr=True)
                if not opts:
                    continue
                ids = mx.array([t for t, _, _ in opts])
                vals = lp[h.row][ids].tolist()
                for (tid, end, abbr), v in zip(opts, vals):
                    text = self.trie.text[tid]
                    cost = abbr_cost * abbr + (latin_cost if not HAN.match(text) else 0.0)
                    score = h.logp + v - cost
                    exp.append((score + per_key * end, score, end, tid, h))
            if not exp:
                break
            exp.sort(key=lambda e: e[0], reverse=True)
            nxt = []
            for rank, score, end, tid, parent in exp:
                if end == n:
                    toks = parent.tokens + [tid]
                    text = "".join(self.trie.text[t] for t in toks)
                    if text not in finished or finished[text].logp < score:
                        finished[text] = Result(text, score, toks)
                    continue
                if len(nxt) < beam:
                    nxt.append(Hyp(parent.tokens + [tid], end, score, 0, parent.row))
            if not nxt:
                break
            best = max((r.logp for r in finished.values()), default=-math.inf)
            if finished and all(h.logp < best - 8 for h in nxt):
                break
            rows = mx.array([h.row for h in nxt])
            for c in cache:
                c.keys = c.keys[rows]
                c.values = c.values[rows]
            for i, h in enumerate(nxt):
                h.row = i
            lp = self._logprobs(self.model(mx.array([[h.tokens[-1]] for h in nxt]), cache=cache)[:, -1, :])
            mx.eval(lp)
            live = nxt
        return sorted(finished.values(), key=lambda r: r.logp, reverse=True)[:top]

    def search_poe(self, base, context: str, keys: str, beam: int = 12, w_ft: float = 1.0,
                   w_base: float = 0.6, per_key: float = 1.0, abbr_cost: float = 1.0,
                   latin_cost: float = 3.0, top: int = 8):
        """Product of experts: this model (sees the keys) × `base` (does not).

        score = w_ft log P_ft(t | ctx, keys, prefix) + w_base log P_base(t | ctx, prefix)
                - channel costs. Both caches are re-indexed together.
        """
        from mlx_lm.models.cache import make_prompt_cache

        from fmt import EOS

        mx = self.mx
        p_ft = self.fmt.prompt(context, keys)
        p_lm = [EOS] + self.fmt.encode(context[-48:])
        c_ft = make_prompt_cache(self.model)
        c_lm = make_prompt_cache(base)
        lf = self._logprobs(self.model(mx.array([p_ft]), cache=c_ft)[:, -1, :])
        lb = self._logprobs(base(mx.array([p_lm]), cache=c_lm)[:, -1, :])
        lp = w_ft * lf + w_base * lb
        mx.eval(lp)
        n = len(keys)
        live = [Hyp([], 0, 0.0, 0, 0)]
        finished: dict[str, Result] = {}
        options: dict[int, list] = {}
        for _ in range(n + 2):
            exp = []
            for h in live:
                opts = options.get(h.pos)
                if opts is None:
                    opts = options[h.pos] = self.trie.allowed(keys, h.pos, with_abbr=True)
                if not opts:
                    continue
                vals = lp[h.row][mx.array([t for t, _, _ in opts])].tolist()
                for (tid, end, abbr), v in zip(opts, vals):
                    text = self.trie.text[tid]
                    score = h.logp + v - abbr_cost * abbr - (latin_cost if not HAN.match(text) else 0.0)
                    exp.append((score + per_key * end, score, end, tid, h))
            if not exp:
                break
            exp.sort(key=lambda e: e[0], reverse=True)
            nxt = []
            for rank, score, end, tid, parent in exp:
                if end == n:
                    toks = parent.tokens + [tid]
                    text = "".join(self.trie.text[t] for t in toks)
                    if text not in finished or finished[text].logp < score:
                        finished[text] = Result(text, score, toks)
                    continue
                if len(nxt) < beam:
                    nxt.append(Hyp(parent.tokens + [tid], end, score, 0, parent.row))
            if not nxt:
                break
            best = max((r.logp for r in finished.values()), default=-math.inf)
            if finished and all(h.logp < best - 8 for h in nxt):
                break
            rows = mx.array([h.row for h in nxt])
            for c in list(c_ft) + list(c_lm):
                c.keys = c.keys[rows]
                c.values = c.values[rows]
            for i, h in enumerate(nxt):
                h.row = i
            step = mx.array([[h.tokens[-1]] for h in nxt])
            lf = self._logprobs(self.model(step, cache=c_ft)[:, -1, :])
            lb = self._logprobs(base(step, cache=c_lm)[:, -1, :])
            lp = w_ft * lf + w_base * lb
            mx.eval(lp)
            live = nxt
        return sorted(finished.values(), key=lambda r: r.logp, reverse=True)[:top]


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
