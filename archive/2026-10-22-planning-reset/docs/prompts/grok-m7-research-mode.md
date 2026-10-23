# 给 Grok 的实现提示词：Expert Chat M7 隐藏科研模式

你是一名资深 Flutter / Dart 工程师。请直接在当前仓库中实现 **M7 隐藏科研模式（SSH + tmux + AI 命令审批）**，不要只给方案或示例代码。

仓库：

```text
E:\wweiyi\Project\Software\expert_chat
```

开始前必须完整阅读：

```text
PROJECT_PLAN.md
```

以其中的 **“M7 — 隐藏科研模式（SSH + tmux + AI 命令审批）”** 为唯一产品规格。然后重点检查这些现有文件，沿用现有架构和设计系统：

```text
lib/features/shell/app_shell.dart
lib/features/shell/shell_tab.dart
lib/features/settings/settings_page.dart
lib/state/settings_controller.dart
lib/core/theme.dart
lib/core/providers.dart
lib/core/workspace_layout.dart
pubspec.yaml
test/
```

`remote_lab_ui/` 只是交互和视觉参考，不是正式实现目标。不要把 React/HTML 代码搬进 Flutter，也不要创建独立品牌“Remote Lab”。

## 不可改变的产品规则

1. 科研模式默认关闭。
2. 关闭时，手机底栏和桌面侧栏都只有“会话 / 创作 / 设置”，任何普通页面都不能出现终端入口。
3. 开关只放在“设置 → 能力 → 实验功能 → 科研模式”。
4. 开启后导航才动态增加“终端”，但不能自动连接服务器。
5. 关闭时必须释放科研模式状态；如有活动 SSH 连接，先向用户确认。当前若在终端页，安全切回设置页。
6. Flutter Web 不支持原生 TCP SSH：Web 端开关必须禁用或隐藏，并使用条件导入保证 Web 能编译。
7. AI 只能生成 `CommandProposal`，不能直接写 SSH。用户逐次查看、可编辑、最终确认后，才能创建 `ApprovedCommand` 并执行。
8. 不允许添加“总是允许”“本会话自动执行”或后台 autonomous loop。
9. 首版不做 SFTP 文件传输、Slurm 专用面板、实验记录、端口转发和多主机并行。

## 实现顺序

请按 M7-A → M7-E 顺序完成，每一阶段都保持项目可分析、可测试、可构建。

### M7-A：隐藏开关和动态导航

- 给 `SettingsState` 增加 `researchModeEnabled`，默认 `false`，使用 `shared_preferences` 持久化。
- 给 `SettingsController` 增加单一职责的 setter。
- 在 `_SettingsCategory.capabilities` 底部增加“实验功能”卡片，完全复用现有 `AppTheme` 和 Material 3 组件。
- 把 `shellTabIndexProvider` 从整数改为语义化：

```dart
enum ShellTab { chat, terminal, studio, settings }
```

- `AppShell` 根据开关生成 visible tabs。不要在业务代码中继续使用 0/1/2/3 magic index。
- 更新全部调用方和测试。
- 在终端页面尚未完成前，可使用与正式页面同名的最小占位页，但 M7-B 完成后必须移除占位内容。

### M7-B：SSH 终端

优先采用：

```yaml
dartssh2: ^2.22.3
xterm: ^4.0.0
```

先检查它们与当前 Flutter 3.44 / Dart 3.12 及锁文件的兼容性；如果解析到兼容的新补丁版本可以接受，不得换成仅支持 Android/iOS 的旧 `ssh2` 包。

建立清晰边界：

```text
SshProfile（无 secret）
ResearchSshClient（SSH/PTY/shell/resize/lifecycle）
ResearchTerminalController（Riverpod 状态）
ResearchTerminalPage（UI）
```

- 原生端支持密码和 OpenSSH 私钥认证。
- 密码、私钥正文、私钥口令只存 `flutter_secure_storage`，不得写日志、SharedPreferences、Drift 或异常字符串。
- 首次连接展示 host key fingerprint 并要求用户信任；已保存 fingerprint 变化时阻断连接。
- 设置连接/认证超时。
- 使用 SSH PTY shell，把远端 stdout/stderr 写入 xterm，把 xterm `onOutput` 写入 shell。
- UI resize 时同步远端 PTY 列/行。
- dispose、断开和关闭科研模式时，关闭 client/session/subscription。
- 使用条件导入提供 Web unsupported stub，`flutter build web` 必须通过。

