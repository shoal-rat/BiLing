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

print "Training LoRA for $iters iterations on $lines lines…"
# The Hub's Xet transfer backend fails intermittently behind some networks;
# the classic resumable HTTP path is slower but dependable.
export HF_HUB_DISABLE_XET=1
"$python" -m mlx_lm lora \
  --model Qwen/Qwen3-0.6B-Base \
  --train \
  --data "$data_dir" \
  --adapter-path "$work/adapter" \
  --batch-size 1 \
  --num-layers 8 \
  --iters "$iters" \
  --learning-rate 1e-5

print "Fusing the adapter and exporting GGUF…"
"$python" -m mlx_lm fuse \
  --model Qwen/Qwen3-0.6B-Base \
  --adapter-path "$work/adapter" \
  --save-path "$work/fused" \
  --export-gguf \
  --gguf-path "$work/personal-f16.gguf"
fused_gguf="$work/personal-f16.gguf"
if [[ ! -f "$fused_gguf" ]]; then
  # Older mlx-lm writes the GGUF inside --save-path instead.
  fused_gguf=$(ls "$work/fused"/*.gguf 2>/dev/null | head -1 || true)
fi
if [[ -z "$fused_gguf" || ! -f "$fused_gguf" ]]; then
  print -u2 "mlx-lm did not produce a GGUF; check the fuse output above."
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
