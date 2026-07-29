# Apple Pinyin comparison protocol

The comparison against Apple's Simplified-Chinese input method is the number
people will quote, so it is the number with the strictest procedure. This
document is the procedure. A comparison that deviates from it should either
not be published or state the deviation next to the headline number.

## 1. What must be recorded before the run

Every published comparison records, verbatim:

| Item | How to obtain |
|---|---|
| Hardware model and chip | `system_profiler SPHardwareDataType` (model identifier, chip, memory) |
| macOS version **and build** | `sw_vers` — the build string, not just "26.5" |
| Apple IME identity | Input-source ID (`com.apple.inputmethod.SCIM.ITABC`). Apple ships the IME with the OS and gives it no separate version string, so **the macOS build number *is* the IME version** and must be recorded for that reason |
| BiLing version and commit | `git rev-parse HEAD`, plus the tag if any |
| Lexicon provenance | The `metadata` table of `lexicon.sqlite3` (`format_version`, `sources`, counts) |
| Model | Whether the run is engine-only or includes the Qwen re-ranker, and which GGUF (sha256) |
| Harness commit | `scripts/apple_baseline.swift` at the commit used |
| Corpus | Exact TSV file, its generator command and seed, and its manifest entry |
| Apple learning state | See §2 — whether the run used a fresh account or an account with prior typing history |
| Keyboard layout | ANSI assumed by the harness key-code table; anything else invalidates the run |

## 2. Apple's user learning is part of the system under test

Apple Pinyin adapts to the user. Two consequences:

1. **Prior state.** A comparison run in a long-lived user account measures
   "Apple Pinyin as trained by this user", not stock Apple Pinyin. Prefer a
   fresh macOS user account. If that is impractical, say so in the results
   file — it biases Apple in an unknown direction and the reader deserves to
   know.
2. **Learning during the run.** The harness commits text with space, and
   Apple learns from commits, so late items see a slightly different IME than
   early items. Mitigations, in order of preference: run in a fresh account;
   randomise item order (record the seed); and never compare two Apple runs
   that processed the corpus in different orders as if they were replicates.

BiLing must be run with an **empty learning store** for symmetry (the
evaluation harness constructs a fresh `MemoryLearningStore`, which satisfies
this; say so anyway).

## 3. Corpus construction

- Items come from a **derived corpus** (`scripts/build_eval_corpus.py`):
  sentences nobody on the project chose, segmented and romanised by tools that
  know nothing about either IME. Hand-picked showcase items are advertising,
  not measurement.
- Prefer the **source-separated** set (`--split-by source-file`) so BiLing's
  n-grams cannot have trained on near-duplicates of the test items. Apple's
  training corpus is unknown and unknowable; ours at least is controlled.
- The harness can only type `a`–`z`, so it skips items containing anything
  else. **Apply the same filter to BiLing's item list first** — both systems
  must see byte-identical item sets, or the pairing is fiction.
- Fix the item list and `n` **before** the first run of either system.
  Dropping an item after seeing an output is cherry-picking, with one
  exception: a documented technical failure of the harness itself (e.g. the
  window lost focus mid-item), which must be removed from **both** sides and
  listed in the results file.

## 4. Paired design

Both systems answer the identical items; the unit of analysis is the item
pair. For each item `i`, record `a_i ∈ {0,1}` (Apple top-1 correct) and
`b_i ∈ {0,1}` (BiLing top-1 correct). Publish:

- both marginal accuracies,
- the win/loss/tie decomposition (`a_i > b_i` / `a_i < b_i` / equal) — this is
  the "both directions" rule made concrete: items BiLing wins are reported
  with exactly the prominence of items Apple wins,
- the paired mean difference with its bootstrap CI (§6),
- per-category breakdowns of the same.

**Top-1 only.** The harness observes what a space-commit produces; it cannot
see Apple's candidate list. Top-5, MRR and coverage are therefore not
comparable and must not appear in a comparison table. Latency is likewise not
comparable — the harness's event-pump waits dominate Apple's number — so no
latency claims about Apple, ever.

## 5. Known limitations of the CGEvent harness

`scripts/apple_baseline.swift` drives Apple's IME as a user would: it selects
the input source, posts synthetic key events into a real `NSTextView`, commits
with space, and reads what landed. Its known failure modes, so results can be
read with appropriate suspicion:

- **Accessibility permission.** Synthetic `CGEvent`s require the terminal to
  be trusted for Accessibility. The harness checks `AXIsProcessTrusted()` and
  aborts rather than reporting all-failures — but the permission must be
  granted to the exact binary that runs it, which is easy to get wrong after
  toolchain updates.
- **Event pump.** Posted events are delivered through `NSApplication`; the
  harness must dequeue and dispatch them itself (`NSApp.nextEvent`/
  `sendEvent`). The waits between keys (~12 ms) and around commits (~450 ms)
  are empirical: a machine under load can exceed them, making a slow
  conversion read as an empty answer. Empty answers should be investigated,
  not counted as Apple errors.
- **Repeated-space commits.** Long input converts in several segments; the
  harness presses space up to six times until the text view stops growing.
  If Apple's segmentation pauses mid-sentence, an extra space can select an
  unintended candidate — an artefact of the harness, not of Apple's
  conversion. Spot-check a sample of long-item transcripts by hand.
- **Escape between items** clears composition state; if an escape is lost,
  residue leaks into the next item. The harness clears the view and the
  running transcript makes this visible, but only to someone who looks.
- **Exclusive machine.** Any real keystroke or focus change during the run
  corrupts it. Do not touch the machine; disable screen lock and notifications
  first. The harness takes over the keyboard — never run it unattended on a
  machine someone is using.

## 6. Bootstrap CI for the paired difference

The statistic is the mean paired difference `D = (1/n) Σ (a_i − b_i)`,
estimated with a **percentile bootstrap on item pairs**:

1. Input: the two per-item correctness vectors, joined on the item identity
   (category, pinyin, expected) so pairing is enforced by construction.
2. For each of `B = 10,000` iterations, draw `n` **indices** `i` uniformly
   with replacement from `1..n` and keep the pairs intact — resampling items,
   never resampling `a` and `b` independently (that would destroy the
   correlation that makes the paired design powerful).
3. Compute the mean difference of each resample; collect the `B` values.
4. The 95% CI is the 2.5th and 97.5th percentiles of that collection.
5. Report `D`, the CI, `B`, and the RNG seed. The run is reproducible from
   the two vectors, `B`, and the seed alone.

If the CI excludes zero, the direction of the difference is supported at the
95% level; if it includes zero, the honest summary is "not distinguishable on
this corpus", regardless of which point estimate is larger.

`scripts/paired_bootstrap.py` implements exactly this and refuses to run on
mismatched item sets.

## 7. Honesty rules

1. **Both directions, always.** Wins, losses and ties are one table. A results
   file that lists only the categories where BiLing improved is broken.
2. **No cherry-picking.** Corpus and `n` fixed before the run; no re-rolling
   the corpus seed until the gap looks better; every run performed is either
   published or listed as discarded with its reason.
3. **Identical context handling.** The current harness types bare keys, so
   Apple receives no context — therefore BiLing must be scored with
   `--no-context` in comparison tables. If a future harness supplies context
   to Apple (typing the context, committing, then the item), it must supply
   the identical string to BiLing, and the results file must say which regime
   was used. Comparing context-fed BiLing against context-free Apple is the
   single easiest way to lie with this benchmark.
4. **Exact commands.** The results file contains the literal commands for
   both runs, the corpus checksum, and everything in §1's table.
5. **Uncertainty next to the point estimate.** The headline difference never
   appears without its CI (§6).
