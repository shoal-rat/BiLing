# Data governance

Two separate concerns share this document: what happens to **the user's typing**
(nothing leaves the machine), and where **training data** comes from and under
what licence.

---

## Part 1 — user data

### What is stored

One encrypted SQLite database at
`~/Library/Application Support/BiLing/learning.sqlite3`, holding aggregated
counts of "for this pinyin, this candidate was chosen", plus a skip signal for
candidates shown and passed over.

**Not** a keystroke stream. Not sentences. Not documents.

| | |
|---|---|
| Encryption | AES-GCM per field |
| Key | 256-bit random, generated on first run, stored in the login Keychain |
| Index | HMAC-SHA256 of the pinyin, so rows are findable without decrypting |
| Backups | directory marked excluded from Time Machine and iCloud |
| Reset | Preferences → 学习与隐私 → clear, which drops every row |

The HMAC index exists because AES-GCM is randomised: two encryptions of the same
pinyin differ, so ciphertext cannot be used as a lookup key. A keyed HMAC gives
a stable index without revealing the plaintext to anyone without the key.

### What is never learned

Learning is skipped entirely when:

* macOS reports **Secure Event Input** — password fields. The OS also stops
  delivering keystrokes to third-party input methods in that state, so this is
  belt and braces.
* the frontmost application is a **terminal or password manager**, matched on
  bundle identifier.
* the text looks like a **secret or identifier**: runs of four or more digits,
  anything containing `@` or `://`, high-entropy Latin strings, or text over 48
  characters.
* the candidate was the **raw literal** the user typed rather than a conversion.

### Network

The input method and its engine make no network requests. There is no
telemetry, no crash reporting, no model download at runtime, and no analytics.

**Stated precisely, because the previous wording overclaimed.** The processes
are *not* sandboxed, so the absence of a network entitlement does not make
network access technically impossible — an unsandboxed process can open a
socket regardless of entitlements. What is true and checkable is that no code
path in the input method or engine performs network I/O. Data acquisition
(corpora, base model) happens only in `scripts/` and `Tools/DataPipeline/`,
which are developer tools that never run as part of the input method.

Adding an explicit sandbox with no network entitlement, so the claim is enforced
rather than merely true, is open work named in `docs/architecture-v2.md`.

### Context handling

Context is read from the host application — up to 600 characters before the
caret — and used only to rank candidates for the current composition. It is
never written to disk and never included in learning records.

**Known gap.** Per-application context isolation has not been audited. The
requirement that no context from one application can influence another is
stated in the v2 plan and is **not yet verified by tests**.

---

## Part 2 — training data

### Sources currently used

| Source | Used for | Licence | Redistributed here? |
|---|---|---|---|
| Leipzig Corpora, `zho_news_2020_10K` | deriving the evaluation corpus | CC BY, per Leipzig's terms | **No** — fetched by script |
| Leipzig Corpora, `zho_news_2007-2009_1M`, `zho_news_2020_300K`, `zho_wikipedia_2018_300K`, `zho_news_2020_100K` | word n-grams, name model | CC BY, per Leipzig's terms | **No** — fetched by script |
| 万象拼音 (`rime_wanxiang`) | lexicon | CC BY 4.0 | Yes, compiled into `lexicon.sqlite3`; attribution in `Resources/Lexicon/` |
| Rime `pinyin-simp` | lexicon | Apache-2.0 | Yes, same |
| Qwen3-0.6B-Base | re-ranking | Apache-2.0 | Yes, GGUF via Git LFS; licence in `Models/` |
| macOS `/usr/share/dict/words` | Latin completions | system file, read at runtime | No |
| 百家姓 surname inventory | name model | public factual information, not a dataset | The character list is in the script |

Corpora are **not** committed. The generators fetch them, and derived corpora
are gitignored, so the repository never redistributes third-party text.

### Contamination control

Any sentence appearing in the corpus used to derive the evaluation set is
excluded from n-gram and name-model training. This is not theoretical: when the
100K and 10K Leipzig sets were pooled, **1,345 sentences overlapped**, and later
5,269 across the full pool. Training on those would have let the model memorise
test items.

```bash
python3 scripts/build_bigrams.py \
    --source <training corpora…> \
    --exclude ~/.cache/biling-corpus/zho_news_2020_10K-sentences.txt \
    --lexicon Sources/BackboneEngine/Resources/lexicon.sqlite3
```

The script reports how many sentences it dropped. A run that reports zero
exclusions against a known-overlapping pool should be treated as a bug.

### Name model provenance

Surname *membership* (王, 李, 张 …) is public factual information rather than a
copyrightable dataset. Every weight — surname frequencies and the entire
given-name character distribution — is estimated from the corpora above using
jieba's part-of-speech tagger to locate real person names. No proprietary name
database is used.

### Derived artefacts and their versions

| Artefact | Where | Versioned by |
|---|---|---|
| Lexicon + n-grams + name model | `Sources/BackboneEngine/Resources/lexicon.sqlite3` | `metadata.format_version`, `metadata.name_model_version`, `metadata.sources` |
| Evaluation corpora | `Tests/Corpus/derived-{dev,test}.tsv` | generator seed, recorded in the file header |
| Personal model (optional) | `~/Library/Application Support/BiLing/adapters/` | filename; deleting it reverts to stock |

`metadata.sources` records the exact source files and weight boosts used to
build the lexicon. This matters: a rebuild with different boosts silently
shifted every weight in the database once, and the recorded value is what made
it detectable.

### Per-source manifests

`data/manifests/` holds one JSON manifest per source — URL, sha256 of the local
file, retrieval date, role (lexicon / LM / name model / evaluation), and the
licence **with a record of how it was verified** (what was fetched, when, and
via what route). The policy, spelled out in `data/manifests/README.md`: no
source ships without a manifest.

### Not yet implemented

Automated licence re-verification; near-duplicate removal beyond what Leipzig
does upstream; and privacy filtering of training text. These remain named in
the v2 plan.
