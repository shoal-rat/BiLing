# 为笔灵贡献

[English](#contributing-in-english)

感谢你帮助改进笔灵。提交变更前，请先阅读
[README](README.md) 的系统模型、隐私边界和验证章节。

## 开发环境

```bash
git lfs install
git clone https://github.com/shoal-rat/BiLing.git
cd BiLing
brew install llama.cpp ggml libomp
swift test
```

请保持以下不变量：

- Qwen 是所有非字面候选的强制排序器，不加入“仅词典”模式；
- 按键回调不得等待模型推理；
- XPC 响应必须校验客户端 ID 与代次；
- 安全输入、密码管理器和高熵文本不得进入学习库；
- `Return` 必须始终能够恢复原始字面输入；
- 输入源必须保持 `smSimpChinese` 且不可输出 ASCII。

提交 Pull Request 时，请说明用户可见行为、验证命令、macOS/硬件版本，以及是否
影响词典、模型、隐私或 InputMethodKit 生命周期。UI 变更应附截图。

## Contributing in English

Set up Git LFS, install `llama.cpp`, `ggml`, and `libomp`, then run
`swift test`. Preserve the architectural invariants listed above. A pull
request should describe its user-visible behavior, verification commands,
macOS/hardware version, and any impact on the lexicon, model, privacy, or
InputMethodKit lifecycle. Include screenshots for UI changes.
