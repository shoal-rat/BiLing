# v2 implementation report

What was actually built in the v2 effort, what it measures, what was tried and
rejected, and what remains. Nothing below is aspirational; every number has a
command in `docs/evaluation-protocol.md`, and unfinished work is labelled
unfinished.

Baseline for comparison: `Docs/baseline/baseline-v1.md`
(37.5% top-1 lexicon-only, 44.2% full system, held-out derived test).

---

## Delivered

**Hybrid word-and-character lattice** (Phase 3). Character edges make unlisted
names and coinages constructible; a corpus-estimated name model (surnames +
given-name position distributions, located via jieba's `nr` tagging after two
cheaper estimators failed measurably) makes them *correct*: wangjianlin →
王建林, chenxiaoming → 陈小明. Compound-internal bigrams recover transitions
jieba's tokenisation hides — the reason 吉林东西没有空调 used to beat
吉林大学没有空调 — so the intended reading now wins in the deterministic layer
with no model involved.

**Fuzzy pinyin and typo repair** (Phase 3/4). z/zh, c/ch, s/sh, n/l, f/h,
an/ang, en/eng, in/ing; QWERTY-neighbour substitution, omission, duplication,
transposition, bounded to one deviation per syllable. Priced as
log-probabilities in the same generative story as everything else. Asymmetric
admission: fuzzy ranks by probability, typo repair must beat every exact
reading. Off by default and byte-identical when off; on, nihoa→你好,
wmen→我们, zongguo→中国 at ~34% median latency cost.

**Decoder correctness** (Phase 5). An exhaustive `ReferenceDecoder` oracle
shares the one edge-scoring function with the production decoder, and
differential tests over thousands of seeded random lattices measure the
approximation: **exact (0/2646) in the production-shaped regime**, 7.5% top-1
disagreement at 1.50 nats mean loss when the state cap is deliberately
exceeded with idiom-like correlated transitions. Two latent production bugs
found and fixed: the frontier trim was skipped after dead-end positions, and
zero-span edges could cycle the backward pass.

**Trainable ranker infrastructure** (Phase 5), shipped in fallback. Listwise
softmax trainer, versioned schema-checked weights, every failure path landing
on θ = [1,0,…] (the untrained engine). The first trained θ "won" by burying
every Latin candidate — Han-only training lists contain no Latin positive, so
features like `contains_latin` can only learn bias. The trainer now freezes
features with no positive-example support and refuses to export a model that
does not beat baseline on holdout. With the bias removed it doesn't beat it,
so the fallback ships. **The refusal is the result**: the infrastructure is
ready, and training waits for data that covers Latin, names, and
personalisation phenomena.

**Model-invocation gate** (Phase 8). Skip Qwen when the deterministic margin
between the top two candidates exceeds 3.0 nats — calibrated on dev
(`Docs/results/gate-calibration.txt`): **20–26% of invocations eliminated at
no measured top-1 cost**. Wired into the live controller.

**Replay benchmark** (Phase 15, partial). `biling-cli --replay` types corpora
one letter at a time: per-keystroke p50/p95/p99, model calls per keystroke,
top-1 churn, `os_signpost` intervals for Instruments. First measurements: p50
6.2 ms, p95 33.8 ms, **churn 97%** — the number that shows why a stability
controller (not yet built) matters.

**Protocol documents.** `architecture-v2.md`, `evaluation-protocol.md`,
`data-governance.md` — including corrections of two previous overclaims: the
decoder is exact only under its state representation, and networking is
designed-out rather than technically impossible (the processes are not
sandboxed).

## Held-out results at this commit

| | top-1 | top-5 | coverage | MRR |
|---|---|---|---|---|
| Baseline, lexicon only | 37.5% | 48.7% | 58.9% | 0.428 |
| **Now, lexicon only** | **37.8%** | **49.2%** | **60.0%** | **0.432** |
| Baseline, full system | 44.2% | 52.5% | 58.9% | 0.477 |
| **Now, full system** | **44.2%** | **53.2%** | **60.0%** | **0.480** |

Modest and honest: the headline gains of this round are capability (names,
compounds, typo/fuzzy), energy (26% fewer model calls at equal accuracy),
correctness (measured decoder guarantees, two bugs fixed), and
infrastructure (trainable ranker, replay harness) — not headline top-1.
Full-system numbers additionally reflect the gate: the model now runs on 73.5%
of items instead of all of them.

## Tried and rejected, with evidence

* Name edges inside the lattice: −3.8 coverage (state crowding) and
  whole-buffer names silently dropped as single-segment paths → names are
  whole candidates instead.
* Surname-character counting for the name model: 面/式 top the distribution
  (方面/方式 pollution); PMI correction: 乂/偲 (rare-event inflation). Both
  recorded in the builder.
* Un-masked ranker features: buried AI and xswl; length-ratio undivided by
  script: same effect in disguise.
* Gate margins below 2.0 nats: refuse calls the model would have won.

## Not implemented (remains from the 19-phase plan)

Modular engine protocols (2); named entities beyond people (3); trainable
typing channel — form priors are still constants (4); learned decoder weights
— the trainer exists but no exported model beats fallback yet (5); multi-tier
user LM, structured learning events, HMAC dedup index (6); compact Core ML
discriminative reranker (7) — the current gate is margin-only, not a learned
confidence model; Qwen bridge fixes: atomic cancellation, tokenization
boundary handling (9); candidate stability controller (10) — churn is
measured, untreated; context-isolation audit (11); data manifests (12);
source/time-separated splits (13); energy instrumentation beyond signposts
(15); Apple comparison protocol doc (16); CI without LFS, transactional
installer (17); configuration system and diagnostics mode (18).

Apple Pinyin remains ahead on the paired no-context comparison (60.8% vs
50.4% at the last measurement, before this round's changes; not re-run since —
re-running it requires taking over the keyboard). No claim of parity is made.
