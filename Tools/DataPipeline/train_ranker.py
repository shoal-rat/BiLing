#!/usr/bin/env python3
"""Train the listwise candidate ranker.

Input: JSONL from `biling-cli --dump-features` — real candidate lists the
engine produced, one line per corpus item, with the index of the correct
candidate. Output: versioned weight JSON the engine loads at startup.

Objective: listwise softmax (ListNet with a single relevant item), which is
conditional maximum likelihood of the user's choice given the list:

    L = −Σ_lists log [ exp(θ·f⁺) / Σ_c exp(θ·f_c) ]  +  λ‖θ‖²

Features are standardised for optimisation and the learned weights are folded
back to raw feature space before export (softmax is invariant to per-list
constant shifts, so dropping the centring term is exact, not approximate). The
optimiser starts from the engine's current behaviour — weight 1 on the
generative score, 0 elsewhere — so training can only move away from today's
ranking if the data justifies it.

Usage:
    python3 Tools/DataPipeline/train_ranker.py \
        --train /tmp/ranker-train.jsonl \
        --out Sources/BackboneEngine/Resources/ranker-weights.json
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

SCHEMA_VERSION = 1
FEATURES = [
    "generative_score", "src_system", "src_sentence", "src_abbreviation",
    "src_name", "src_english", "src_literal", "segments_log",
    "candidate_length", "key_length", "contains_latin", "han_length_ratio",
]


def load(path: Path):
    lists = []
    with path.open() as handle:
        for line in handle:
            record = json.loads(line)
            matrix = np.array(
                [c["features"] for c in record["candidates"]], dtype=np.float64
            )
            if matrix.shape[0] < 2 or matrix.shape[1] != len(FEATURES):
                continue
            lists.append((matrix, int(record["positive_index"])))
    return lists


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--train", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--holdout-fraction", type=float, default=0.1)
    parser.add_argument("--iterations", type=int, default=600)
    parser.add_argument("--learning-rate", type=float, default=0.05)
    parser.add_argument("--l2", type=float, default=1e-3)
    parser.add_argument("--seed", type=int, default=20260728)
    args = parser.parse_args()

    lists = load(args.train)
    rng = np.random.default_rng(args.seed)
    rng.shuffle(lists)
    holdout_count = max(1, int(len(lists) * args.holdout_fraction))
    holdout, train = lists[:holdout_count], lists[holdout_count:]
    print(f"lists: {len(train)} train, {len(holdout)} holdout")

    stacked = np.vstack([m for m, _ in train])
    mean = stacked.mean(axis=0)
    std = stacked.std(axis=0)
    std[std < 1e-9] = 1.0

    # A feature that is zero for every POSITIVE example cannot be estimated
    # from this data — the optimiser can only ever learn "push it down",
    # which is bias, not signal. Training on Han news round-trips produced
    # src_english = 0 everywhere among positives while contains_latin picked
    # up −8.3, which buried every Latin candidate (AI, xswl) at runtime.
    # Such features are frozen at zero and listed in the export so the gap
    # in the training distribution is visible, not silent.
    positive_rows = np.vstack([m[p : p + 1] for m, p in train])
    supported = np.abs(positive_rows).sum(axis=0) > 0
    masked = [FEATURES[i] for i in range(len(FEATURES)) if not supported[i]]
    if masked:
        print(f"masked (no positive support): {', '.join(masked)}")

    def top1(theta_raw, data):
        hits = 0
        for matrix, positive in data:
            if int(np.argmax(matrix @ theta_raw)) == positive:
                hits += 1
        return hits / max(1, len(data))

    # Start exactly at the shipped behaviour: raw weight 1 on the generative
    # score. In standardised space that is θ_std = σ ⊙ θ_raw.
    theta = np.zeros(len(FEATURES))
    theta[0] = std[0]
    theta[~supported] = 0.0

    baseline_train = top1(theta / std, train)
    baseline_holdout = top1(theta / std, holdout)
    print(f"baseline top-1  train {baseline_train:.4f}  holdout {baseline_holdout:.4f}")

    best_theta = theta.copy()
    best_holdout = baseline_holdout

    # Full-batch Adam. The problem is convex apart from nothing — plain
    # logistic-style likelihood — so this converges without ceremony.
    m = np.zeros_like(theta)
    v = np.zeros_like(theta)
    beta1, beta2, epsilon = 0.9, 0.999, 1e-8

    standardised = [((matrix - mean) / std, positive) for matrix, positive in train]
    for iteration in range(1, args.iterations + 1):
        gradient = np.zeros_like(theta)
        loss = 0.0
        for matrix, positive in standardised:
            logits = matrix @ theta
            logits -= logits.max()
            probabilities = np.exp(logits)
            probabilities /= probabilities.sum()
            loss -= math.log(max(probabilities[positive], 1e-300))
            gradient += matrix.T @ probabilities - matrix[positive]
        gradient /= len(standardised)
        loss /= len(standardised)
        gradient += 2 * args.l2 * theta
        gradient[~supported] = 0.0

        m = beta1 * m + (1 - beta1) * gradient
        v = beta2 * v + (1 - beta2) * gradient**2
        m_hat = m / (1 - beta1**iteration)
        v_hat = v / (1 - beta2**iteration)
        theta -= args.learning_rate * m_hat / (np.sqrt(v_hat) + epsilon)

        if iteration % 50 == 0 or iteration == args.iterations:
            raw = theta / std
            holdout_accuracy = top1(raw, holdout)
            print(
                f"iter {iteration:4d}  loss {loss:.4f}  "
                f"train top-1 {top1(raw, train):.4f}  holdout {holdout_accuracy:.4f}"
            )
            if holdout_accuracy > best_holdout:
                best_holdout = holdout_accuracy
                best_theta = theta.copy()

    if best_holdout <= baseline_holdout:
        print(
            "training did not beat the baseline on holdout "
            f"({best_holdout:.4f} vs {baseline_holdout:.4f}); refusing to export"
        )
        raise SystemExit(1)

    raw = best_theta / std
    payload = {
        "schema_version": SCHEMA_VERSION,
        "features": FEATURES,
        "theta": [float(x) for x in raw],
        "trained_on": f"{args.train.name}, {len(train)} lists, seed {args.seed}",
        "holdout_top1": round(best_holdout, 4),
        "masked_features": masked,
        "baseline_top1": round(baseline_holdout, 4),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {args.out}  (holdout {baseline_holdout:.4f} → {best_holdout:.4f})")


if __name__ == "__main__":
    main()
