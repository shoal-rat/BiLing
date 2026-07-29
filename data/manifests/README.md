# Data-source manifests

One JSON file per data source that BiLing actually consumes. **Policy: no
source ships without a manifest.** If a build step starts reading a new corpus,
dictionary, or inventory, the change that introduces it must also add a
manifest here — a pull request adding a `--source` without a manifest is
incomplete by definition.

## What a manifest records

| Field | Meaning |
|---|---|
| `name`, `kind`, `version` | What the source is and which revision/sample of it |
| `retrieved` | When the local copy was obtained |
| `url` | Where it came from |
| `local_file` | Where the copy lives (repo path, or `~/.cache/biling-corpus/` for corpora that are never committed) |
| `sha256` | Checksum of the exact local file the pipeline read, so a silent upstream change or local corruption is detectable |
| `licence` | Licence name **plus how it was verified**: the method, the date, and the URL actually consulted. `verified: true` means someone fetched the terms and read them — not that a licence name was copied from a README. If the terms page cannot be reached, the manifest must say `unverified` rather than guess. |
| `used_for` | lexicon / language model / name model / evaluation — and any hygiene constraints (e.g. "evaluation only, never training") |
| `redistribution` | Whether the repository ships the data or only derived statistics |

## Verification honesty

Licence verification for the current manifests (2026-07-29):

- **rime-pinyin-simp** and **rime-wanxiang**: SPDX ids confirmed via the GitHub
  licence API against the live repositories (Apache-2.0 and CC-BY-4.0
  respectively). Full licence texts are preserved in `Resources/Lexicon/`.
- **Leipzig Corpora Collection**: the live terms page
  (<https://wortschatz.uni-leipzig.de/en/usage>) sits behind an anti-bot
  interstitial that defeated automated fetching, so verification used the
  Internet Archive snapshot `20260206070156` of that exact page. The snapshot
  distinguishes two regimes: the *web applications* are CC BY-NC, the
  *downloadable text corpora* are **CC BY**. BiLing only uses the downloads.
  If Leipzig's terms change, the snapshot date recorded in each manifest bounds
  what was actually known.

## Training/evaluation separation, in one place

- Training pool (bigrams, trigrams, name-model weights):
  `zho_news_2007-2009_1M`, `zho_news_2020_100K`, `zho_news_2020_300K`,
  `zho_wikipedia_2018_300K`.
- Hash-split evaluation source: `zho_news_2020_10K` — exact sentences excluded
  from training, but it samples the same news-2020 collection as two training
  files, so near-duplicate leakage is possible.
- Source-separated evaluation source: `zho-cn_web_2015_30K` — different
  collection, year, and genre from every training file. **Never add it to the
  training pool.**

## Out of scope for this directory

The Qwen3-0.6B-Base re-ranking model is a model artefact, not a text corpus;
its licence (Apache-2.0) ships next to the weights in `Models/`. The macOS
`/usr/share/dict/words` list is a system file read at runtime and never
redistributed. Both are catalogued in `docs/data-governance.md`.