### M7-C：tmux 和移动端 UI

- UI 必须继续属于 Expert Chat：米白/墨青外壳，只有终端画布为深色；禁止全局黑绿霓虹。
- 手机：
  - AppBar：科研终端、当前主机、连接状态；
  - 会话条：当前 tmux、`+`、`tmux N`；
  - 主体：xterm；
  - 快捷键：Ctrl、Esc、Tab、管道符、波浪号、方向键；
  - 右下角：AI 分析；
  - 底部仍是 AppShell 主导航。
- 宽屏：左终端、右 AI 面板；沿用 `WorkspaceBreakpoints`。
- tmux list/new/attach 必须按计划书命令和严格 shell quoting 实现。
- tmux 未安装、无会话、SSH 已断开时都要有明确空状态。

### M7-D：AI 分析和人工审批

实现：

```text
TerminalTranscriptBuffer
ResearchCopilotService
CommandProposal
CommandRisk
ApprovedCommand
ApprovedCommandExecutor
```

- transcript 使用行数和字节双上限，移除 ANSI/control chars。
- 默认只选最近 36 行，并允许用户预览即将发送的文本。
- 本地遮盖 API key、Bearer token、密码赋值和 PEM 私钥块。
- 复用现有 active LLM Provider；不要再做一套模型/API Key 设置。
- 科研 system prompt 要求结构化 JSON；解析失败时只展示文本，不能显示执行按钮。
- 最终风险为模型风险与本地风险分类中的较高者。
- 编辑命令后重新计算本地风险。
- 最终确认必须展示：主机、cwd、完整命令、风险和影响。
- 审批与 `hostId + connectionGeneration + proposalId` 绑定。切主机、重连、断线、离开页面、关闭弹窗后，旧审批必须失效。
- 从类型和依赖层面保证 `CommandProposal` 不能直接传给 SSH 写入方法。

### M7-E：测试和收尾

至少补齐：

- Settings 默认 false、持久化和旧设置迁移测试。
- 导航隐藏/显示、选中映射、关闭时从 terminal 回退测试。
- Web unsupported 分支测试或构建检查。
- SSH controller 使用 fake transport 测试连接、输出、resize、dispose。
- tmux 输出解析和 session name quoting 测试。
- transcript 内存上限、ANSI 清理和 secret redaction 测试。
- proposal JSON 解析失败时无执行按钮。
- 未审批无法执行、编辑后重算风险、连接 generation 变化使审批失效。
- 手机关键布局 Widget 测试，避免底部 Sheet 和导航溢出。

## 工程约束

- 使用 Riverpod 3.x 现有写法；不要引入另一套状态管理。
- 保留当前工作区中与本任务无关的用户改动。
- 优先小文件和可测试的 domain abstraction，避免把 SSH、AI、风险判断全部塞进一个 Widget/Controller。
- 不修改现有聊天、创作、联网、图片生成等功能行为。
- 不把终端完整日志写入聊天数据库。
- 不在生产代码放演示主机、测试密码或真实凭证。
- 不使用字符串拼接处理不可信 tmux session name；必须集中实现 shell quoting。
- 所有错误面向用户时做脱敏，不展示 secret、私钥内容或底层堆栈。

## 完成前必须执行

```text
dart format .
flutter analyze
flutter test
flutter build windows --debug
flutter build web
```

如果当前机器不具备某个平台构建条件，明确说明跳过原因，但不要用“无法实机 SSH”作为跳过 domain/widget 测试的理由；使用 fake transport。

最终回答必须包含：

1. 已完成的 M7-A～M7-E 项目；
2. 主要文件清单；
3. 测试和构建结果；
4. 尚未验证的真实设备/SSH 场景；
5. 明确确认没有实现 SFTP、Slurm 面板、实验记录和自动执行。
