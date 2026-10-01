#!/usr/bin/env python3
"""Fine-tune Qwen3-0.6B-Base into 子期, the listener, with MLX LoRA.

The model learns one skill: read the context and the raw keys, write the
intended text. Loss is taken only on the target (and its end marker); the
context and keys are conditioning. Batches are bucketed by length so padding
stays small, and the step is compiled once per bucket shape.

    python train.py --data ../../../work/data --out ../../../work/runs/r1
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
from mlx.utils import tree_flatten
from mlx_lm import load
from mlx_lm.tuner.utils import linear_to_lora_layers

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fmt import EOS, Format  # noqa: E402

LORA_KEYS = [
    "self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj",
    "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj",
]


def load_examples(path: Path, fmt: Format, limit: int | None, rng: random.Random):
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            rows.append(json.loads(line))
    rng.shuffle(rows)
    if limit:
        rows = rows[:limit]
    contexts = fmt.tok.encode_batch([r["c"][-48:] for r in rows], add_special_tokens=False)
    targets = fmt.tok.encode_batch([r["t"] for r in rows], add_special_tokens=False)
    from fmt import KEYS, OUT, key_ids

    out = []
    for r, c, t in zip(rows, contexts, targets):
        prompt = c.ids + [KEYS] + key_ids(r["k"]) + [OUT]
        seq = prompt + t.ids + [EOS]
        if len(seq) <= 160:
            out.append((seq, len(prompt)))
    return out


def batches(examples, token_budget: int, rng: random.Random, shuffle=True):
    """Length-bucketed batches, padded to a multiple of 16."""
    order = list(range(len(examples)))
    if shuffle:
        rng.shuffle(order)
    chunk = 8192
    out = []
    for start in range(0, len(order), chunk):
        part = sorted(order[start:start + chunk], key=lambda i: len(examples[i][0]))
        i = 0
        while i < len(part):
            length = len(examples[part[i]][0])
            padded = (length + 15) // 16 * 16
            size = max(1, token_budget // padded)
            group = part[i:i + size]
            longest = max(len(examples[j][0]) for j in group)
            out.append((group, (longest + 15) // 16 * 16))
            i += size
    if shuffle:
        rng.shuffle(out)
    return out


def collate(examples, group, width):
    """Inputs, plus the flat positions and labels that carry loss.

    Only target positions are supervised (~15% of tokens), so the LM head runs
    on those positions alone: computing 152k-way logits for every context and
    key position would cost most of the step and tens of GB.
    """
    inputs = []
    positions = []
    labels = []
    for row, j in enumerate(group):
        seq, start = examples[j]
        inputs.append(seq + [EOS] * (width - len(seq)))
        # Position t predicts token t+1.
        for t in range(start - 1, len(seq) - 1):
            positions.append(row * width + t)
            labels.append(seq[t + 1])
    return mx.array(inputs), mx.array(positions), mx.array(labels)


def loss_fn(model, inputs, positions, labels):
    hidden = model.model(inputs)
    flat = hidden.reshape(-1, hidden.shape[-1])[positions]
    if getattr(model.args, "tie_word_embeddings", True):
        logits = model.model.embed_tokens.as_linear(flat)
    else:
        logits = model.lm_head(flat)
    ce = nn.losses.cross_entropy(logits.astype(mx.float32), labels)
    ntoks = mx.array(labels.size, dtype=mx.float32)
    return ce.mean(), ntoks


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--model", type=Path, default=Path(__file__).resolve().parents[3] / "work/models/Qwen3-0.6B-Base")
    p.add_argument("--data", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--epochs", type=float, default=1.0)
    p.add_argument("--tokens-per-batch", type=int, default=6144)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--rank", type=int, default=64)
    p.add_argument("--scale", type=float, default=2.0)
    p.add_argument("--warmup", type=int, default=200)
    p.add_argument("--eval-every", type=int, default=1000)
    p.add_argument("--resume", type=Path, default=None)
    p.add_argument("--seed", type=int, default=7)
    args = p.parse_args()

    rng = random.Random(args.seed)
    mx.random.seed(args.seed)
    # This is a 16 GB machine that is also someone's desktop: keep MLX from
    # hoarding freed buffers, or the OS starts swapping and steps slow 10x.
    mx.set_cache_limit(512 * 1024 * 1024)
    args.out.mkdir(parents=True, exist_ok=True)
    fmt = Format(args.model / "tokenizer.json")

    t0 = time.time()
    train = load_examples(args.data / "train.jsonl", fmt, args.limit, rng)
    dev = load_examples(args.data / "dev.jsonl", fmt, 3000, random.Random(1))
    print(f"loaded {len(train)} train / {len(dev)} dev in {time.time()-t0:.0f}s", flush=True)

    model, _ = load(str(args.model))
    model.freeze()
    lora_config = {"rank": args.rank, "scale": args.scale, "dropout": 0.0, "keys": LORA_KEYS}
    linear_to_lora_layers(model, len(model.layers), lora_config)
    if args.resume:
        model.load_weights(str(args.resume), strict=False)
    n_train = sum(v.size for _, v in tree_flatten(model.trainable_parameters()))
    print(f"trainable parameters: {n_train/1e6:.1f}M", flush=True)
    (args.out / "adapter_config.json").write_text(json.dumps({
        "fine_tune_type": "lora",
        "num_layers": len(model.layers),
        "lora_parameters": lora_config,
    }, indent=2))

    epoch_batches = batches(train, args.tokens_per_batch, rng)
    total_steps = int(len(epoch_batches) * args.epochs)
    schedule = optim.join_schedules(
        [optim.linear_schedule(1e-6, args.lr, args.warmup),
         optim.cosine_decay(args.lr, max(1, total_steps - args.warmup), args.lr * 0.08)],
        [args.warmup],
    )
    optimizer = optim.AdamW(learning_rate=schedule, weight_decay=0.0)
    value_and_grad = nn.value_and_grad(model, loss_fn)

    def evaluate():
        total, count = 0.0, 0.0
        for group, width in batches(dev, args.tokens_per_batch, rng, shuffle=False):
            inputs, positions, labels = collate(dev, group, width)
            loss, ntoks = loss_fn(model, inputs, positions, labels)
            mx.eval(loss, ntoks)
            total += loss.item() * ntoks.item()
            count += ntoks.item()
        return total / max(count, 1)

    print(f"steps: {total_steps}  (batches/epoch {len(epoch_batches)})", flush=True)
    print(f"dev loss before: {evaluate():.4f}", flush=True)
    seen_tokens = 0
    running = None
    tic = time.time()
    s = 0
    epoch = 0
    while s < total_steps:
        plan = epoch_batches if epoch == 0 else batches(train, args.tokens_per_batch, rng)
        epoch += 1
        for group, width in plan:
            if s >= total_steps:
                break
            inputs, positions, labels = collate(train, group, width)
            (loss, ntoks), grads = value_and_grad(model, inputs, positions, labels)
            optimizer.update(model, grads)
            mx.eval(model.trainable_parameters(), optimizer.state, loss)
            s += 1
            seen_tokens += inputs.size
            running = loss.item() if running is None else 0.98 * running + 0.02 * loss.item()
            if s % 50 == 0 or s in (5, 20):
                elapsed = time.time() - tic
                print(
                    f"step {s}/{total_steps} loss {running:.4f} lr {optimizer.learning_rate.item():.2e} "
                    f"tok/s {seen_tokens/elapsed:.0f} mem {mx.get_peak_memory()/1e9:.1f}GB "
                    f"eta {(total_steps-s)*elapsed/s/60:.0f}m",
                    flush=True,
                )
            if s % args.eval_every == 0 or s == total_steps:
                print(f"step {s} dev loss {evaluate():.4f}", flush=True)
                weights = dict(tree_flatten(model.trainable_parameters()))
                mx.save_safetensors(str(args.out / "adapters.safetensors"), weights)
                mx.save_safetensors(str(args.out / f"step{s:06d}.safetensors"), weights)
    print("done", flush=True)


if __name__ == "__main__":
    main()
