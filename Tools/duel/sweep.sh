#!/bin/zsh
# Tune 子期's decoding on the duel *dev* split only; the test split is never
# used for choosing anything. Prints one line per configuration.
set -euo pipefail
root=${0:A:h:h:h}
bin="$root/.build/release/tiaoyin"
dev="${DEV:-$root/Tests/Corpus/duel-dev.tsv}"
model="${MODEL:-$root/Models/ziqi-base.gguf}"
adapter="${ADAPTER:-$root/Models/ziqi-tingyin.gguf}"
run() {
  local label="$1"; shift
  local line=$("$bin" eval "$dev" --model "$model" --adapter "$adapter" "$@" 2>/dev/null | grep "^all")
  print "$label | $line"
}
run "default"
run "zhi0.4" --zhi 0.4
run "zhi0.8" --zhi 0.8
run "zhi1.0" --zhi 1.0
run "beam6" --beam 6
run "beam14" --beam 14
run "abbr0.5" --abbr-cost 0.5
run "abbr1.8" --abbr-cost 1.8
run "perkey0.6" --per-key 0.6
run "perkey1.4" --per-key 1.4
run "slip3" --slip-cost 3
run "slip8" --slip-cost 8
run "norescue" --no-rescue
run "zhionly" --adapter none
run "tingonly" --zhi 0
