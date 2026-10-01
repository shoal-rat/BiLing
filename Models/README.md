# 子期的模型

`ziqi.gguf` — 子期，知音的听者。由 [Qwen3-0.6B-Base](https://huggingface.co/Qwen/Qwen3-0.6B-Base)
（Apache-2.0）经 LoRA 微调、合并后量化为 Q4_K_M 的 GGUF。

它学的只有一件事：读前文和原始按键，写出你要的字。提示格式见
`Tools/zhuoqin/fmt.py`：

    [前文] <|fim_prefix|> 按 键 字 母 … <|fim_middle|> [目标文字] <|endoftext|>

每个按键是一个单字母 token，于是每敲一个键只追加一个 token，之前的 KV 缓存全部复用。

重新训练与导出（需要 MLX、约 3 小时，M5 / 16 GB）：

    python Tools/zhuoqin/make_dataset.py --out work/data_v2 --per-source 160000
    python Tools/zhuoqin/make_xinci.py   --out work/data_xinci
    python Tools/zhuoqin/train.py --data work/data_v2 --out work/runs/r2
    python Tools/zhuoqin/export.py work/runs/r2 --out Models/ziqi.gguf

模型文件较大，不进 git 历史；发布包里自带，或用上面的流程自己斫一把。
