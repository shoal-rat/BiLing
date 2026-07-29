#!/usr/bin/env python3
"""Paired bootstrap CI for the difference between two per-item correctness files.

Implements §6 of docs/apple-comparison-protocol.md: the two systems answered
the identical items, so the statistic is the mean of the per-item differences,
and the bootstrap resamples *item pairs* with replacement — never the two
columns independently, which would throw away the pairing that gives the
design its power.

Input format (both files): TSV where the first three columns identify the item
(category, pinyin, expected) and the LAST column is 0/1 correctness — the
format `scripts/apple_baseline.swift` prints. Lines starting with `#` and a
header row are ignored. The two files must contain exactly the same item set;
anything else is a hard error, because a "paired" analysis of different items
is meaningless.

Usage:
    python3 scripts/paired_bootstrap.py apple.tsv biling.tsv \\
        [--iterations 10000] [--seed 20260729]

Output: both accuracies, win/loss/tie counts, the mean paired difference
(file1 − file2), and its percentile-bootstrap 95% CI.
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path


def read_items(path: Path) -> dict[tuple[str, str, str], int]:
    """Item identity -> 0/1 correctness. Duplicate identities are an error."""
    items: dict[tuple[str, str, str], int] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 4:
            sys.exit(f"{path}:{number}: expected at least 4 tab-separated fields")
        if fields[-1] not in ("0", "1"):
            # Tolerate exactly one header row; anything later is data corruption.
            if number == 1:
                continue
            sys.exit(f"{path}:{number}: last column must be 0 or 1, got {fields[-1]!r}")
        key = (fields[0], fields[1], fields[2])
        if key in items:
            sys.exit(f"{path}:{number}: duplicate item {key}")
        items[key] = int(fields[-1])
    if not items:
        sys.exit(f"{path}: no data rows")
    return items


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("first", type=Path, help="per-item correctness TSV (system A)")
    parser.add_argument("second", type=Path, help="per-item correctness TSV (system B)")
    parser.add_argument("--iterations", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=20260729)
    args = parser.parse_args()

    a_items = read_items(args.first)
    b_items = read_items(args.second)

    if a_items.keys() != b_items.keys():
        only_a = list(a_items.keys() - b_items.keys())[:5]
        only_b = list(b_items.keys() - a_items.keys())[:5]
        sys.exit(
            "Item sets differ — a paired analysis needs identical items.\n"
            f"  only in {args.first}: {len(a_items.keys() - b_items.keys())}"
            f" (e.g. {only_a})\n"
            f"  only in {args.second}: {len(b_items.keys() - a_items.keys())}"
            f" (e.g. {only_b})"
        )

    keys = sorted(a_items)  # deterministic order, so the seed fully fixes the run
    differences = [a_items[k] - b_items[k] for k in keys]
    n = len(keys)

    accuracy_a = sum(a_items[k] for k in keys) / n
    accuracy_b = sum(b_items[k] for k in keys) / n
    wins = sum(1 for d in differences if d > 0)
    losses = sum(1 for d in differences if d < 0)
    ties = n - wins - losses
    observed = sum(differences) / n

    rng = random.Random(args.seed)
    means = []
    for _ in range(args.iterations):
        total = 0
        for _ in range(n):
            total += differences[rng.randrange(n)]
        means.append(total / n)
    means.sort()

    def percentile(p: float) -> float:
        # Nearest-rank on the sorted bootstrap distribution.
        index = min(len(means) - 1, max(0, round(p * (len(means) - 1))))
        return means[index]

    low, high = percentile(0.025), percentile(0.975)

    print(f"n = {n} paired items")
    print(f"{args.first}:  accuracy {accuracy_a:.4f}")
    print(f"{args.second}:  accuracy {accuracy_b:.4f}")
    print(f"wins/losses/ties (first vs second): {wins}/{losses}/{ties}")
    print(
        f"paired mean difference (first - second): {observed:+.4f}"
        f"  [{low:+.4f}, {high:+.4f}] 95% CI"
        f"  (percentile bootstrap, B={args.iterations}, seed={args.seed})"
    )
    if low > 0 or high < 0:
        print("CI excludes zero: the direction is supported at the 95% level.")
    else:
        print("CI includes zero: not distinguishable on this corpus.")


if __name__ == "__main__":
    main()
