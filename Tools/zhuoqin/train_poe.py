#!/usr/bin/env python3
"""Train 听音 *as one of two ears*: the product-of-experts objective.

At inference 子期 scores every token with log P听音 + w·log P知意, where 知意
is the plain base model reading only the context. train.py trains 听音 as if
it were alone, so it never learns to overrule 知意's biases (with no context
the base model leans toward document openings: 看点是 for kandianshi). Here
the loss is the cross-entropy of the renormalised product

    p(t) ∝ exp(log p听音(t) + w · log p知意(t))

with 知意 = the same network with its LoRA switched off, no gradient. 听音
learns exactly the correction 知意 needs — what the two ears do together.

    python train_poe.py --data DIR --out RUN --resume PREV/adapters.safetensors
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
    """[(听音 sequence, its target start, 知意 sequence, its target start)]."""
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
        zprompt = [EOS] + c.ids
        zseq = zprompt + t.ids + [EOS]
        if len(seq) <= 160:
            out.append((seq, len(prompt), zseq, len(zprompt)))
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
    """Both ears' inputs, the flat positions that carry loss, and labels.

    Only target positions are supervised, so the LM head runs on those alone.
    The two sequences supervise the same target tokens in the same order.
    """
    inputs, positions, zinputs, zpositions, labels = [], [], [], [], []
    zwidth = max(len(examples[j][2]) for j in group)
    zwidth = (zwidth + 15) // 16 * 16
    for row, j in enumerate(group):
        seq, start, zseq, zstart = examples[j]
        inputs.append(seq + [EOS] * (width - len(seq)))
        zinputs.append(zseq + [EOS] * (zwidth - len(zseq)))
        for k, t in enumerate(range(start - 1, len(seq) - 1)):
            positions.append(row * width + t)
            zpositions.append(row * zwidth + zstart - 1 + k)
            labels.append(seq[t + 1])
    return (mx.array(inputs), mx.array(positions), mx.array(zinputs), mx.array(zpositions), mx.array(labels))


ZHI_WEIGHT = 0.6
_LORA: list = []


def head(model, hidden, positions):
    flat = hidden.reshape(-1, hidden.shape[-1])[positions]
    if getattr(model.args, "tie_word_embeddings", True):
        return model.model.embed_tokens.as_linear(flat)
    return model.lm_head(flat)


def loss_fn(model, inputs, positions, zinputs, zpositions, labels):
    ting = head(model, model.model(inputs), positions).astype(mx.float32)
    # 知意: the same network with every LoRA scaled to zero, no gradient.
    saved = [m.scale for m in _LORA]
    for m in _LORA:
        m.scale = 0.0
    zhi = mx.stop_gradient(head(model, model.model(zinputs), zpositions).astype(mx.float32))
    for m, s in zip(_LORA, saved):
        m.scale = s
    product = (ting - mx.logsumexp(ting, axis=-1, keepdims=True)) + ZHI_WEIGHT * (zhi - mx.logsumexp(zhi, axis=-1, keepdims=True))
    ce = nn.losses.cross_entropy(product, labels)
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
    p.add_argument("--zhi-weight", type=float, default=0.6)
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
    global ZHI_WEIGHT
    ZHI_WEIGHT = args.zhi_weight
    _LORA.extend(m for _, m in model.named_modules() if hasattr(m, "lora_a") and hasattr(m, "scale"))
    print(f"LoRA layers toggled for 知意: {len(_LORA)}", flush=True)
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
            batch = collate(dev, group, width)
            loss, ntoks = loss_fn(model, *batch)
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
            batch = collate(train, group, width)
            inputs = batch[0]
            (loss, ntoks), grads = value_and_grad(model, *batch)
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
