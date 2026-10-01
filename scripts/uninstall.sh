#!/bin/zsh
# Removes 知音: disables the input source and moves the app to the Trash.
# 默契 (your learned choices) stays in ~/Library/Application Support/Zhiyin
# unless you pass --forget; its sealing key stays in the Keychain likewise.
set -euo pipefail
app="$HOME/Library/Input Methods/Zhiyin.app"
[[ -x "$app/Contents/MacOS/Zhiyin" ]] && "$app/Contents/MacOS/Zhiyin" --disable || true
killall Zhiyin 2>/dev/null || true
if [[ -e "$app" ]]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$app\"" >/dev/null && print "Moved Zhiyin.app to the Trash."
fi
if [[ "${1:-}" == "--forget" ]]; then
  rm -rf "$HOME/Library/Application Support/Zhiyin"
  security delete-generic-password -s com.zhiyin.inputmethod.moqi >/dev/null 2>&1 || true
  print "默契 forgotten."
fi
