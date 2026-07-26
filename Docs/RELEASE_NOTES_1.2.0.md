# 笔灵 BiLing 1.2.0

让 144 万词汇与本地 Qwen 在原生 macOS 输入链路中协同工作。

## 本次发布

- 修复 Qwen 长期显示不可用：输入法与模型均登录启动、launchd 保活，客户端
  定时健康检查并自动重连。
- 修复“中/英”键总是切到笔灵：输入源现在是非拉丁 `smSimpChinese`，
  不再被 macOS 误认为英文侧输入源。
- 安装器同时验证 CLI XPC 和实际输入法进程的 Qwen 连接。
- 提供包含模型、Metal 后端、144 万词库与一键安装脚本的 Apple silicon
  预构建包。
- README 默认中文，并提供完整英文版本、论文式理论说明与双语 SVG 图。

## 安装

下载 `BiLing-1.2.0-macOS-arm64.zip`，解压后右键“安装笔灵.command”，选择
“打开”。要求 Apple silicon 与 macOS 26 或更新版本。

本构建使用 ad-hoc 代码签名，未经过 Apple 公证。遇到开发者验证提示时，请在
“系统设置 → 隐私与安全性”核对来源后选择“仍要打开”；无需关闭 Gatekeeper。

## 验证

- 19 项 Swift 测试通过；
- 1,440,094 条词汇发布下限通过；
- `jilindaxue → 吉林大学` 第一候选通过；
- Qwen 进程故障注入后由 launchd 自动换 PID 重启并恢复排序；
- ZIP 解压、严格验签、预构建安装、双 LaunchAgent 与输入源注册闭环通过。

---

BiLing 1.2.0 fixes persistent Qwen-unavailable states with login startup,
launchd keep-alive, periodic health checks, and automatic XPC reconnection. It
also registers BiLing as a non-Latin `smSimpChinese` source, restoring the
intended macOS Chinese/English key behavior. The prebuilt Apple-silicon archive
contains the model, Metal backends, 1.44-million-entry lexicon, and a no-build
installer.
