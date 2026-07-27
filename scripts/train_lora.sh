#!/bin/zsh
set -euo pipefail

# 用你在笔灵里的选择记录训练一个 LoRA，并生成笔灵直接加载的个人模型。
#
# 流程：导出学习记录 → mlx-lm LoRA 微调 Qwen3-0.6B-Base → 融合并导出
# GGUF → llama-quantize 到 Q4_K_M → 装入
# ~/Library/Application Support/BiLing/adapters/qwen-personal-q4_k_m.gguf。
# 守护进程在下一次（懒）加载时自动改用个人模型；删除该文件即回退。
#
# 用法:
#   ./scripts/train_lora.sh                 # 用本机学习记录训练（默认 200 步）
#   ./scripts/train_lora.sh --iters 400
#   ./scripts/train_lora.sh --data 目录     # 用自备 train.jsonl/valid.jsonl
#
# 需要: python3 + mlx-lm（脚本自动安装）、Homebrew llama.cpp（llama-quantize）、
# 首次运行会从 Hugging Face 下载 Qwen/Qwen3-0.6B-Base（约 1.2 GB，仅一次）。
# 建议接电源运行；训练在 M 系列上通常只需几分钟。

iters=200
data_dir=""
while (( $# > 0 )); do
  case "$1" in
    --iters)
      iters="$2"; shift 2 ;;
    --data)
      data_dir="$2"; shift 2 ;;
    *)
      print -u2 "Unknown option: $1"; exit 64 ;;
  esac
done

support="$HOME/Library/Application Support/BiLing"
adapters_dir="$support/adapters"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script_dir=${0:A:h}
cli="$HOME/Library/Input Methods/BiLing.app/Contents/Helpers/biling-cli"
if [[ ! -x "$cli" ]]; then
  cli="${script_dir:h}/.build/release/biling-cli"
fi
if [[ ! -x "$cli" ]]; then
  print -u2 "biling-cli not found; install BiLing or run swift build -c release first."
  exit 66
fi
if ! command -v llama-quantize >/dev/null; then
  print -u2 "llama-quantize is missing; install it with: brew install llama.cpp"
  exit 69
fi

# A private venv sidesteps PEP-668 "externally managed" system Pythons.
venv="$support/venv"
python="$venv/bin/python3"
if [[ ! -x "$python" ]]; then
  print "Creating the training venv (one-time)…"
  python3 -m venv "$venv"
fi
if ! "$python" -c "import mlx_lm" 2>/dev/null; then
  print "Installing mlx-lm into the venv (one-time)…"
  "$python" -m pip install --quiet --upgrade pip
  "$python" -m pip install --quiet mlx-lm
fi

if [[ -z "$data_dir" ]]; then
  data_dir="$work/data"
  print "Exporting learned selections (a Keychain prompt for the learning-store key is expected)…"
  "$cli" --export-training-data "$data_dir"
fi
if [[ ! -f "$data_dir/train.jsonl" ]]; then
  print -u2 "No train.jsonl in $data_dir."
  exit 66
fi
lines=$(wc -l < "$data_dir/train.jsonl" | tr -d ' ')
if (( lines < 16 )); then
  print -u2 "Only $lines training lines. Type with BiLing for a while first (selections are the data), or pass --data DIR."
  exit 65
fi

# The Hub's Xet transfer backend fails intermittently behind some networks;
# the classic resumable HTTP path is slower but dependable.
export HF_HUB_DISABLE_XET=1

# Fetch the *complete* base-model snapshot up front. mlx_lm's own loader
# pulls only weights and config, but its fuse step later demands a complete
# cached snapshot (local_files_only=True) and fails on the handful of
# metadata files it never asked for. These are a few KB.
print "Preparing the base model…"
"$python" - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("Qwen/Qwen3-0.6B-Base")
PY

print "Training LoRA for $iters iterations on $lines lines…"
"$python" -m mlx_lm lora \
  --model Qwen/Qwen3-0.6B-Base \
  --train \
  --data "$data_dir" \
  --adapter-path "$work/adapter" \
  --batch-size 1 \
  --num-layers 8 \
  --iters "$iters" \
  --learning-rate 1e-5

print "Fusing the adapter into the base weights…"
# mlx_lm's own --export-gguf only covers llama/mixtral, so fuse to
# safetensors and hand the conversion to llama.cpp's converter below.
"$python" -m mlx_lm fuse \
  --model Qwen/Qwen3-0.6B-Base \
  --adapter-path "$work/adapter" \
  --save-path "$work/fused"

# llama.cpp's converter ships with its source, not the Homebrew binary
# package, so fetch and cache it once. Pinned to b6500: the last tag where
# convert_hf_to_gguf.py is a single self-contained file that already knows
# Qwen3. Newer tags split it across a `conversion/` package that a one-file
# download cannot satisfy. GGUF is forward-compatible, so output from this
# converter loads fine in the newer llama.cpp doing inference.
tools_dir="$support/tools"
converter="$tools_dir/convert_hf_to_gguf.py"
converter_tag="b6500"
if [[ ! -f "$converter" ]]; then
  mkdir -p "$tools_dir"
  print "Fetching llama.cpp $converter_tag's GGUF converter (one-time)…"
  if ! curl -fsSL -o "$converter.tmp" \
    "https://raw.githubusercontent.com/ggml-org/llama.cpp/$converter_tag/convert_hf_to_gguf.py"; then
      print -u2 "Could not download convert_hf_to_gguf.py ($converter_tag)."
      exit 69
  fi
  mv "$converter.tmp" "$converter"
fi
# mistral_common is imported unconditionally by that converter even for
# non-Mistral models, so it is a hard requirement here.
if ! "$python" -c "import gguf, torch, mistral_common" 2>/dev/null; then
  print "Installing conversion dependencies (one-time, ~1 GB)…"
  "$python" -m pip install --quiet gguf torch mistral-common
fi

print "Converting to GGUF…"
"$python" "$converter" "$work/fused" \
  --outfile "$work/personal-f16.gguf" \
  --outtype f16
fused_gguf="$work/personal-f16.gguf"
if [[ ! -f "$fused_gguf" ]]; then
  print -u2 "Conversion did not produce a GGUF; check the output above."
  exit 70
fi

print "Quantizing to Q4_K_M…"
llama-quantize "$fused_gguf" "$work/personal-q4_k_m.gguf" Q4_K_M >/dev/null

mkdir -p "$adapters_dir"
mv "$work/personal-q4_k_m.gguf" "$adapters_dir/qwen-personal-q4_k_m.gguf"
launchctl kickstart -k "gui/$(id -u)/com.biling.inputmethod.engine" 2>/dev/null || true

print ""
print "个人模型已装载：$adapters_dir/qwen-personal-q4_k_m.gguf"
print "验证：biling-cli --xpc <拼音> 的状态行会带上“个人模型”。"
print "回退：删除上述文件，再执行 launchctl kickstart -k \"gui/$(id -u)/com.biling.inputmethod.engine\"。"
