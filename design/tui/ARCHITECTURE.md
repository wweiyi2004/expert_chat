# TUI 架构决策（2026-10-26）

## 用户已确定

1A：复用桌面应用的 ChatController，不另建代理循环。2A：自动连接，必要时后台启动桌面应用，保持单实例。3A：入口 `expert`，实际程序 `expert-tui`。
4A：允许补齐必要后端能力，两端共用，不重构现有内核。5A：关闭终端仅断开客户端，任务继续；显式停止才取消。6A：默认当前目录，首次使用需确认路径和权限，已登记项目沿用权限。

## 接入方案

- Rust workspace 新增 `next/tui`，ratatui/crossterm/unicode-width，WebSocket 使用 tungstenite；依赖通过 Cargo.lock 锁定。`expert` 脚本转发参数、退出码，不注册第二执行引擎。
- Dart 新增 `lib/features/tui_bridge/`。`main(List<String> args)` 中在与 GUI 相同的 ProviderScope 内启动 bridge host。通过 `ProviderContainer` 读取/监听现有 providers。不复制密钥、不实例化第二 ChatController、不调用 independent RemoteHost 执行模型循环。
- 默认不监听；`--tui-bridge --background` 开启。正在运行的程序通过原生单实例消息通知开启 bridge；消息不携带任意命令或路径。Dart method channel `expert_chat/tui_bridge` 接收 `enable`，并提供启动参数查询和 `show` 方法。启动请求早于 channel 初始化时保留 pending 标记。
- Windows `%LOCALAPPDATA%/expert-chat/tui/bridge.json` 为发现文件，包含 v、pid、port、token；目录和文件仅当前用户/SYSTEM 可读写，创建令牌前建立 ACL，拒绝 junction/symlink。令牌 32 随机字节，每次服务启动轮换。127.0.0.1 随机端口 WebSocket `/tui`；无 Origin 浏览器入口，握手必须 token，5 秒认证超时，限制消息长度。其他 OS 使用权限 0700/0600。
- GUI 路径按明确 `--gui <path>` / `EXPERT_CHAT_GUI` / 同目录 expert_chat.exe / 用户发现文件解析；不执行项目目录或不可信 PATH 中的同名 GUI。连接失败清楚提示，不自动切到 demo。
- 客户端重连先握手、读取快照；禁止自动重发有副作用请求。请求 id 用于去重；服务重启丢失缓存时报告未知结果，用户核对后决定。
- 断开任意客户端不停止控制器、子代理或后台进程。服务关闭只关闭通信；任务停止走现有 stop。GUI 托盘退出仍结束整个应用，需要向用户说明。

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

## 分工与边界

- root：本文件/协议/schema/fixtures、Windows 单实例和后台启动、集成与实测、日志和最终提交。
- A1：next/tui 界面/组件/键盘/宠物/快照；先建立状态模型与骨架再通知 A2。
- A2：source.rs、launcher.rs、数据回放/WebSocket/重连/命令入口脚本（不改 A1 的视图文件）。
- B：Dart bridge、必要 session/controller/policy 扩展、main.dart 最小接入、对应 Dart 测试；不改 native runner。
- 协议变更先报 root，两端和 fixtures 同步。子代理不提交；root 审查后逐项指定路径提交，不 push。
