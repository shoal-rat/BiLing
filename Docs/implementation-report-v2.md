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

**Learning store v2** (Phase 6). The v1 dedup constraint
`UNIQUE(pinyin_hash, text_cipher)` could never fire — AES-GCM ciphertext is
randomised — so uniqueness was an O(rows) decrypt-and-compare scan. v2 indexes
keyed HMACs of the plaintext: real constraint, one indexed statement per
update, nothing readable without the Keychain key. Recency became three EMAs
(τ = 50/500/5000 selections) whose mixture forgets like a power law; committed
sentences teach word-transition evidence that interpolates into the lexicon
bigram model with weight earned from evidence (μ = n/(n+40), capped 0.7);
an encrypted event log feeds offline fitting; retention caps, per-item
deletion, full decrypted export (`--export-learning`). One-transaction
migration recomputes the pinyin hash under its new domain prefix — without
that, every migrated row would have been silently unreachable (caught by the
migration reachability test).

**Deterministic context** (Phase 3/16 follow-through). The engine accepted a
context parameter and never read it — measured bit-identical with and without
context; all context value was bought from Qwen at 25–40 ms. Now the last
committed word substitutes for the decoder's sentence-start marker and adds a
promotion-only delta to whole-key candidates, in the same Jelinek-Mercer
blend the lattice already uses. Contrast corpus, engine only: 41.9% → 48.8%
at ~1 ms. One honest wrinkle, pinned by test: under the finite state cap the
promotion is per-path, not list-level — a promoted rival can evict the path a
tail candidate scored through.

**Calibrated dual-mode gate** (Phase 8). Logistic P(top-1 wrong) over
list-shape features replaces the fixed 3.0-nat margin — fit separately for
cold and context-shaped lists after measuring that the cold fit under-fires
on context lists (7 contrast points lost to wrong skips). At the shipped
thresholds: cold accuracy equal to the margin rule at 66% of its invocations;
context accuracy equal at 74%. Holdout Brier 0.143/0.145 vs 0.231/0.227 base.

**Distilled reranker: infrastructure only** (Phase 7). A 12→16→1 MLP trained
against Qwen's per-candidate log-probabilities (4,394 cold + 4,435 context
teacher lists) lands within noise of the deterministic baseline at every
(α, T) grid point — the 12-feature bottleneck cannot carry the teacher's
text-level knowledge. The trainer refuses statistically insignificant exports
(> 1.96σ required); the Swift runtime (loader, forward pass, promotion-only
blend) ships dormant and tested. Plain Swift, not Core ML: at ~500 parameters
the arithmetic is ~1 µs, below Core ML's dispatch overhead.

**Qwen bridge correctness** (Phase 9). C11 `_Atomic` cancellation checked in
llama.cpp's abort callback and between decode waves, with a fixed
signal-vs-reset race; newer generations supersede older requests
automatically. Candidates are tokenized merged with their context and only
the divergent suffix is priced, with partial KV reuse on boundary merges.
Wall-clock budget (default 2500 ms) returns nil so the deterministic ranking
ships; model-load failure disables the ranker for the session, logged once.
Twelve tests skip cleanly when the GGUF is absent.

**Candidate stability + context isolation** (Phases 10–11). A pure
`CandidateStabilityController`: no reordering after manual navigation,
adjacent-swap hysteresis, re-promotion damping — calibrated at 0.1 nats after
measuring that the spec's suggested 0.5 suppressed context *corrections*
(87.5% → 83.3%); shipped setting keeps accuracy parity while suppressing the
purely cosmetic flip. The audit found and fixed a real leak: committed
context survived app switches, so text typed in one app influenced rankings
in another. Replies are now structurally bound to their (generation, buffer)
stamp.

**Entity lexicon beyond people** (Phase 3). jieba ns/nt tagging over 300K
news sentences: 3,861 typed entities recorded, 682 previously-unreachable
compounds (county-level places, foreign nations) added as entries, filtered
against the lexicon's own character inventory because the Leipzig crawl
mixes traditional script.

**Data governance and split rigour** (Phases 12–13). Nine manifests with
verified licences (Apache-2.0, CC-BY-4.0 via GitHub API; Leipzig CC BY via
an archived snapshot of terms blocked behind an anti-bot gate — recorded as
such). A source-separated test set (zho-cn_web_2015, disjoint from every
training file) reads 13.1% engine-only / 17.5% full — the results file says
plainly that this conflates leakage removal with genuine domain shift
(coverage collapses to 26% at candidate generation, which leakage cannot
explain).

**Config, typing channel, metrics** (Phases 4, 14, 18). A versioned
per-field-validated config file for the swept expert knobs (gate thresholds,
fan-ins, model timeout, opt-in-only diagnostics); TypingForm priors behind a
guardrailed loadable channel with a fit script that accepts only real
event-log exports — fitting from the derived corpora would be circular, and
the script refuses and says why; --evaluate now reports first-page coverage,
average selected position, and keystrokes-per-character.

**CI without LFS, transactional installer** (Phase 17). A 69 KB fixture
lexicon with the exact production schema (committed as a plain git blob),
`BILING_LEXICON_PATH` override, availability-gated golden suites that read
an LFS pointer file as absent, a workflow that never fetches LFS objects,
and an installer with trap-based rollback (previous bundle restored,
launchd re-bootstrapped, input source re-registered) exercised by
`scripts/test_installer_rollback.sh` against a temp prefix.

**Apple comparison, with context** (Phase 16). The CGEvent harness gained
--context: the committed context is seeded into the text view, caret at the
end, and only text after the seed is read. On 150 held-out general-text
items both systems saw identically: BiLing 76.0% vs Apple 77.3%, 95% CI
[−7.3, +4.7] — statistical parity where the frozen cold comparison had
Apple ahead by 10.4. On the 43-item contrast corpus BiLing 79.1% vs 67.4%,
CI touching zero at that n. Stated exactly that way, nothing stronger.

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

Modular engine protocols (2) — extraction of whole-key candidate producers
behind a protocol is in review on a branch, behavioural-identity gated;
learned decoder weights (5) and the distilled reranker (7) — both trainers
exist and both refuse to export because nothing beats fallback beyond noise
(the refusal is the result; infrastructure ships dormant); energy
instrumentation beyond signposts and the gate's measured invocation cuts
(15) — powermetrics automation was not built.

Apple Pinyin remains ahead cold (60.8% vs 50.4%, frozen 260-item
comparison). With committed context the systems are statistically
indistinguishable on general text and BiLing leads on context
disambiguation at an n too small to certify — see
`Docs/results/apple-comparison-context.txt`. No parity claim is made for
cold start; no SOTA claim is made anywhere.
