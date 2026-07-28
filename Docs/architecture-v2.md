# BiLing architecture, v2 (in progress)

This document describes what is **implemented and measured**, and states
plainly what is not. Sections marked *Not yet implemented* are design intent
only; nothing here should be read as a claim that unbuilt work exists.

Status as of this commit: Phase 1 complete, Phase 3 partially complete. The
remaining phases of the v2 plan are listed at the end with their actual state.

---

## 1. Where the system stands

The runtime today is:

```
Keystrokes
  → incremental pinyin segmentation (syllable graph, all ambiguities kept)
  → hybrid lattice: word edges, character edges, name edges,
                    abbreviation edges, Latin edges, literal edge
  → exact decoding: forward Viterbi over (position, last word) states,
                    backward A* for the n-best
  → trigram rescoring of the finished n-best
  → evidence-gated Qwen re-ranking (asynchronous, never blocking)
  → candidate panel
  → encrypted local learning
```

The model is **not** on the keystroke path: the deterministic layer answers
every keystroke on its own, and Qwen results, when they arrive, re-sort a list
that is already on screen. Removing the model degrades ranking quality and
nothing else.

## 2. Scoring: one scale

Every candidate — dictionary word, composed sentence, abbreviation, name,
Latin term, or the raw keystrokes — is a log-probability under one generative
story: the user chose a sequence of words and typed each in some written form.

```
score(path) = Σᵢ [ log P(wordᵢ | context) + log P(formᵢ) ]
```

* `log P(word | context)` interpolates a word trigram, a word bigram and the
  lexicon unigram (Jelinek-Mercer). Bigram weight 0.40, trigram weight 0.15,
  both swept on the development set.
* `log P(form)` prices how the word was written: fully spelled 0.80, first
  syllable spelled with the rest as initials 0.13, initials only 0.07.
* Latin words enter the same unigram model through a stand-in frequency rather
  than an absolute probability, so they cannot outrank every Chinese word.
* The literal is a prior on wanting Latin output times a uniform letter model,
  so its cost scales with input length.

Path scores are **not** divided by segment count. A sum of log-probabilities is
already the probability of the path; averaging it destroys the length
preference that makes segmentation work.

### Why this replaced the previous scheme

Each candidate source previously had its own invented scale — `log1p(weight)+10`
for abbreviations, an averaged beam score plus bonuses for sentences, a bare
`18` or `100` for the literal. The constants were not comparable, so every fix
broke another case. Two features were "tuned" that way and the result was a
crash on `vscode` and a regression on `ai`. The single-scale model removed the
whole class of problem.

## 3. Decoding

**Forward pass.** Exact Viterbi. Under a bigram the decoder state is
(position, last word), not position, because the next word's score depends on
the last one. Every reachable state keeps the exact best score into it.

**Backward pass.** A\* from the end, ordering partial suffixes by
`f = g + forward[state]`. The forward score is the exact best completion, so
the heuristic is perfect and complete paths pop in strictly decreasing score
order.

**Honesty about exactness.** The n-best is exact *given the state set that
survived the forward pass*. The forward pass keeps at most 24 distinct
last-word states per position (`maxStatesPerPosition`), so the decoder is exact
under its state representation and approximate with respect to the full
lattice. The differential test against exhaustive enumeration
(`DecoderDifferentialTests`, oracle in `ReferenceDecoder.swift`) now measures
that approximation: on 3000 production-shaped random lattices where the cap
never fires the decoder is exact (0 top-1 disagreements, top-5 score
sequences identical), and on lattices built to exceed the cap with
idiom-style correlated transitions it loses top-1 in 7.5% of cases at a mean
1.50 nats — full numbers in `Docs/results/decoder-differential.txt`. The
loss requires *both* >24 distinct last-words at a position *and* a strongly
predicted continuation hanging off a weak-prefix word; independent random
transitions produce no measurable loss at all.

This replaced a beam search that kept the best few partial paths per position.
That failed exactly where the lattice is widest — long input and abbreviations
— because the correct path could be crowded out early and never return.
Measured: widening the beam moved coverage by fractions of a point at double
the latency; the exact formulation improved coverage *and* halved p95 latency,
because nothing is spent on paths that cannot win.

## 4. The lattice

