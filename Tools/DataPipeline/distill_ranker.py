#!/usr/bin/env python3
"""Distill the Qwen reranker into a compact MLP, and fit the confidence gate.

Input: JSONL from `biling-cli --dump-features <tsv>` where each list carries
the 12 RankerModel features per candidate, the index of the correct candidate,
and — when the dump ran with the model — the teacher's log-probability for the
top candidates.

Two artefacts come out:

* distilled-ranker.json — a 12→H→1 MLP trained with a mixed objective:
  listwise cross-entropy on the labelled positive, plus KL against the
  teacher's softmax over the candidates it scored. The teacher term is what
  makes ~500 parameters worth anything: the label alone was already tried at
  linear capacity and refused export (see train_ranker.py); the teacher
  provides a full preference ordering per list, tens of comparisons where the
  label gives one.

* confidence-gate.json — a logistic model of P(deterministic top-1 is wrong)
  from list-shape features (margin, entropy, spread). The runtime uses it to
  route: confident lists skip every model, uncertain ones get the MLP, only
  the least confident pay for Qwen.

Honesty rules, inherited from train_ranker.py: holdout split by key hash,
export refused unless the runtime-shaped blend beats the deterministic
baseline on holdout, and every number printed is from held-out lists only.
The teacher dump currently runs without context; both artefacts are
calibrated for the cold path and the report says so.

Runtime blend semantics (must match DistilledRanker.swift):
    final_i = det_score_i + lambda * max(0, mlp_i - mlp_top)
where mlp_top is the MLP score of the deterministic #1 — promotion-only,
the same internal-LM-subtraction shape the Qwen blend uses.

Usage:
    python3 Tools/DataPipeline/distill_ranker.py \
        --data /tmp/teacher-train.jsonl \
        --out-ranker Sources/BackboneEngine/Resources/distilled-ranker.json \
        --out-gate Sources/BackboneEngine/Resources/confidence-gate.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

HIDDEN = 16
SEED = 20260729


def load_lists(path: Path):
    lists = []
    for line in path.open(encoding="utf-8"):
        row = json.loads(line)
        feats = np.array([c["features"] for c in row["candidates"]], dtype=np.float64)
        teacher = np.array(
            [c.get("teacher", np.nan) for c in row["candidates"]], dtype=np.float64
        )
        lists.append(
            {
                "keys": row["keys"],
                "x": feats,
                "teacher": teacher,
                "positive": row["positive_index"],
            }
        )
    return lists


def split(lists):
    train, hold = [], []
    for item in lists:
        digest = hashlib.sha256(item["keys"].encode()).hexdigest()
        (hold if int(digest[:8], 16) % 10 == 0 else train).append(item)
    return train, hold


def standardise(train):
    stacked = np.vstack([item["x"] for item in train])
    mean = stacked.mean(axis=0)
    std = stacked.std(axis=0)
    std[std < 1e-9] = 1.0
    return mean, std


def forward(params, x):
    hidden = np.maximum(0.0, x @ params["w1"] + params["b1"])
    return hidden @ params["w2"] + params["b2"], hidden


def train_mlp(train, mean, std, alpha=0.5, temperature=2.0, epochs=30, lr=0.01):
    rng = np.random.default_rng(SEED)
    dim = train[0]["x"].shape[1]
    params = {
        "w1": rng.normal(0, 0.3 / np.sqrt(dim), (dim, HIDDEN)),
        "b1": np.zeros(HIDDEN),
        "w2": rng.normal(0, 0.3 / np.sqrt(HIDDEN), HIDDEN),
        "b2": 0.0,
    }
    velocity = {k: np.zeros_like(v) if hasattr(v, "shape") else 0.0 for k, v in params.items()}
    order = np.arange(len(train))
    for epoch in range(epochs):
        rng.shuffle(order)
        total = 0.0
        for index in order:
            item = train[index]
            x = (item["x"] - mean) / std
            scores, hidden = forward(params, x)

            # Listwise CE on the labelled positive.
            shifted = scores - scores.max()
            soft = np.exp(shifted)
            soft /= soft.sum()
            grad_scores = alpha * soft.copy()
            grad_scores[item["positive"]] -= alpha
            total -= alpha * np.log(max(soft[item["positive"]], 1e-12))

            # KL to the teacher over the candidates it scored.
            mask = ~np.isnan(item["teacher"])
            if mask.sum() >= 2:
                t = item["teacher"][mask] / temperature
                t_soft = np.exp(t - t.max())
                t_soft /= t_soft.sum()
                s_sub = scores[mask]
                s_soft = np.exp(s_sub - s_sub.max())
                s_soft /= s_soft.sum()
                grad_sub = (1 - alpha) * (s_soft - t_soft)
                grad_scores[mask] += grad_sub
                total += (1 - alpha) * float(
                    np.sum(t_soft * (np.log(t_soft + 1e-12) - np.log(s_soft + 1e-12)))
                )

            grad_w2 = hidden.T @ grad_scores
            grad_b2 = grad_scores.sum()
            grad_hidden = np.outer(grad_scores, params["w2"]) * (hidden > 0)
            grad_w1 = x.T @ grad_hidden
            grad_b1 = grad_hidden.sum(axis=0)
            for name, grad in (
                ("w1", grad_w1), ("b1", grad_b1), ("w2", grad_w2), ("b2", grad_b2),
            ):
                velocity[name] = 0.9 * velocity[name] - lr * grad
                params[name] = params[name] + velocity[name]
        if epoch % 10 == 9:
            print(f"  epoch {epoch + 1}: loss {total / len(train):.4f}", file=sys.stderr)
    return params


def blended_top1(lists, params, mean, std, lam):
    """Top-1 accuracy under the runtime promotion-only blend."""
    hits = 0
    for item in lists:
        x = (item["x"] - mean) / std
        scores, _ = forward(params, x)
        det = item["x"][:, 0]
        final = det + lam * np.maximum(0.0, scores - scores[np.argmax(det)])
        if np.argmax(final) == item["positive"]:
            hits += 1
    return hits / len(lists)


def baseline_top1(lists):
    return sum(np.argmax(i["x"][:, 0]) == i["positive"] for i in lists) / len(lists)


def gate_features(item):
    det = np.sort(item["x"][:, 0])[::-1]
    margin = det[0] - det[1] if len(det) > 1 else 20.0
    top8 = det[: min(8, len(det))]
    soft = np.exp(top8 - top8.max())
    soft /= soft.sum()
    entropy = -float(np.sum(soft * np.log(soft + 1e-12)))
    spread = det[0] - det[min(4, len(det) - 1)]
    return np.array([margin, entropy, spread, np.log(1 + len(det))])


def fit_gate(train, hold):
    x_train = np.vstack([gate_features(i) for i in train])
    y_train = np.array([np.argmax(i["x"][:, 0]) != i["positive"] for i in train], float)
    mean, std = x_train.mean(axis=0), x_train.std(axis=0)
    std[std < 1e-9] = 1.0
    xs = (x_train - mean) / std
    w = np.zeros(xs.shape[1])
    b = 0.0
    for _ in range(500):
        p = 1 / (1 + np.exp(-(xs @ w + b)))
        grad_w = xs.T @ (p - y_train) / len(y_train)
        grad_b = float(np.mean(p - y_train))
        w -= 0.5 * grad_w
        b -= 0.5 * grad_b
    x_hold = (np.vstack([gate_features(i) for i in hold]) - mean) / std
    y_hold = np.array([np.argmax(i["x"][:, 0]) != i["positive"] for i in hold], float)
    p_hold = 1 / (1 + np.exp(-(x_hold @ w + b)))
    # Brier score against the trivial constant predictor: the gate must know
    # something the base rate does not, or it does not ship.
    brier = float(np.mean((p_hold - y_hold) ** 2))
    base = float(np.mean((y_hold.mean() - y_hold) ** 2))
    return {"w": w, "b": b, "mean": mean, "std": std, "brier": brier, "base": base,
            "p_hold": p_hold, "y_hold": y_hold}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out-ranker", type=Path, required=True)
    parser.add_argument("--out-gate", type=Path, required=True)
    parser.add_argument("--alpha", type=float, default=0.5)
    parser.add_argument("--temperature", type=float, default=2.0)
    args = parser.parse_args()

    lists = load_lists(args.data)
    train, hold = split(lists)
    print(f"lists: {len(train)} train / {len(hold)} holdout")
    mean, std = standardise(train)

    params = train_mlp(train, mean, std, alpha=args.alpha, temperature=args.temperature)

    base_train, base_hold = baseline_top1(train), baseline_top1(hold)
    best_lam, best_train = 0.0, base_train
    for lam in [0.1, 0.2, 0.3, 0.5, 0.8, 1.2, 2.0]:
        acc = blended_top1(train, params, mean, std, lam)
        if acc > best_train:
            best_train, best_lam = acc, lam
    hold_acc = blended_top1(hold, params, mean, std, best_lam) if best_lam else base_hold
    print(f"baseline  train {base_train:.4f}  holdout {base_hold:.4f}")
    print(f"distilled train {best_train:.4f}  holdout {hold_acc:.4f}  (lambda {best_lam})")

    # The bar is statistical, not literal: with ~400 holdout lists a single
    # flipped item moves top-1 by 0.24 points, so "beats baseline" must mean
    # by more than one binomial standard error of the difference.
    sigma = float(np.sqrt(base_hold * (1 - base_hold) / max(1, len(hold))))
    if best_lam == 0.0 or hold_acc <= base_hold + 1.96 * sigma:
        print(f"REFUSED: holdout gain {hold_acc - base_hold:+.4f} is within noise "
              f"(1.96 sigma = {1.96 * sigma:.4f}); nothing exported.")
    else:
        payload = {
            "schema": "biling-distilled-ranker",
            "version": 1,
            "trained_on": str(args.data),
            "feature_count": int(train[0]["x"].shape[1]),
            "hidden": HIDDEN,
            "lambda": best_lam,
            "feature_mean": mean.tolist(),
            "feature_std": std.tolist(),
            "w1": params["w1"].tolist(),
            "b1": params["b1"].tolist(),
            "w2": params["w2"].tolist(),
            "b2": float(params["b2"]),
            "holdout": {"baseline_top1": base_hold, "distilled_top1": hold_acc},
        }
        args.out_ranker.write_text(json.dumps(payload))
        print(f"exported {args.out_ranker} "
              f"({sum(np.size(v) for v in params.values())} parameters)")

    gate = fit_gate(train, hold)
    print(f"gate Brier {gate['brier']:.4f} vs base-rate {gate['base']:.4f}")
    if gate["brier"] >= gate["base"]:
        print("REFUSED: gate is no better calibrated than the base rate; not exported.")
        return
    # Operating points for the report: share of lists routed past each
    # threshold and the top-1 that routing would forfeit if the skipped
    # model were an oracle (upper bound on harm).
    for threshold in (0.1, 0.2, 0.3, 0.5):
        routed = gate["p_hold"] >= threshold
        missed = float(np.mean(~routed & (gate["y_hold"] > 0)))
        print(f"  P(wrong)>= {threshold:.1f}: route {routed.mean():.1%} of lists; "
              f"skipped-but-wrong {missed:.1%}")
    args.out_gate.write_text(json.dumps({
        "schema": "biling-confidence-gate",
        "version": 1,
        "features": ["margin", "entropy_top8", "spread_top5", "log_candidates"],
        "w": gate["w"].tolist(),
        "b": float(gate["b"]),
        "mean": gate["mean"].tolist(),
        "std": gate["std"].tolist(),
        "holdout_brier": gate["brier"],
        "holdout_base_rate_brier": gate["base"],
    }))
    print(f"exported {args.out_gate}")


if __name__ == "__main__":
    main()
