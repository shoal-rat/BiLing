#!/bin/bash
# Exercises install.sh's rollback path against a throwaway prefix.
#
# BILING_INSTALL_PREFIX points the installer at a temp directory (the real
# ~/Library/Input Methods is never touched; the sandboxed mode also skips
# launchd and input-source registration), and BILING_INSTALL_FAIL_AFTER_COPY=1
# makes it fail deliberately right after the app bundle copy. The test asserts
# that the previous installation is restored byte-for-byte and that no .bak or
# partial copy is left behind — and, in a second scenario, that a failed fresh
# install leaves nothing at all.
#
# Requires a machine that can run the real installer preflight (Homebrew
# llama.cpp libraries and the LFS-downloaded Qwen model), so this runs on
# developer machines, not on CI.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_installer() {
  local prefix="$1"
  local log="$2"
  BILING_INSTALL_PREFIX="$prefix" BILING_INSTALL_FAIL_AFTER_COPY=1 \
    zsh "$script_dir/install.sh" >"$log" 2>&1
}

# --- scenario 1: a previous installation exists and must be restored --------
prefix1="$sandbox/upgrade/Library"
previous="$prefix1/Input Methods/BiLing.app"
mkdir -p "$previous/Contents"
echo "previous-install-sentinel" > "$previous/Contents/sentinel.txt"

log1="$sandbox/install-upgrade.log"
if run_installer "$prefix1" "$log1"; then
  fail "installer exited 0 despite BILING_INSTALL_FAIL_AFTER_COPY=1 (see $log1)"
fi

grep -q "failing deliberately right after the copy step" "$log1" \
  || fail "the deliberate-failure hook did not fire (see $log1)"
grep -q "rolling back" "$log1" \
  || fail "the installer did not report a rollback (see $log1)"

[ -d "$previous" ] || fail "previous BiLing.app is gone after rollback"
[ -f "$previous/Contents/sentinel.txt" ] \
  || fail "previous bundle contents were not restored"
grep -q "previous-install-sentinel" "$previous/Contents/sentinel.txt" \
  || fail "sentinel content changed during rollback"
[ ! -e "$previous/Contents/MacOS" ] \
  || fail "rollback left newly-installed files inside the restored bundle"
[ ! -e "$previous.bak" ] || fail "rollback left a stale .bak behind"
if compgen -G "$prefix1/Application Support/BiLing/Backups/*" > /dev/null 2>&1; then
  fail "a failed install must not retire anything into the Backups folder"
fi
echo "scenario 1 passed: previous installation restored after mid-install failure"

# --- scenario 2: no previous installation; the partial copy must vanish -----
prefix2="$sandbox/fresh/Library"
mkdir -p "$prefix2/Input Methods"

log2="$sandbox/install-fresh.log"
if run_installer "$prefix2" "$log2"; then
  fail "installer exited 0 despite BILING_INSTALL_FAIL_AFTER_COPY=1 (see $log2)"
fi

[ ! -e "$prefix2/Input Methods/BiLing.app" ] \
  || fail "a failed fresh install left a partial BiLing.app behind"
[ ! -e "$prefix2/Input Methods/BiLing.app.bak" ] \
  || fail "a failed fresh install left a .bak behind"
echo "scenario 2 passed: failed fresh install left no partial state"

# --- scenario 3: the success path must still work and retire the .bak -------
prefix3="$sandbox/success/Library"
previous3="$prefix3/Input Methods/BiLing.app"
mkdir -p "$previous3/Contents"
echo "previous-install-sentinel" > "$previous3/Contents/sentinel.txt"

log3="$sandbox/install-success.log"
if ! BILING_INSTALL_PREFIX="$prefix3" zsh "$script_dir/install.sh" >"$log3" 2>&1; then
  fail "sandboxed install without the fail hook did not succeed (see $log3)"
fi

[ -x "$previous3/Contents/MacOS/BiLingApp" ] \
  || fail "successful install did not put the new bundle in place"
[ ! -e "$previous3.bak" ] || fail "successful install left the .bak behind"
if ! compgen -G "$prefix3/Application Support/BiLing/Backups/BiLing.previous-*.app" > /dev/null 2>&1; then
  fail "successful install did not retire the previous bundle into Backups"
fi
retired="$(compgen -G "$prefix3/Application Support/BiLing/Backups/BiLing.previous-*.app" | head -n 1)"
grep -q "previous-install-sentinel" "$retired/Contents/sentinel.txt" \
  || fail "the retired backup does not hold the previous bundle"
echo "scenario 3 passed: successful install replaced the bundle and retired the backup"

echo "installer rollback test passed"
