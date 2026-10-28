# TUI 架构决策（2026-10-26）

## 用户已确定

1A：复用桌面应用的 ChatController，不另建代理循环。2A：自动连接，必要时后台启动桌面应用，保持单实例。3A：入口 `expert`，实际程序 `expert-tui`。
4A：允许补齐必要后端能力，两端共用，不重构现有内核。5A（2026-10-28 更新）：关闭窗口结束该窗口发起的任务，其他窗口任务继续；短暂断线保留 5 秒重连窗口。6A：默认当前目录，首次使用需确认路径和权限，已登记项目沿用权限。

## 当前共享宿主实现（统一验收前）

本轮将早期“Flutter 后台桥接”迁为独立 Dart Host；下方早期决定中的桌面后台启动语义由本节替代。具体兼容表见 [共享宿主说明](../../docs/SHARED-HOST.md)。新增代码尚未完成本轮统一验证。

- `host/bin/expert-host.exe` 持有原 ChatController 的任务循环和纯 Dart Riverpod 服务容器，不加载 Flutter 引擎。`expert-tui` 与 Flutter GUI 都是客户端；GUI/TUI 关闭会取消各自拥有的任务，Host 可继续服务其他窗口。
- GUI 的任务控制器变为 RPC / 状态投影；资料库和学习等既有业务通过 Host 的 Drift 数据连接共享同一个 SQLite 实例。每个客户端的事务在断线时清理，不自动重放写入。
- TUI 启动仅查找明确 `EXPERT_CHAT_HOST`、GUI 路径旁的 `host/bin/expert-host.exe` 或 TUI 所在发行包。不会通过项目目录或不可信 PATH 猜测 Host 程序。
- `%LOCALAPPDATA%/expert-chat/tui/bridge.json` 保留 v1 私有发现目录；另有仅 GUI 使用的 `gui.json`。握手返回 `execution_host:dart` 与 `host_version:1`。原始偏好、SQL、凭据与内部操作必须持有 GUI token。
- 生产 Host 持有旧 GUI 的 v1 互斥量与资料目录锁；新 GUI 使用 v2 界面互斥量。首次迁移保存原始资料副本。任务副作用先登记持久化请求回执，崩溃后旧请求不会自动执行。
- 公共快照协商 `snapshot.patch` 后使用消息/步骤/子代理的增量，基线丢失时读取完整快照。GUI 使用会话游标与运行状态分段版本；状态过期始终可见。
- `/gui` 通过已连接 GUI 的动作回执定位；没有 GUI 时可启动图形客户端。OAuth 和 SSH 指纹确认由明确的客户端操作完成，断连不会默认为批准。
- `/bridge off` 和关闭 TUI 会断开调用者并取消其窗口任务。默认无客户端且无活动执行资源时空闲 600 秒退出；显式 Host 退出先停止、等待和保存恢复记录。

## 已核实的后端映射

| 规格状态/信息 | 来源 |
|---|---|
| 会话与正文、工具步骤、思考 | chatControllerProvider / Conversation.activePath / ChatMessage.searchActivities |
| 运行、停止、失败、重启中断 | ChatState.runningConversationIds、sessionCheckpoints、workTaskRuntimeProvider |
| 等待批准 | workApprovalsProvider，优先于步骤的 running 显示 |
| 轮次/暂停 | workRoundsProvider 的 used/limit/active/paused |
| 待验收/已验收 | taskAcceptanceProvider + taskSnapshotFor + verifyAndAcceptTask；不能把模型自称完成当验收 |
| 改动与差异 | workChangesProvider，按当前会话/本轮 assistantId 筛选；文本快照与二进制区别保留 |
| 助手任务树 | workAgentsProvider.records / followup / cancel / resumeChildTask |
| 补充要求 | ChatController.addWorkRequirement / workTaskSteeringProvider |
| 执行位置 | conversationWorkspaceBindingsProvider + desktopWorkspaceHostProvider；SSH 从 sessionPolicyProvider |
| 模型、来源、思考 | settingsControllerProvider + conversationModelChoiceProvider + reasoningEffortsFor；不输出 API Key |
| 上下文 | ChatState.contextReports / workSessionInsightsProvider；未知值为 null，不捏造百分比 |
| 错误/诊断 | scoped ChatState.error 与 workRuntimeLogsProvider；重试信息没有来源时不捏造倒计时 |
| 规则/记忆 | TaskCore.repositorySources / workMemoryProvider 的公开元数据，非私密模型内部上下文 |

状态优先级：pending approval → active retry（有真实证据）→ running → explicit stopped/interrupted → failed → acceptance waiting/accepted → idle。工具失败与总任务失败分开。

## 必要最小扩展（用户 4A 已确认）

- 新增会话 planOnly 策略，缺字段默认 false。计划模式执行层只允许明确只读工具：读取、目录、搜索、浏览、数学纯计算等；禁止 shell、文件写、进程控制、电脑操作及未知 MCP、子代理写入。不能仅在提示词中要求不写。子代理继承限制。运行中模式调整下一完整轮生效，收紧限制应在每次工具执行前重查。
- 批准增加本会话精确操作授权与拒绝原因。授权绑定会话、执行位置、工具、规范化完整参数，不能使用字符串前缀批准任意 shell；关闭/restart 不扩大授权。GUI 仍使用同一批准 provider。
- 撤回仅限尚未消费的 queued id，持久化成功才确认；已消费返回冲突，不能假装撤回。
- Bridge 显式 conversationId 入口避免 GUI 切会话产生误发。公开 controller 的最小 session-scoped 包装方法，不复制 sendMessage 实现。

## 规格差异与处理

- `next/desktop/README.md` 描述过时，当前程序已有命令/子代理等能力；以代码为准。
- GUI 除工作任务外还有故事/学习/多媒体/资料库/自动化等；TUI 不删除功能，提供 GUI 定位/打开设置入口，已支持的图片附件沿用现有 Attachment。
- 计划模式、会话级精准批准、单条撤回为新增能力（上文）；登录/复杂配置继续在 GUI 完成，并明确跳转，不显示假成功。
- `ctrl+b` 同时被规格列为侧栏快捷键和不能占用的 readline 键：有输入时按编辑后退，空输入且宽度 >=140 才切侧栏。
- ASCII 回退指界面装饰字形，不把用户中文正文改写为英文；中文仍按显示宽度排版。
- 项目注册需确认，不能因为 cwd 自动授予读写。运行中拒绝切执行位置。
- 宠物使用实际 JSON 帧，界面纯终端字符；性能与键位按真实终端验证，未执行的 tmux/平台检查如实记录。

## 早期桥接实施分工（历史记录）

- root：本文件/协议/schema/fixtures、Windows 单实例和后台启动、集成与实测、日志和最终提交。
- A1：next/tui 界面/组件/键盘/宠物/快照；先建立状态模型与骨架再通知 A2。
- A2：source.rs、launcher.rs、数据回放/WebSocket/重连/命令入口脚本（不改 A1 的视图文件）。
- B：Dart bridge、必要 session/controller/policy 扩展、main.dart 最小接入、对应 Dart 测试；不改 native runner。
- 协议变更先报 root，两端和 fixtures 同步。子代理不提交；root 审查后逐项指定路径提交，不 push。
