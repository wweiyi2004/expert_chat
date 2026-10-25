# TUI 实施日志

## 2026-10-26 · 阶段 0

- 用户确认 1A/2A/3A/4A/5A/6A，决策见 ARCHITECTURE.md。
- 开工 git status --short 为空；从 codex/v3.6.1-ui-directory 新建 feat/tui；没有已有脏文件需要隔离。
- 已阅读 AGENT-PROMPT、TUI-SPEC 全文、HTML 参考/宠物 JSON、执行端 README，检查控制器各模块及 work providers 的接入边界。执行端 README 过时，不用于当前能力断言。
- 现有 Flutter 全套基线已启动，输出 output/tui-build/flutter-baseline.log；结果待完成。尚未进行真实模型请求（0/30）。
- 协议与状态映射已写入 PROTOCOL.md / ARCHITECTURE.md；schema 和 fixtures 正在建立。
- 尚未实现，不代表验收通过；所有平台/终端验证按实际结果记录。

## 范围说明

- 允许必要共享后端扩展来自本轮用户 4A；main.dart 和 native runner 的最小启动改动来自 2A。
- 后续需修改 next/Cargo.toml/Cargo.lock（crate+依赖）、session_policy/controller/approval/steering（新增能力）、测试和文档。保持现有设置默认、权限规则和独立会话不变。
- 本轮允许按任务文件逐项提交，不 push，不改写历史。子代理不自行提交，审查由 root 完成后提交。

## 验收进度

未开始：Rust build/test/clippy、Dart analyze/新增测试/回归、80/60/40×24 快照、7 步真实桥接端到端、单实例后台启动、demo 全状态、终端主题/ASCII/键位/宠物。

## 真实模型调用记录

0 次。只允许端到端冒烟使用，累计最多 30 次，独立临时工作区、请求批准模式；不修改现有会话和设置。
