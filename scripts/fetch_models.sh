#!/bin/zsh
# Fetches 子期's two files from the GitHub release and checks them:
#   Models/ziqi-base.gguf     Qwen3-0.6B-Base, Q4_K_M (知意; also the base for 听音)
#   Models/ziqi-tingyin.gguf  the 听音 LoRA adapter
set -euo pipefail
root=${0:A:h:h}
release="https://github.com/shoal-rat/BiLing/releases/download/zhiyin-1.0.0"
# local name -> released asset (the 听音 adapter is versioned per training round)
typeset -A assets
assets[ziqi-base.gguf]="ziqi-base-q4_k_m.gguf"
assets[ziqi-tingyin.gguf]="ziqi-tingyin-r2.gguf"
typeset -A sums
sums[ziqi-base.gguf]="c284b39c605d79b74f50229c6a9056610cd48fb3c55239f8efb9f70610061c06"
sums[ziqi-tingyin.gguf]="bde9f0f0df0c0d4159601d7feac5405930fd2be9983fc9356ad8dc02af559b4f"
mkdir -p "$root/Models"
for name in ziqi-base.gguf ziqi-tingyin.gguf; do
  target="$root/Models/$name"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "${sums[$name]}" ]]; then
    print "$name: already here, checksum ok"
    continue
  fi
  print "downloading $name …"
  curl -fL --progress-bar -o "$target.part" "$release/${assets[$name]}"
  actual=$(shasum -a 256 "$target.part" | awk '{print $1}')
  if [[ "$actual" != "${sums[$name]}" ]]; then
    rm -f "$target.part"
    print -u2 "$name: checksum mismatch (got $actual)"
    exit 78
  fi
  mv "$target.part" "$target"
  print "$name: ok"
done
