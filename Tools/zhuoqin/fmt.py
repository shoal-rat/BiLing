"""The prompt layout 子期 (the listener model) is trained on.

    [context tokens] <|fim_prefix|> k e y s … <|fim_middle|> [target] <|endoftext|>

Context is ordinary BPE text — whatever already sits before the caret. Each
key is its own single-letter token, so a keystroke appends exactly one token
and every earlier key keeps its KV cache. Target is the BPE tokenization of
the intended text. The Swift runtime builds byte-identical prompts
(`Sources/ZhiyinListener/Prompt.swift`); change one, change both.
"""

from __future__ import annotations

from pathlib import Path

from tokenizers import Tokenizer

KEYS = 151659  # <|fim_prefix|>
OUT = 151660  # <|fim_middle|>
EOS = 151643  # <|endoftext|>
APOSTROPHE = 6
LETTER_BASE = 64  # 'a'
CONTEXT_CHARS = 48


def key_ids(keys: str) -> list[int]:
    out = []
    for ch in keys:
        if ch == "'":
            out.append(APOSTROPHE)
        elif "a" <= ch <= "z":
            out.append(LETTER_BASE + ord(ch) - ord("a"))
        else:
            raise ValueError(f"untypeable key {ch!r}")
    return out


class Format:
    def __init__(self, tokenizer_path: Path | str):
        self.tok = Tokenizer.from_file(str(tokenizer_path))

    def encode(self, text: str) -> list[int]:
        return self.tok.encode(text, add_special_tokens=False).ids if text else []

    def decode(self, ids: list[int]) -> str:
        return self.tok.decode(ids, skip_special_tokens=False)

    def prompt(self, context: str, keys: str) -> list[int]:
        return self.encode(context[-CONTEXT_CHARS:]) + [KEYS] + key_ids(keys) + [OUT]

    def example(self, context: str, keys: str, target: str) -> tuple[list[int], int]:
        """Token ids and the index where the supervised part begins."""
        p = self.prompt(context, keys)
        return p + self.encode(target) + [EOS], len(p)