| Edge type | Source | Status |
|---|---|---|
| Word (full pinyin) | lexicon, 1.44M entries | implemented |
| Character | every valid syllable → its characters | implemented |
| Personal name | surname + given-name characters | implemented |
| Initials abbreviation | `abbrev` code column | implemented |
| Mixed abbreviation | `mixed` code column | implemented |
| Latin, spelled out | curated table + system word list | implemented |
| Latin, completed | curated table + system word list | implemented |
| Literal | raw keystrokes | implemented |
| Fuzzy pinyin (z/zh, c/ch, s/sh, n/l, f/h, an/ang, en/eng, in/ing) | syllable rewrites over the inventory, priced per deviation | implemented, opt-in (`fuzzyPinyin`, default off) |
| Typing-error edges (QWERTY substitution, omission, duplication, transposition) | single-deviation repairs at segmentation dead-ends plus whole-buffer variants | implemented, opt-in (`fuzzyPinyin`, default off) |
| User-dictionary edges | learned entries enter as candidates, not edges | partial |
| Named entities beyond people | — | **not yet implemented** |

### Character fallback

Word edges alone can only reproduce sequences the lexicon already contains, so
an unlisted name or coinage is unreachable however the search is tuned. Every
valid syllable therefore also contributes its individual characters (top 20 by
frequency, swept on dev). Paths of many single characters are not free: each
segment pays `−log(total corpus weight)`, so character composition wins only
where no word covers the span.

### Personal names

Character fallback makes names constructible but picks the commonest character
per syllable — `wangjianlin` gives 望见林, not 王建林 — because nothing marks
those characters as being used as a name. A name model supplies that:

* `surnames(char, logp)` — how likely a character opens a personal name.
* `given_chars(char, position, logp)` — how likely a character sits at
  given-name position 1 or 2.

Both are estimated by `Tools/DataPipeline/build_name_model.py` from corpus text
whose licence is recorded, using jieba's part-of-speech tagger to locate actual
person names (`nr`). Two cheaper methods were tried and rejected with
measurements recorded in the script: counting characters after any surname
*character* produced 面 and 式 as the likeliest given names, because 方面 and
方式 are ordinary words; correcting that with pointwise mutual information
overshot and produced rare characters such as 乂 and 偲. Only tagging real
names gives a usable distribution.

The surname inventory itself is the conventional 百家姓 set. Membership is
public factual information; all weights are estimated from the named corpora.

### Fuzzy pinyin and typing-error tolerance

Both are alternative *readings* of a span of the buffer, generated by
`ToleranceGenerator` (PinyinLattice) and priced by `ScoreModel.Tolerance` as
log-probabilities on the shared scale — one deviation factor multiplied into
the same generative story as the word and form costs, never a bonus. A reading
carries at most one deviation, and repairs are only generated where exact
segmentation dead-ends (plus doubled letters, which are their own evidence),
which bounds the lattice.

Deviant readings enter three ways: character edges under the intended
syllable, word edges that begin with the intended syllable, and whole-buffer
variants looked up as ordinary exact keys (zongguo → zhongguo → 中国 as one
word). Admission differs by claim: fuzzy readings rank wherever their
probability puts them, because to an opted-in user z/zh *is* one sound; a typo
repair asserts the user slipped, so it must beat every exact reading or it is
suppressed as clutter.

The fuzzy cost is boxed in by two dev-set measurements — it must exceed the
≈ 10 nats by which a fuzzy whole-word rival can structurally beat an exact
multi-segment reading (碳素材料 vs 搪塑材料), and stay under the ≈ 11.5-nat
margin of a genuine rescue (zongguo → 中国). Measured on derived-dev with the
feature **on**: top-1 and top-5 unchanged to the decimal (32.5 / 44.2),
coverage +0.1, MRR −0.001, at ≈ +34 % median and +22 % p95 engine latency.
Off — the default, `fuzzyPinyin` — the tolerance code does not run and output
is byte-identical to the pre-feature engine. The latency price of the opt-in
is why it stays opt-in.

## 5. Personalisation

Selections are recorded to an AES-GCM encrypted SQLite store, key in the
Keychain, directory excluded from backup. A learned entry is anchored to the
most frequent word in the corpus, so one deliberate selection is worth at least
as much as the commonest reading — which is what makes a correction stick on
the next keystroke.

**Not yet implemented** from the v2 plan: multi-tier recency weighting, user
bigrams and phrases, structured learning events with candidate positions and
correction signals, HMAC-keyed deduplication indexes, retention limits, and the
export API. The current store learns a decayed count per (pinyin, text) pair
and applies a skip penalty to candidates the user paged past.

## 6. The model, and when it runs

