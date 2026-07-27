# 笔灵 BiLing 1.4.0

两个新能力：简拼，和本地 LoRA 个性化。

## 简拼与缩写

- 整串首字母直接出词：`jldx` → 吉林大学，`zgrm` → 中国人民；
- 全拼加首字母混合拼句：`beijinghy` → 北京还有；
- 字母串本身是合法全拼时全拼优先，`fan` → 饭 不受影响；
- 词库升级为格式 2（新增声母索引，111 MB，改经 Git LFS 分发），
  安装器照常自动处理。

## LoRA 个性化（进阶，可选）

```bash
./scripts/train_lora.sh
```

一条命令：导出你的选择记录 → 本机 mlx-lm 微调 Qwen3-0.6B-Base →
融合导出 GGUF → 量化 Q4_K_M → 装载。守护进程下一次加载自动改用
个人模型，状态行标注"个人模型"；删除
`~/Library/Application Support/BiLing/adapters/qwen-personal-q4_k_m.gguf`
即回退。推理层同时支持标准 GGUF LoRA 适配器（`BILING_LORA_PATH`）。
首次运行下载基座模型约 1.2 GB（仅一次），训练在 M 系列上几分钟。

## 其他

- `biling-cli` 新增 `--export-training-data` 与 `--adapter`；
- 以拼音为主、尾部带声母的输入不再被误判为英文；
- 25 项测试通过；安装门槛不变
  （`jilindaxuelajixuexiao → 吉林大学垃圾学校`）。
