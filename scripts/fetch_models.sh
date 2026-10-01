#!/bin/zsh
# Fetches 子期's two files from the GitHub release and checks them:
#   Models/ziqi-base.gguf     Qwen3-0.6B-Base, Q4_K_M (知意; also the base for 听音)
#   Models/ziqi-tingyin.gguf  the 听音 LoRA adapter
set -euo pipefail
root=${0:A:h:h}
release="https://github.com/shoal-rat/BiLing/releases/download/zhiyin-1.0.0"
typeset -A sums
sums[ziqi-base.gguf]="__BASE_SHA256__"
sums[ziqi-tingyin.gguf]="__TINGYIN_SHA256__"
mkdir -p "$root/Models"
for name in ziqi-base.gguf ziqi-tingyin.gguf; do
  target="$root/Models/$name"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "${sums[$name]}" ]]; then
    print "$name: already here, checksum ok"
    continue
  fi
  print "downloading $name …"
  curl -fL --progress-bar -o "$target.part" "$release/$name"
  actual=$(shasum -a 256 "$target.part" | awk '{print $1}')
  if [[ "$actual" != "${sums[$name]}" ]]; then
    rm -f "$target.part"
    print -u2 "$name: checksum mismatch (got $actual)"
    exit 78
  fi
  mv "$target.part" "$target"
  print "$name: ok"
done
