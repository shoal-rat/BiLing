#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
if [[ -d "$script_dir/BiLing.app" ]]; then
  release_root="$script_dir"
else
  release_root=${script_dir:h}
fi

model_name="qwen3-0.6b-base-q4_k_m.gguf"
model_path="$release_root/BiLing.app/Contents/Resources/Models/$model_name"
expected_size=396704512
expected_sha256="218d3f063193b40008d4e63d90cf83e7dc6d33a8c6c1c647589f868a8fc74492"
model_commit="d5c522d3cf6c3de81f84bc2f0f94609244fb9b32"
model_url="https://media.githubusercontent.com/media/shoal-rat/BiLing/$model_commit/Models/$model_name"
offline_installer="$release_root/安装笔灵.command"

if [[ ! -d "$release_root/BiLing.app" || ! -x "$offline_installer" ]]; then
  print -u2 "The BiLing release files are incomplete."
  exit 66
fi

model_is_valid=false
if [[ -f "$model_path" ]]; then
  model_size=$(stat -f %z "$model_path")
  if [[ "$model_size" == "$expected_size" ]]; then
    model_sha256=$(shasum -a 256 "$model_path" | awk '{print $1}')
    [[ "$model_sha256" == "$expected_sha256" ]] && model_is_valid=true
  fi
fi

if [[ "$model_is_valid" != true ]]; then
  print "正在从笔灵仓库的固定提交下载 Qwen3 模型（约 378 MiB）…"
  download_path=$(mktemp)
  trap 'rm -f "$download_path"' EXIT
  curl \
    --fail \
    --location \
    --retry 8 \
    --retry-all-errors \
    --connect-timeout 30 \
    --output "$download_path" \
    "$model_url"

  actual_size=$(stat -f %z "$download_path")
  if [[ "$actual_size" != "$expected_size" ]]; then
    print -u2 "Qwen model download is incomplete: $actual_size bytes."
    exit 78
  fi
  actual_sha256=$(shasum -a 256 "$download_path" | awk '{print $1}')
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    print -u2 "Qwen model download failed its SHA-256 integrity check."
    exit 78
  fi
  mkdir -p "${model_path:h}"
  mv "$download_path" "$model_path"
  trap - EXIT
  print "Qwen 模型校验通过。"
else
  print "已找到并校验完整的 Qwen 模型。"
fi

exec "$offline_installer"