Qwen3-0.6B-Base (Q4_K_M) runs in a separate launchd-managed daemon, reached
over XPC, and re-ranks the top 16 candidates. Its weight scales with the
evidence available to it:

```
λ(x) = 0.55 · e/(e+1),   e = (candidate length − 1) + 2·[context present]
```

At zero evidence — a one-character candidate with no preceding text — the model
gets no vote and the lexicon order stands. This is not a tuning constant: the
lexicon already carries unigram frequency estimated from a far larger corpus
than a 0.6B model's opinion about a single character, and all the model can add
is *conditional* structure. Before this change the model made single-syllable
and pure-Latin inputs measurably worse (100% → 87.5% and 100% → 80%).

A monotone guard bounds it further: the model may only promote candidates it
scores above the lexicon's own first choice, never demote that choice by an
arbitrary amount.

**Not yet implemented**: the compact discriminative Core ML reranker that the
v2 plan puts between the statistical decoder and Qwen. Today there are two
tiers (statistical, then Qwen), not three. Qwen is still used for online
re-ranking rather than being restricted to teacher and fallback duty.

## 7. Measured behaviour

All numbers from `Docs/results/`, corpus derived from Leipzig zho_news by
`scripts/build_eval_corpus.py`, split dev/test by sentence hash, every
parameter tuned on dev and test run once.

| | top-1 | top-5 | coverage | MRR | median |
|---|---|---|---|---|---|
| Lexicon only | 37.5% | 48.7% | 58.9% | 0.428 | 7.2 ms |
| + Qwen, with context | 44.2% | 52.5% | 58.9% | 0.477 | 41.0 ms |

Coverage is the ceiling: 44.2% top-1 against 58.9% coverage means roughly three
quarters of reachable answers already rank first, and most remaining error is
candidates never generated. That is why the v2 plan puts coverage ahead of
reranking sophistication, and why character and name edges came before any
neural work.

Against macOS's own Pinyin on 260 identical items, neither system given
context: **Apple 60.8%, BiLing 50.4%**. Apple is ahead. The gap is almost
entirely abbreviated input. See `docs/apple-comparison-protocol.md` for what
that comparison does and does not control.

## 8. Decisions worth recording

* **SQLite partial indexes need their predicate repeated in the query.**
  `WHERE mixed = ?` against an index declared `WHERE mixed <> ''` silently
  full-scanned 1.44M rows: 3035 ms versus 14.2 ms, a 214× difference from
  predicate placement alone.
* **Prune per decoder state, never globally.** Sums of log-probabilities mean a
  path that has consumed less input always scores higher, so a single global
  cutoff keeps whichever prefix is shortest.
* **Display form and key length are different things.** `embeddedWords`
  returned "VS Code" while the caller consumed `display.count` characters of
  input, indexing past the end of any key whose expansion is longer.
* **Lazy loading makes behaviour non-deterministic.** The Latin word list
  loaded in the background, so identical input converted or fell back
  depending on timing. It now starts loading at engine init.

## 9. Remaining v2 phases and their real state

| Phase | State |
|---|---|
| 1 Baseline and golden fixtures | done |
| 2 Modular engine protocols | not started — the engine is still one type |
| 3 Hybrid lattice | character, name, fuzzy, and typo edges done; entity edges not started |
| 4 Trainable typing channel | not started — form priors are still fixed constants |
| 5 Trainable statistical decoder | infrastructure shipped in fallback; trained θ refused export after bias masking (see implementation-report-v2.md) |
| 6 User language model tiers | not started |
| 7 Compact neural reranker | not started |
| 8 Confidence gating | margin gate calibrated on dev, 20–26% fewer model calls at equal top-1; no learned confidence model yet |
| 9 Qwen demotion and bridge fixes | not started |
| 10 Candidate stability controller | not started — generation tagging exists, no stability rules |
| 11 Context correctness audit | not started |
| 12 Data pipeline | partial — corpus, n-gram and name builders exist; no manifests or licence records |
| 13 Split design | partial — hash split by sentence; no source or time separation |
| 14 Evaluation metrics | partial — top-1/5, coverage, MRR, latency; no keystroke savings or churn |
| 15 Replay and energy benchmark | replay harness with signposts done; energy runs not yet automated |
| 16 Apple comparison protocol | partial — harness exists and is documented; no controlled protocol document |
| 17 CI and installer | not started |
| 18 Configuration and observability | not started |
| 19 Migration | ongoing |
