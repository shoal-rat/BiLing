# Evaluation protocol

How BiLing is measured, why each choice was made, and what the numbers do and
do not support. Everything here is runnable; commands are given for each claim.

---

## 1. Two corpora, and why both exist

**The authored corpus** (`Tests/Corpus/eval.tsv`, 72 items) is hand-written and
kept only as a fast smoke check. It is **not** a measurement instrument. It
overstates accuracy by roughly 2.4×, which is the single most important
methodological finding in the project: a corpus written by the person who wrote
the engine measures what that person already knew worked.

**The derived corpus** is the real evaluation. Nobody chooses its items:

1. Sentences come from a public news corpus (Leipzig `zho_news_2020_10K`).
2. `jieba` segments them into words; `pypinyin` supplies readings. Neither tool
   knows the BiLing lexicon exists, so neither can be biased toward it.
3. Keystrokes are **sampled from the engine's own typing-form prior** — for each
   word, spelled out, first-syllable-plus-initials, or initials only — so the
   engine must invert a process it had no hand in.

```bash
python3 scripts/build_eval_corpus.py --fetch --limit 800
```

The same `--seed` reproduces the corpus exactly. The output is gitignored: it is
third-party text under its own licence, so the repository ships the generator,
not the derivation.

## 2. Splitting

Items are assigned to dev or test by **hash of the source clause**, so a
sentence and all keystroke variants derived from it land in the same split.
Without that, the same sentence would appear in both under different
abbreviation profiles and the test set would be contaminated by construction.

Every parameter in the engine — the transition weight, the trigram weight, the
literal prior, character fan-in, abbreviation fan-in, n-best size — was swept on
**dev only**. `derived-test.tsv` is run once per reported result.

**Known gap.** The split is by sentence, not by source document, publication
date, or domain. Leipzig sentences are already shuffled and de-duplicated
upstream, which limits but does not eliminate leakage between related sentences.
Source- and time-separated splits are specified in the v2 plan and are **not yet
implemented**.

## 3. Metrics, and what each is for

| Metric | Question it answers |
|---|---|
| top-1 | Did the user get the whole target without touching anything? |
| top-5 | Was it on the first page? |
| **coverage** | Was it generated *at all*, anywhere in the list? |
| MRR | How far down, on average? |
| p50 / p95 / p99 latency | How does it feel while typing? |
| model calls per keystroke | How much energy does ranking cost? |
| top-1 churn | How much does the list jump around as you type? |

**Coverage is reported separately from ranking on purpose.** They fail for
opposite reasons and need opposite fixes: a candidate that was never generated
is a search or lexicon problem, one generated but ranked low is a scoring
problem. Conflating them sends work to the wrong place. Currently top-1 is
~75% of coverage, meaning most remaining error is generation, not ranking —
which is why character and name edges were built before any neural work.

**top-1 is full-target exact match**, not character accuracy. A twenty-character
sentence with one wrong character scores zero. This is deliberately strict and
is *not* comparable to per-character numbers quoted elsewhere in the literature.

## 4. Commands

```bash
# Accuracy, deterministic layer only
.build/release/biling-cli --evaluate Tests/Corpus/derived-test.tsv \
    --engine-only --no-context

# Accuracy, full system with context
.build/release/biling-cli --evaluate Tests/Corpus/derived-test.tsv

# Per-keystroke latency, model-call rate, candidate churn
.build/release/biling-cli --replay Tests/Corpus/derived-dev.tsv \
    --replay-limit 120 --engine-only
```

The replay harness types each buffer one letter at a time, which is the only way
per-keystroke cost and inter-keystroke instability become visible; whole-buffer
evaluation hides both. Each interval is emitted as an `os_signpost` under
subsystem `com.biling.inputmethod.BiLing`, so the same run can be opened in
Instruments (Time Profiler, Energy Log) without altering the measured path.

## 5. Ablations to run when changing scoring

Report all four. The gap between the first two isolates the model; the gap
between the last two isolates reading the document context.

| Condition | Flags |
|---|---|
| Lexicon only | `--engine-only --no-context` |
| Lexicon + context | `--engine-only` |
| Lexicon + model | `--no-context` |
| Full system | *(none)* |

## 6. Reporting rules

* Quote the corpus, split, and commit alongside any number.
* State the machine: measurements here are Apple M5 / 16 GB / macOS 26.5.
* Never tune on `derived-test.tsv`. If a threshold was chosen by sweeping,
  say which set it was swept on and show the sweep.
* Report regressions in the same table as improvements. Two changes in this
  project — beam widening and per-state pruning — were measured, found not to
  pay, and reverted; both are recorded rather than quietly dropped.
* Do not claim parity with or superiority over another input method without a
  controlled comparison. See `docs/apple-comparison-protocol.md`.

## 7. Current headline numbers

Derived test set, 1,761 items, all tuning on dev, test run once:

| | top-1 | top-5 | coverage | MRR | median |
|---|---|---|---|---|---|
| Lexicon only | 37.5% | 48.7% | 58.9% | 0.428 | 7.2 ms |
| Full system | 44.2% | 52.5% | 58.9% | 0.477 | 41.0 ms |

Per-keystroke replay, deterministic layer, 3,043 keystrokes:
p50 6.2 ms, p95 33.8 ms, p99 53.0 ms, top-1 churn 97.1%.

The p95 sits well above the sub-5 ms intent for the keystroke path. It is
concentrated in abbreviated input, where the abbreviation fan-in is widest.
Churn of 97% is partly inherent — the answer for `ni` should differ from the
answer for `nihao` — but it is untreated: no stability controller exists yet.
Both are open, and both are named in `docs/architecture-v2.md`.
