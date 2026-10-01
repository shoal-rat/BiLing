#!/usr/bin/env python3
"""Paired comparison of two input methods on the same duel items.

    python Tools/duel/compare.py zhiyin.tsv apple.tsv [--names 知音 Apple] [--markdown]

Both files are per-item TSVs with columns category, context, pinyin,
expected, <answer>, correct (tiaoyin eval --per-item and duel.swift both
write this layout). Items are paired on (context, pinyin, expected); only
items present in both count. For every slice — source, span, typing style,
cold vs with-context — it prints both accuracies, the paired difference and
a 95% bootstrap interval (10 000 resamples, fixed seed), and wins/losses.
"""

from __future__ import annotations

import argparse
import random
from collections import defaultdict
from pathlib import Path


def load(path: Path) -> dict[tuple[str, str, str], tuple[str, int]]:
    rows = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        f = line.split("\t")
        if len(f) < 6 or f[0] == "category" or line.startswith("#"):
            continue
        ctx = "" if f[1] in ("-", "") else f[1]
        rows[(ctx, f[2], f[3])] = (f[0], int(f[5]))
    return rows


def bootstrap(diffs: list[int], rounds: int = 10000, seed: int = 20261002) -> tuple[float, float]:
    if not diffs:
        return (0.0, 0.0)
    rng = random.Random(seed)
    n = len(diffs)
    means = sorted(sum(diffs[rng.randrange(n)] for _ in range(n)) / n for _ in range(rounds))
    return means[int(0.025 * rounds)], means[int(0.975 * rounds) - 1]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("a", type=Path)
    p.add_argument("b", type=Path)
    p.add_argument("--names", nargs=2, default=["知音", "Apple"])
    p.add_argument("--markdown", action="store_true")
    args = p.parse_args()
    A, B = load(args.a), load(args.b)
    keys = [k for k in A if k in B]
    slices: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for k in keys:
        category, a = A[k]
        b = B[k][1]
        parts = category.split("/")
        names = ["all", "ctx" if k[0] else "cold"]
        if len(parts) == 3:
            names += [f"source:{parts[0]}", f"span:{parts[1]}", f"form:{parts[2]}",
                      f"{parts[0]}·{'ctx' if k[0] else 'cold'}"]
        else:
            names.append(category)
        for n in names:
            slices[n].append((a, b))
    order = ["all", "cold", "ctx"] + sorted(s for s in slices if s not in ("all", "cold", "ctx"))
    na, nb = args.names
    if args.markdown:
        print(f"| 切片 | n | {na} | {nb} | 差 | 95% CI | 胜/负/平 |")
        print("|---|---|---|---|---|---|---|")
    for s in order:
        pairs = slices[s]
        n = len(pairs)
        if n == 0:
            continue
        ra = sum(a for a, _ in pairs) / n
        rb = sum(b for _, b in pairs) / n
        diffs = [a - b for a, b in pairs]
        lo, hi = bootstrap(diffs)
        w = sum(1 for d in diffs if d > 0)
        l = sum(1 for d in diffs if d < 0)
        t = n - w - l
        if args.markdown:
            print(f"| {s} | {n} | {100*ra:.1f}% | {100*rb:.1f}% | {100*(ra-rb):+.1f} | [{100*lo:+.1f}, {100*hi:+.1f}] | {w}/{l}/{t} |")
        else:
            print(f"{s:24s} n={n:5d}  {na} {100*ra:5.1f}%  {nb} {100*rb:5.1f}%  diff {100*(ra-rb):+5.1f}"
                  f"  CI [{100*lo:+5.1f}, {100*hi:+5.1f}]  w/l/t {w}/{l}/{t}")
    print(f"\npaired items: {len(keys)} (of {len(A)} / {len(B)})")


if __name__ == "__main__":
    main()
