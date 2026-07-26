# 更新记录 / Changelog

本文档遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.2.0] - 2026-07-27

### 新增

- 输入法与 Qwen 两个用户域 LaunchAgent，均在登录时启动并保持运行。
- 输入法进程级 Qwen 健康检查、15 秒周期探测与 1–15 秒指数退避重连。
- 无需构建工具的 Apple silicon 预构建发布包安装器。
- 默认中文、可切换英文的论文式 README，以及中文 SVG 横幅和架构图。
- Git LFS 模型分发、公开 CI、贡献指南、安全政策与私密漏洞报告说明。

### 修复

- 将输入源从 ASCII-capable Unicode 模式修正为非拉丁
  `smSimpChinese`，恢复 macOS“中/英”键与 Caps Lock 的系统切换语义。
- 安装器现在保留并恢复安装前使用的输入源。
- XPC interruption 不再停留在永久“Qwen 不可用”状态。

### 验证

- 19 项 Swift 测试通过。
- 1,440,094 条发布词汇通过只读 SQLite 回归门槛。
- 安装后 CLI 与真实输入法进程的 Qwen 健康检查通过。
- 故障注入后 launchd 自动换 PID 重启模型，`jilindaxue → 吉林大学` 仍排名第一。

## [1.1.0] - 2026-07-26

- 修复 InputMethodKit 启动崩溃与空白候选条。
- 候选窗改用 AppKit 原生文本控件。
- 集成万象拼音与 Rime 主词库，以及强制启用的本地 Qwen 排序器。
