# BiLing 笔灵

[简体中文](README.md) · **English**

![BiLing — local AI pinyin for macOS](Docs/hero.svg)

## Your words should arrive before the software gets in the way.

BiLing is a native macOS Pinyin input method that combines a 1.44-million-entry
open-source lexicon with a bundled Qwen3 model. It understands context locally,
learns useful choices without uploading keystrokes, and presents candidates in
a compact interface built for macOS.

Type `jilindaxue`. Get **吉林大学**. Press Space. Keep thinking.

> **Private by construction.** The model, lexicon, inference runtime, and
> learning store live on this Mac. BiLing contains no network client and
> requires no account, API key, model download, or dictionary warm-up.

### Install and type

For most users, download
`BiLing-1.2.0-online-installer-macOS-arm64.zip` from the
[latest release](https://github.com/shoal-rat/BiLing/releases/latest), extract
it, then Control-click **在线安装笔灵.command** and choose Open. The installer
fetches the one pinned Qwen LFS object and verifies its size and SHA-256; it
needs neither Homebrew, Xcode, an API key, nor network access after installation.

To build from source:

```bash
git lfs install
git clone https://github.com/shoal-rat/BiLing.git
cd BiLing
brew install llama.cpp ggml libomp
./scripts/install.sh
```

Select **笔灵** from the macOS input menu, type Pinyin, and press Space to
commit the highlighted candidate. The installer already includes Qwen and the
compiled vocabulary; first-time users do not need to train or import anything.

---

# A native, local-LLM Pinyin input method for macOS

## Abstract

BiLing treats Pinyin conversion as constrained contextual ranking. A
deterministic engine maps an incremental Pinyin lattice to lexical and
sentence-level candidates. A local Qwen3-0.6B-Base model then scores the
highest-priority candidates using recently committed text as context. A
user-specific prior updates immediately after safe selections.

The implementation separates the latency-sensitive InputMethodKit process from
model inference. The input controller remains responsive while one launchd
daemon owns the 373 MB quantized model and serves generation-tagged requests
over a same-user, code-signature-validated XPC connection. BiLing deliberately
does not expose a dictionary-only operating mode: non-literal candidate
ranking always uses Qwen. When the mandatory model service is unavailable, the
panel reports the failure and preserves only the literal recovery path.

The release includes 1,440,094 unique lexical entries compiled into a 59 MB
read-only SQLite index. This provides useful vocabulary on the first
keystroke without materializing millions of Swift objects in the IME process.

## 1. System model

![BiLing architecture](Docs/architecture.svg)

The figure is a native SVG so it remains sharp in GitHub, exported PDFs, and
Retina displays. The product banner is also SVG; the live candidate interface
it depicts is implemented with AppKit text controls rather than raster assets.

The runtime has two processes:

1. **`BiLing.app`** receives key events through InputMethodKit, maintains
   marked text, queries the lexical index, displays candidates, and commits the
   selection.
2. **`biling-engined`** owns one Qwen model instance and returns contextual
   scores through XPC. A newer generation cancels the superseded request; a
   response with a stale client ID or generation is discarded.

This boundary avoids loading model weights in every client session and keeps
model initialization outside the synchronous key-event handler.

## 2. Candidate-generation theory

Let \(x\) be the raw Pinyin buffer, \(h\) the recently committed context, and
\(u\) the local user prior. The deterministic stage constructs a candidate set

\[
C(x) = C_{\mathrm{exact}}(x) \cup C_{\mathrm{beam}}(x)
       \cup C_{\mathrm{English}}(x) \cup \{x\}.
\]

`PinyinLattice` preserves all valid syllable boundaries rather than making one
greedy split. The backbone then combines:

- exact multi-syllable terms from the indexed lexicon;
- bounded sentence beams formed from prefix matches;
- mixed Chinese–English continuations when the input is not purely Pinyin;
- learned terms from the encrypted local store; and
- the raw literal, which is always recoverable with Return.

For a candidate \(c\), BiLing applies a hybrid score of the form

\[
S(c \mid x,h,u) =
B_{\mathrm{lex}}(c,x)
+ \lambda L_{\mathrm{Qwen}}(c \mid h)
+ \mu U(c \mid u)
+ \beta_{\mathrm{exact}}.
\]

\(B_{\mathrm{lex}}\) incorporates lexical frequency, word length, and lattice
coverage. \(L_{\mathrm{Qwen}}\) is the local model score. \(U\) is a
tick-decayed selection prior with a soft penalty for candidates repeatedly
shown and skipped. The exact-phrase term prevents a valid, high-confidence
word from being buried by a plausible character-by-character segmentation.
For example, the release test requires `jilindaxue → 吉林大学` at rank 1 before
any personal learning.

Qwen scores the first latency-critical page in a shared-prefix batch. It is a
ranker, not a free-form generator: the lexical/lattice stage defines valid
output candidates, and the language model decides which candidate best fits
the context.

## 3. Lexicon

BiLing ships a compiled vocabulary assembled from:

- Wanxiang Pinyin's maintained `dicts/jichu.dict.yaml` main lexicon;
- the Apache-2.0 Rime `pinyin-simp` vocabulary; and
- the literal and mixed-language candidates produced by the runtime.

Wanxiang Pinyin is pinned to commit
`1daf1e973001271331517fef3fb86eceb7e69afd`. Its tone-marked readings are
normalized to ASCII Pinyin (`lǜ sè → lv se`), duplicate `(pinyin, text)` pairs
are merged, and source weights are retained. The original source file,
upstream CC BY 4.0 license, pinned commit, and transformation notice are under
`Resources/Lexicon/`. Those notices are also copied into the installed app.

The generated database is checked into the backbone resources, so users never
run the compiler. Maintainers can reproduce it with:

```bash
python3 scripts/build_dictionary.py \
  --source Resources/Lexicon/pinyin_simp.dict.yaml:1.25 \
  --source Resources/Lexicon/wanxiang-jichu.dict.yaml:4.0 \
  --output Sources/BackboneEngine/Resources/lexicon.sqlite3
```

The database uses a `(pinyin, text)` primary key and opens read-only with
SQLite's full-mutex mode. Exact lookup is indexed by the Pinyin key; sentence
construction queries only prefixes reachable from the current lattice
position.

## 4. Model and inference

The mandatory model is `Qwen3-0.6B-Base`, quantized as Q4_K_M:

| Property | Value |
|---|---|
| Parameters | 596.05 million |
| File | `qwen3-0.6b-base-q4_k_m.gguf` |
| Size | 396,704,512 bytes |
| SHA-256 | `218d3f063193b40008d4e63d90cf83e7dc6d33a8c6c1c647589f868a8fc74492` |
| Runtime | llama.cpp with Metal |
| License | Apache License 2.0 |

The installer rejects a missing, truncated, or digest-mismatched model.
Inference happens in a launchd agent so all input-controller sessions share
one set of weights. The client automatically recreates an invalidated XPC
connection after a daemon restart.

In the included reproducibility case on an Apple M5, warm candidate scoring
for `jilindaxue` took 137.9 ms and ranked **吉林大学** first. This is an
observed development measurement, not a hardware-independent latency claim.

## 5. Installation

### 5.1 Prebuilt release

The prebuilt release requires macOS 26 on Apple silicon. Download and extract
`BiLing-1.2.0-online-installer-macOS-arm64.zip`, then Control-click
**在线安装笔灵.command** and choose Open. It contains the app, Metal backends,
compiled lexicon, and a no-build installer. The script downloads the model from
the repository's pinned Git LFS commit and verifies the exact 396,704,512-byte
file before installation; inference remains entirely offline.

This release is ad-hoc signed because the build account has no Apple Developer
ID certificate, so it is not notarized. If macOS displays a developer
verification message, review the app name and download source in System
Settings → Privacy & Security and choose Open Anyway. BiLing never asks users
to disable Gatekeeper.

### 5.2 Source requirements

- macOS 26 on Apple silicon
- Xcode 26 command-line tools and Swift 6.3 or newer
- Homebrew packages `llama.cpp`, `ggml`, and `libomp` at build time
- Git LFS

The installed app is self-contained: it copies the model, llama/ggml
libraries, Metal backends, compiled lexicon, and third-party notices into
`BiLing.app`. Homebrew is not required after installation.

### 5.3 Install from source

```bash
cd /path/to/BiLing
./scripts/install.sh
```

The script:

1. verifies the bundled model size and SHA-256;
2. builds the app, engine daemon, and diagnostic CLI in release mode;
3. assembles and ad-hoc signs `BiLing.app`;
4. runs a time-bounded release gate for IMKServer startup, event routing, the
   compiled lexicon, and candidate-panel labels and geometry;
5. preserves the previous app under
   `~/Library/Application Support/BiLing/Backups`;
6. installs to `~/Library/Input Methods/BiLing.app`;
7. installs and starts login agents for both the input method and Qwen;
8. verifies the installed Qwen/XPC path with `jilindaxue → 吉林大学`;
9. verifies that the actual installed input-method process can reach Qwen; and
10. registers BiLing as a non-Latin Simplified Chinese source, then restores
    the input source that was active before installation.

If the input-source menu does not refresh after the first installation, log
out and back in once. This is a macOS input-source cache behavior.

## 6. First use

1. Choose **笔灵** from the input menu in the macOS menu bar.
2. Focus a normal text field.
3. Type `jilindaxue`.
4. Confirm that **1 吉林大学** appears in the candidate panel.
5. Press Space to commit it.

The candidate panel reports one of three model states:

- `Qwen · 排序中` while a generation is in flight;
- `Qwen · N ms` after successful ranking; or
- `Qwen · 暂不可用` when the mandatory model service cannot rank.

Open preferences with:

```bash
open "$HOME/Library/Input Methods/BiLing.app" --args --preferences
```

Preferences control CJK/Latin auto-spacing, full-width Chinese punctuation,
and immediate local learning. The learning pane shows what BiLing has retained
and can erase it in one operation.

### Keyboard controls

| Input | Action |
|---|---|
| `a`–`z`, `'` | Extend the Pinyin composition |
| Space | Commit the highlighted candidate |
| `1`–`9` | Commit a numbered candidate |
| Left / Right | Move the highlight |
| Up / Down | Change candidate page |
| Return | Commit the raw literal buffer |
| Escape | Cancel the composition |
| Command/Control/Option shortcut | Commit literal text, then pass the shortcut through |

### Chinese/English key and Caps Lock

macOS uses the same Latin/non-Latin mechanism for the dedicated 中/英 key and
the configurable Caps Lock switch. BiLing 1.2.0 identifies itself as
`smSimpChinese` with `TISInputSourceIsASCIICapable = false`; it is no longer
mistaken for an English-side target. With BiLing as the primary Simplified
Chinese mode, the intended transitions are Apple Pinyin → English,
English → BiLing, and BiLing → English.

Enable “Use the Caps Lock key to switch to and from the last used Latin input
source” under System Settings → Keyboard → Text Input → Edit. Chinese
keyboards with a 中/英 key use the same setting.

## 7. Learning and privacy

Selection learning is local and inspectable. Each eligible commit updates an
AES-GCM-encrypted SQLite store; the encryption key is generated with
`SecRandomCopyBytes` and held in Keychain. The store is excluded from system
backup.

BiLing suppresses learning when Secure Event Input is active and in terminals,
password managers, Keychain-like clients, long numeric runs, URLs, email-like
text, and high-entropy literal strings. Literal candidates are never learned.
No raw keystroke stream is exported, and the project has no network inference
path.

The XPC daemon accepts a connection only when the peer:

- has the same effective user ID;
- runs from the expected installed app path; and
- passes macOS code-signature validation.

## 8. Candidate-window and input lifecycle

BiLing uses the unpacked InputMethodKit callback
`inputText(_:key:modifiers:client:)` as its single event path. Mixing that
callback with `handleEvent` or the simpler key-binding callback can produce
ambiguous dispatch on current macOS releases.

Candidate labels are AppKit `NSTextField` controls inside a non-activating
`NSPanel`, not custom text painted into `NSVisualEffectView.draw(_:)`. This
avoids the empty translucent bar caused by a visual-effect view consuming the
draw pass before candidate glyphs were painted. A clipped viewport preserves
full-width CJK labels while keeping page and Qwen status visible.

![Rendered BiLing candidate panel](Docs/candidate-panel.png)

The input controller invalidates obsolete generations on commit, cancel,
deactivation, and teardown. It also validates the `IMKTextInput` sender before
calling marked-text APIs.

## 9. Verification

Run the complete pure and integration-oriented test suite:

```bash
swift test
```

The current suite covers lattice ambiguity, apostrophe boundaries,
heteronyms, mixed-language classification, literal recovery, immediate
learning, privacy guards, all principal key routes, the 1.4M-entry release
floor, tone-mark normalization, and the `吉林大学` rank-1 regression.

Exercise the bundled Qwen model directly:

```bash
.build/release/biling-cli \
  --model Models/qwen3-0.6b-base-q4_k_m.gguf \
  jilindaxue
```

Render the actual candidate panel to PNG for visual regression inspection:

```bash
.build/debug/BiLingApp \
  --render-candidate-panel /tmp/biling-candidate-panel.png
```

Inspect lifecycle logs:

```bash
log show --last 10m \
  --predicate 'subsystem == "com.biling.inputmethod.BiLing"' \
  --style compact
```

## 10. Troubleshooting

### Nothing appears after selecting BiLing

Re-run `./scripts/install.sh`. Version 1.2.0 includes the InputMethodKit crash
fix and now requires both a CLI XPC test and an installed-app Qwen health check
before installation can succeed. The installer will abort
if server startup, routing, lexicon, UI layout, or Qwen/XPC
ranking fails. If macOS still holds the old input-source cache, log out and
back in once.

### A wide empty candidate bar appears

Install version 1.1.0 or newer. The candidate row now uses native text controls
and is covered by a layout smoke test plus a renderable snapshot command.

### Qwen keeps starting or recovering

```bash
launchctl print "gui/$(id -u)/com.biling.inputmethod.engine"
launchctl print "gui/$(id -u)/com.biling.inputmethod.app"
tail -n 100 "$HOME/Library/Application Support/BiLing/engine.log"
```

Both processes start at login and are kept alive by launchd. The client runs a
15-second health check and reconnects with bounded exponential backoff after an
interruption. A damaged model cannot be installed because the installer
validates its digest.

### The Chinese/English key always selects BiLing

Install 1.2.0 and log out once if macOS retained old input-source metadata.
The release registration gate rejects any BiLing build that the system reports
as ASCII-capable.

## 11. Project organization

```text
BiLing/
├── Models/                         bundled Qwen GGUF + license
├── Resources/
│   ├── App/Info.plist              InputMethodKit registration
│   ├── Lexicon/                    attributed source dictionaries
│   └── LaunchAgents/               input-method + model login templates
├── Sources/
│   ├── PinyinLattice/              incremental segmentation
│   ├── BackboneEngine/             indexed lexicon + encrypted learning
│   ├── InputSessionCore/           pure key-event router
│   ├── IPCProtocol/                generation-tagged XPC contract
│   ├── LLMRanker/                  llama.cpp Qwen scorer
│   ├── BiLingEngine/               validated XPC service
│   ├── BiLingApp/                  controller, panel, preferences
│   └── BiLingCLI/                  model diagnostic
├── Tests/
└── scripts/
    ├── build_dictionary.py
    ├── install.sh
    ├── install_online.sh
    ├── install_prebuilt.sh
    ├── package_online_release.sh
    ├── package_release.sh
    ├── register.swift
    └── uninstall.sh
```

## 12. Uninstall

```bash
./scripts/uninstall.sh
```

The uninstaller moves the app and both launch agents to Trash. It leaves personal
learning data in place so removal remains recoverable.

## 13. Sources and third-party notices

- [Qwen3-0.6B-Base](https://huggingface.co/Qwen/Qwen3-0.6B-Base), Apache-2.0
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Wanxiang Pinyin](https://github.com/amzxyz/rime_wanxiang), CC BY 4.0
- [Rime pinyin-simp](https://github.com/rime/rime-pinyin-simp), Apache-2.0
- [Apple InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)

Exact license texts and attribution metadata are included with the relevant
sources and in the installed app's `Contents/Resources/Licenses` directory.
