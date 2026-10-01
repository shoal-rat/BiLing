#!/bin/zsh
# Installs 知音 into ~/Library/Input Methods, transactionally.
#
# The new bundle is staged and smoke-tested before anything installed is
# touched; the previous installation is kept aside until the new one has
# registered, and restored if any later step fails.
#
#   scripts/install.sh            build, stage, test, install, register
#   ZHIYIN_SKIP_BUILD=1 …         reuse the existing release build
#   ZHIYIN_BASE=path.gguf …       a different base model (知意)
#   ZHIYIN_ADAPTER=path.gguf …    a different 听音 adapter
set -euo pipefail

root=${0:A:h:h}
bundle_name="知音.app"
dest_dir="$HOME/Library/Input Methods"
dest="$dest_dir/$bundle_name"
backup="$dest.previous"
base_model="${ZHIYIN_BASE:-$root/Models/ziqi-base.gguf}"
adapter="${ZHIYIN_ADAPTER:-$root/Models/ziqi-tingyin.gguf}"
data="$root/Resources/Data"

for f in "$base_model" "$adapter" "$data/qinpu.trie" "$data/ziqi-vocab.trie" "$data/char_readings.json"; do
  [[ -f "$f" ]] || { print -u2 "missing: $f"; exit 78; }
done
for lib in /opt/homebrew/opt/llama.cpp/lib/libllama.0.dylib /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
           /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib /opt/homebrew/opt/libomp/lib/libomp.dylib; do
  [[ -f "$lib" ]] || { print -u2 "missing $lib — brew install llama.cpp ggml libomp"; exit 69; }
done

if [[ -z "${ZHIYIN_SKIP_BUILD:-}" ]]; then
  swift build --package-path "$root" -c release --product Zhiyin
  swift build --package-path "$root" -c release --product tiaoyin
fi
bin=$(swift build --package-path "$root" -c release --show-bin-path)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/$bundle_name"
c="$app/Contents"
mkdir -p "$c/MacOS" "$c/Frameworks" "$c/Resources/Data" "$c/Resources/Models" "$c/Resources/Licenses"

ditto "$root/Resources/App/Info.plist" "$c/Info.plist"
ditto "$root/Resources/App/zh-Hans.lproj" "$c/Resources/zh-Hans.lproj"
ditto "$root/Resources/App/en.lproj" "$c/Resources/en.lproj"
ditto "$bin/Zhiyin" "$c/MacOS/Zhiyin"
ditto "$bin/tiaoyin" "$c/MacOS/tiaoyin"
ditto "$root/Resources/Brand/AppIcon.icns" "$c/Resources/AppIcon.icns"
ditto "$root/Resources/Brand/MenuIcon.pdf" "$c/Resources/MenuIcon.pdf"
for f in qinpu.trie ziqi-vocab.trie char_readings.json; do ditto "$data/$f" "$c/Resources/Data/$f"; done
ditto "$base_model" "$c/Resources/Models/ziqi-base.gguf"
ditto "$adapter" "$c/Resources/Models/ziqi-tingyin.gguf"
ditto "$root/LICENSE" "$c/Resources/Licenses/LICENSE-ZHIYIN.txt"
for f in "$root"/Resources/Licenses/*(N); do ditto "$f" "$c/Resources/Licenses/${f:t}"; done

# llama.cpp and ggml travel inside the bundle. ggml looks for its GPU/CPU
# backends next to the executable, so they live in MacOS/.
ditto /opt/homebrew/opt/llama.cpp/lib/libllama.0.dylib "$c/Frameworks/libllama.0.dylib"
ditto /opt/homebrew/opt/ggml/lib/libggml.0.dylib "$c/Frameworks/libggml.0.dylib"
ditto /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib "$c/Frameworks/libggml-base.0.dylib"
ditto /opt/homebrew/opt/libomp/lib/libomp.dylib "$c/Frameworks/libomp.dylib"
for so in /opt/homebrew/opt/ggml/libexec/libggml-*.so; do ditto "$so" "$c/MacOS/${so:t}"; done
chmod -R u+w "$c"

relink() { install_name_tool "$@" 2>/dev/null || true; }
for exe in "$c/MacOS/Zhiyin" "$c/MacOS/tiaoyin"; do
  relink -change /opt/homebrew/opt/llama.cpp/lib/libllama.0.dylib @rpath/libllama.0.dylib "$exe"
  relink -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib "$exe"
  relink -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib "$exe"
  relink -delete_rpath /opt/homebrew/opt/llama.cpp/lib "$exe"
  relink -delete_rpath /opt/homebrew/opt/ggml/lib "$exe"
done
relink -id @rpath/libllama.0.dylib "$c/Frameworks/libllama.0.dylib"
relink -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib "$c/Frameworks/libllama.0.dylib"
relink -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib "$c/Frameworks/libllama.0.dylib"
relink -id @rpath/libggml.0.dylib "$c/Frameworks/libggml.0.dylib"
relink -id @rpath/libggml-base.0.dylib "$c/Frameworks/libggml-base.0.dylib"
relink -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib "$c/Frameworks/libggml-base.0.dylib"
relink -id @rpath/libomp.dylib "$c/Frameworks/libomp.dylib"
for lib in "$c"/Frameworks/*.dylib; do relink -add_rpath @loader_path "$lib"; done
for so in "$c"/MacOS/*.so; do
  relink -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib "$so"
  relink -add_rpath @loader_path/../Frameworks "$so"
done

codesign --force --deep --sign - "$app" >/dev/null
codesign --verify --deep --strict "$app"

# Nothing in the bundle may still point into Homebrew.
if otool -L "$c"/MacOS/* "$c"/Frameworks/* 2>/dev/null | grep -q "/opt/homebrew"; then
  print -u2 "bundle still references /opt/homebrew:"
  otool -L "$c"/MacOS/* "$c"/Frameworks/* | grep "/opt/homebrew" >&2
  exit 70
fi

print "Smoke test (琴谱 + 子期)…"
if ! /usr/bin/perl -e 'alarm 120; exec @ARGV' "$c/MacOS/Zhiyin" --smoke-test; then
  print -u2 "smoke test failed; nothing installed."
  exit 70
fi

# --- mutation: covered by rollback from here on ------------------------------
mkdir -p "$dest_dir"
installed=0
rollback() {
  if (( ! installed )); then
    rm -rf "$dest"
    [[ -e "$backup" ]] && mv "$backup" "$dest"
    print -u2 "Install failed; previous state restored."
  fi
}
trap 'rollback; rm -rf "$stage"' EXIT
killall Zhiyin 2>/dev/null || true
# Early builds installed as Zhiyin.app; never leave two copies registered.
rm -rf "$dest_dir/Zhiyin.app" "$dest_dir/Zhiyin.app.previous"
rm -rf "$backup"
[[ -e "$dest" ]] && mv "$dest" "$backup"
ditto "$app" "$dest"
if [[ -z "${ZHIYIN_NO_REGISTER:-}" ]]; then
  "$dest/Contents/MacOS/Zhiyin" --register
fi
installed=1
rm -rf "$backup"
print "知音 installed at $dest"
print "Choose 知音 from the input menu (or run: \"$dest/Contents/MacOS/Zhiyin\" --select)."
print "If it is not listed yet, log out and back in once — macOS caches input sources."
