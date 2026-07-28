# Expert Chat — 跨平台 LLM 客户端 · 完整项目计划书

> 仿 [chat.deepseek.com](https://chat.deepseek.com/) 体验的客户端：**专家模式（深度思考）、智能联网、文件上传**，并提供默认隐藏、按需开启的 **科研模式（SSH + tmux + AI 命令审批）**。界面简洁，支持浅色 / 深色 / 跟随系统。
> 用户自带 API Key，支持 DeepSeek 等任意 **OpenAI 兼容** 服务。**纯客户端、无后端。**

---

## 1. 目标与范围

### 1.1 产品目标
做一个"自带钥匙"的多平台 AI 对话客户端，把官网网页端的核心体验搬到本地应用：

| 能力 | 说明 | 还原程度 |
|---|---|---|
| 基础对话 | 流式输出、Markdown/代码/公式渲染、多轮历史 | 完全对齐 |
| 专家模式 / 深度思考 | 接 `deepseek-reasoner`，展示可折叠思考链 | 完全对齐 |
| 智能联网 | 模型自主决定搜索 → 检索 → 注入 → 带引用 | 接近对齐（搜索源自选） |
| 文件上传 | PDF/Word/Excel 等解析为文本注入对话 | 数字文档对齐；扫描件/超大文档需进阶能力 |
| 多 Provider | DeepSeek / OpenAI / Kimi / 智谱 … 任填 | 通过统一抽象支持 |
| 主题 | 浅 / 深 / 跟随系统 | 完全对齐 |
| 科研模式（可选） | SSH 终端、tmux、终端输出交给 AI 分析、命令人工审批 | 默认隐藏；仅原生端启用 |

### 1.2 关键产品决策（已确认）
- **平台**：跨全平台（桌面 + 移动）—— Windows / macOS / Linux / iOS / Android / Web。
- **数据**：纯本地，无后端。API Key 与对话历史只存用户本机，客户端直连各家 API。
- **联网/文件**：自己选第三方搜索源 + 本地文件解析（官方那套服务端能力不开放，必须自建）。
- **科研模式是隐藏实验功能**：默认关闭；关闭时主导航、页面和普通会话中都不得出现终端入口。用户只能在「设置 → 能力 → 实验功能」中主动开启。
- **AI 不能直接控制服务器**：AI 只能分析用户明确选择的终端上下文并提出命令；命令必须经过用户查看、编辑和确认后才能写入 SSH 会话，不提供永久自动批准。
- **科研模式首版范围**：原生端 SSH shell、移动端终端、tmux 会话发现/新建/附加、AI 命令建议与逐次审批。

### 1.3 非目标（至少初期不做）
- 不做账号系统、不做云同步、不做服务端代理。
- 不自建搜索引擎索引（不现实，用搜索 API）。
- 不做模型训练/微调。
- 科研模式首版不做 SFTP 文件上传/下载、不做 Slurm 专用面板、不做实验记录系统、不做端口转发、不做无人值守或自动循环执行命令。
- Flutter Web 不直连 SSH：浏览器没有原生 TCP socket；没有额外 WebSocket 网关时，Web 端隐藏科研模式开关和终端入口。

---

## 2. 技术选型与理由

| 维度 | 选择 | 理由 |
|---|---|---|
| 框架 / 语言 | **Flutter 3.44 / Dart 3.12** | 一套代码覆盖全部 6 端；原生编译、桌面性能优于 Electron；用户已有 Flutter 环境 |
| 状态管理 | **Riverpod 3.x** | 适合流式异步数据、依赖注入清晰 |
| 网络 / SSE | **dio** + `ResponseType.stream` | DeepSeek 走 OpenAI 兼容 SSE，需逐 chunk 解析 |
| Markdown | **gpt_markdown** | 专为 LLM 输出设计，活跃维护 |
| 密钥存储 | **flutter_secure_storage** | 进系统钥匙串（Win=DPAPI / macOS=Keychain / Android=Keystore） |
| 设置存储 | **shared_preferences** | 轻量键值，存 baseUrl/model/themeMode |
| 历史存储 | **M1: JSON 文件** → **M3: drift/SQLite** | 接口已抽象，先跑通再升级，避免 codegen 阻塞首次运行 |
| 主题 | **Material 3** `ColorScheme.fromSeed` + `ThemeMode` | 一行切换三种模式 |
| SSH | **dartssh2 2.22.x** | 纯 Dart；支持原生端 SSH shell、PTY、密码/密钥认证；Web 原生 TCP 不可用 |
| 终端渲染 | **xterm 4.x** | Flutter 全平台终端模拟器，支持移动端输入、CJK/IME、快捷键和动态主题 |

**为何不用 Electron / Tauri / RN**：Electron、Tauri 桌面强但移动端缺位；RN+Tauri 要维护两套栈。Flutter 是唯一真正六端通吃的方案。

### Riverpod 3.x 注意事项（与 2.x 不同，已踩坑）
- 取值用 `AsyncValue.value`（**不是** `valueOrNull`）。
- `AsyncNotifier` 自带 `update` 方法，自定义方法**别重名**（本项目用 `apply`）。

---

## 3. 架构总览（纯客户端，分层）

```
┌─────────────────────────────────────────────┐
│  UI 层  features/                              │
│  chat（聊天页/输入框/思考面板/文件卡片）         │
│  settings（API/模型/主题/实验功能）              │
│  research（隐藏科研模式：SSH 终端/AI 审批）      │
├─────────────────────────────────────────────┤
│  状态层  state/  (Riverpod AsyncNotifier)      │
│  ChatController / SettingsController           │
│  ResearchTerminalController                     │
├─────────────────────────────────────────────┤
│  领域层  domain/                                │
│  ┌────────────────┐   ┌──────────────────┐    │
│  │  LlmProvider   │   │   ToolEngine      │    │
│  │  (抽象接口)     │   │ 联网搜索 / 文件解析 │    │
│  └────────────────┘   └──────────────────┘    │
│  ┌────────────────────────────────────────┐    │
│  │ Research: SSH transport / tmux / AI gate │    │
│  └────────────────────────────────────────┘    │
├─────────────────────────────────────────────┤
│  数据层  data/                                  │
│  SecureStorage(API/SSH 密钥) │ SharedPrefs 开关  │
│  ConversationRepository │ SSH 主机配置           │
└─────────────────────────────────────────────┘
                │ 直连 HTTPS
                ▼  DeepSeek / OpenAI / Kimi / 智谱 …
```

**核心抽象**：
- `LlmProvider`（接口） + `OpenAiCompatibleProvider`（SSE 实现，已接 `content` 与 `reasoning_content`）。多家服务只是 baseUrl/model 不同。
- `ConversationRepository`（接口） + `JsonConversationRepository`（M1）→ 后续 `DriftConversationRepository`。
- `ResearchSshClient` 隔离 SSH 连接、shell/PTY、窗口尺寸和生命周期；UI 不直接持有 `dartssh2` 对象。
- `TerminalTranscriptBuffer` 维护有限长度的纯文本环形缓冲区，供用户选取上下文；它与 xterm 的显示缓冲分离。
- `ResearchCopilotService` 只输出结构化 `CommandProposal`；`ApprovedCommandExecutor` 只接受 UI 审批后创建的 `ApprovedCommand`，从类型边界阻止 AI 绕过确认。

---

## 4. 三大难点的能力边界分析

### 4.1 深度思考（专家模式）— ✅ 可完全还原
`deepseek-reasoner` 流式返回里把思考链放 `reasoning_content`、答案放 `content`。UI 做成可折叠"深度思考中…"面板，思考完展示正文。**SSE 解析已同时接两个字段，面板组件 `ThinkingPanel` 已就位。**

### 4.2 智能联网 — ⚠️ 接近还原，需自拼（官方源不开放）
联网搜索 = 两步：
1. **发现（discovery）**：找出该读哪些 URL —— **绕不开搜索引擎**。客户端没有全网索引，只能：
   - 爬搜索引擎结果页 → 不可靠、易被风控封禁，不采用；
   - **调搜索 API** → 稳定合规（Tavily / Exa / Bing / SearXNG / 国内博查等），**采用**。
2. **抓取（fetch + parse）**：拿到 URL 下载并提取正文 —— **原生端（桌面/移动）可自己直连抓取，无 CORS 限制**；**Web 端有 CORS，需代理**。

**最省成本方案**：搜索 API 只用来拿 URL 列表（调用便宜/有免费额度），正文让客户端自抓自解析。
**"智能"如何实现**：用 **function calling** 定义 `web_search` 工具，模型自主决定何时搜、可多轮检索（agentic 循环），结果带 URL 渲染成引用角标。
**官方搜索源**：联网查证过 —— DeepSeek **从未公开披露**实际用哪家，外界推测多为 Bing 但无官方确认；这不影响本项目（那套不开放，自选即可）。

### 4.3 文件上传 — ⚠️ 数字文档可对齐，进阶能力需补
开放 API 是纯文本接口（无文件托管），所以**本地解析文件为文本再注入对话**：
- PDF/Word/Excel/PPT（带文字层）→ 本地解析库即可，**可对齐**。
- **两个真实差距**（根源是无后端）：
  - **超大文档**（几百页）→ 受上下文窗口限制。官网用 RAG（切片+向量检索）。要追平需在**本地做轻量 RAG**：切片 → embedding → 本地向量库（sqlite-vec/objectbox）→ 检索注入。可做，属额外工程，排后期。
  - **扫描件 / 图片型 PDF** → 需 **OCR**（本地 Tesseract）或视觉模型。可做，排后期。

### 4.4 关键约束（务必记住）
`deepseek-reasoner`(R1) **不支持 function calling**。所以"深度思考 + 联网"不能由同一模型一次完成 → **编排**：先用 `deepseek-chat` 判断并执行搜索、把检索结果注入上下文，再交给 reasoner 深度思考。逻辑放 `ToolEngine`。

---

## 5. 目录结构

```
lib/
├── main.dart                          # 入口：ProviderScope + MaterialApp(主题绑定)
├── core/
│   ├── providers.dart                 # sharedPrefs/secureStorage/repo/llm 注入
│   └── theme.dart                     # Material 3 浅/深色
├── data/
│   ├── models.dart                    # ChatMessage / Conversation / MessageRole
│   └── conversation_repository.dart   # 抽象 + JSON 实现
├── domain/
│   └── llm/
│       ├── llm_provider.dart          # LlmProvider 抽象 / LlmConfig / ChatChunk / KnownModels
│       └── openai_compatible_provider.dart  # SSE 流式实现
├── state/
│   ├── settings_controller.dart       # AsyncNotifier，baseUrl/key/model/theme
│   └── chat_controller.dart           # AsyncNotifier，对话列表/流式/停止/持久化
└── features/
    ├── chat/
    │   ├── chat_page.dart             # 主界面 + 输入框 + 历史抽屉
    │   └── widgets/
    │       ├── message_bubble.dart    # 用户/助手气泡 + Markdown
    │       └── thinking_panel.dart    # 可折叠深度思考面板
    └── settings/
        └── settings_page.dart         # 设置页
```
科研模式新增目录（M7）：

```text
lib/
├── data/research/
│   ├── ssh_profile.dart                # 非敏感主机信息；不含密码/私钥正文
│   └── research_prefs.dart             # 隐藏开关、最近主机、AI 上下文行数
├── domain/research/
│   ├── research_ssh_client.dart        # SSH、PTY、shell、resize、断线
│   ├── tmux_service.dart               # list/new/attach，仅做 tmux 命令编排
│   ├── terminal_transcript_buffer.dart # 有界终端文本缓冲与脱敏
│   ├── command_risk.dart               # 本地风险标签，不把模型判断当安全边界
│   └── research_copilot_service.dart   # 终端上下文 → 结构化 CommandProposal
├── state/
│   └── research_terminal_controller.dart
└── features/research/
    ├── research_terminal_page.dart     # 响应式科研终端主页面
    └── widgets/
        ├── ssh_profile_sheet.dart
        ├── terminal_shortcut_bar.dart
        ├── tmux_session_sheet.dart
        ├── research_ai_sheet.dart
        └── command_approval_sheet.dart
```

（后续仍保留：`domain/rag/` 用于超大文档，不与科研模式耦合。）

---

## 6. 详细路线图

### ✅ M1 — 基础对话（已完成）
- [x] 创建全平台 Flutter 工程，引入依赖
- [x] `LlmProvider` 抽象 + OpenAI 兼容 SSE 流式实现
- [x] 流式对话 + gpt_markdown 渲染
- [x] 设置页：Base URL + API Key（安全存储）+ 模型选择
- [x] 本地历史（JSON）+ 历史抽屉（切换/删除/自动命名）
- [x] 浅 / 深 / 跟随系统主题
- [x] 停止生成、Enter 发送 / Shift+Enter 换行
- [x] 错误提示（401/402/404/429/网络）
- [x] 通过 `flutter analyze` + 单元测试 + Windows debug 构建
- *附带*：SSE 已接 `reasoning_content`，`ThinkingPanel` 已就位（M2 核心提前打通）

### ✅ M2 — 深度思考体验打磨（已完成）
- [x] 思考耗时计时显示（"已深度思考 N 秒"，`Stopwatch` 在首个 reasoning delta 启动、首个 content delta 冻结）
- [x] 思考流式动效（脉冲图标）/ 思考完成后自动折叠（`AnimatedCrossFade`）
- [x] 输入框旁"深度思考"开关，开启即把本次请求路由到 active profile 的 reasoner 模型
- [x] reasoner 不支持 function calling → provider 层防御：reasoner 模型不下发 `tools`

### ✅ M3 — 多 Provider + 持久化升级（已完成）
- [x] 设置页多套 Provider 配置（增删改、命名、切换；key 按 profile 存安全存储）
- [x] 内置预设（DeepSeek / OpenAI / Kimi / 智谱）一键填充 baseUrl + 模型列表（`ProviderPreset`）
- [x] `ConversationRepository` 换 **drift/SQLite**（build_runner codegen 已跑通；旧 JSON 历史首启动自动迁移）
- [x] 历史搜索（标题+正文）/ 重命名 / 导出（导出见 M6）

### ✅ M4 — 文件上传（已完成）
- [x] 文件选择（file_picker v11 `FilePicker.pickFiles`，注意 v11 是静态方法）+ 输入框上方文件卡片 UI
- [x] 本地解析：PDF（syncfusion_flutter_pdf）、Word（docx_to_text）、Excel（excel）、PPT（archive+xml 自解）、纯文本
- [x] 解析文本注入对话上下文（每文件 60k 字截断 + 卡片提示；原文件不出本机）
- [x] 图片：卡片提示"需视觉模型"，预留入口

### ✅ M5 — 智能联网（已完成）
- [x] `ToolEngine` + `web_search` ToolSpec 定义（function-calling 能力已在 provider 预留）
- [x] 多搜索后端（Tavily / Exa / 博查）经 dio 直连，用户自带 key
- [x] **编排式**联网（对所有模型含 reasoner 通用）：搜索 → 注入 system 上下文 → 模型带 `[n]` 引用作答
- [x] 引用角标渲染（gpt_markdown `sourceTagBuilder`，可点跳转）+ 折叠"来源"列表
- *说明*：客户端自抓正文为可选增强（Tavily/Exa 已直接返回正文）；纯 function-calling agentic 循环为后续增强项

### ⬜ M6 — 进阶 & 打磨（核心已完成；RAG/OCR 延后）
- [x] 响应式布局（≥900px 桌面双栏常驻历史面板 / 窄屏抽屉）
- [x] 消息复制 / 重新生成、失败重试（错误条"重试"）
- [x] 导出对话为 Markdown（file_picker `saveFile`，桌面写盘 / 移动传 bytes）
- [x] 快捷键（Ctrl/⌘+N 新对话；Enter 发送 / Shift+Enter 换行已有）
- [ ] 本地 RAG（切片 + embedding + sqlite-vec）支撑超大文档 —— 延后
- [ ] OCR（Tesseract）支撑扫描件 —— 延后

### ✅ M7 — 隐藏科研模式（SSH + tmux + AI 命令审批）

#### M7.0 产品规则（不可自行改动）

1. **默认隐藏**：新安装和旧版本升级后，`researchModeEnabled` 均默认为 `false`。
2. **唯一开启位置**：`设置 → 能力 → 实验功能 → 科研模式`。普通会话页不放引导卡、红点或终端入口。
3. **关闭状态的导航**：
   - 手机底栏：`会话 / 创作 / 设置`；
   - 宽屏侧栏：`会话 / 创作 / 设置`；
   - 不创建科研页面、SSH controller 或后台连接。
4. **开启状态的导航**：
   - 手机底栏：`会话 / 终端 / 创作 / 设置`；
   - 宽屏侧栏：同样动态增加 `终端`；
   - 开启开关只显示入口，不自动连接服务器。
5. **关闭科研模式**：
   - 无活动连接时立即关闭并隐藏入口；
   - 有 SSH 连接时先提示“将断开 N 个连接；远端 tmux 中的任务仍会继续”，确认后断开、清理内存中的终端内容并隐藏入口；
   - 当前页若为终端，回退到设置页，不能留下越界的 tab index。
6. **本地状态**：开关保存在 `shared_preferences`，不进入对话导出、AI 上下文或云端。
7. **人工审批是硬边界**：AI 不能调用 SSH 写入接口；每条 AI 命令都必须由用户逐次确认，不提供“总是允许”。

#### M7.1 设置页 UI（功能入口）

- 位置：现有 `_SettingsCategory.capabilities` 页面底部，新建 `_SectionTitle('实验功能')`。
- 卡片沿用 `AppTheme`：
  - 左侧：`Icons.terminal_rounded`，墨青色 `primaryContainer`；
  - 标题：`科研模式`；
  - 标签：`实验性`，使用现有 secondary/琥珀色；
  - 描述：`启用 SSH 终端、tmux 会话和 AI 命令审批。`；
  - 右侧：`Switch.adaptive`。
- 卡片下方固定说明：
  - `关闭时，终端入口不会显示，服务器配置也不会进入普通 AI 会话。`
  - Web 端显示禁用态：`浏览器无法直接建立原生 SSH 连接。`
- 开启后可在卡片下显示一次性按钮 `进入科研终端`，但不自动发起 SSH。

#### M7.2 主导航改造

现有 `shellTabIndexProvider` 使用整数并把范围写死为 `0..2`，不能直接在中间插入条件 tab。必须先改为语义化状态：

```dart
enum ShellTab { chat, terminal, studio, settings }
```

- `ShellTabController` 保存 `ShellTab`，不保存可变数组下标。
- `AppShell` 根据 `settings.researchModeEnabled` 生成 `visibleTabs`：

```dart
final visibleTabs = researchModeEnabled
    ? const [ShellTab.chat, ShellTab.terminal, ShellTab.studio, ShellTab.settings]
    : const [ShellTab.chat, ShellTab.studio, ShellTab.settings];
```

- `NavigationBar.selectedIndex` 和 `NavigationRail.selectedIndex` 由 `visibleTabs.indexOf(selectedTab)` 得出。
- `IndexedStack` 的 children 与 `visibleTabs` 使用同一映射，避免导航标签与页面错位。
- 关闭开关前若当前为 `ShellTab.terminal`，先切到 `ShellTab.settings`，再释放科研状态。
- 更新所有 `openShellTab(ref, int)` 调用方，改成 `openShellTab(ref, ShellTab.xxx)`；不要在其他 feature 中散落 magic index。

#### M7.3 科研终端 UI

视觉原则：**Expert Chat 外壳保持米白纸张感和墨青主色，只有真实终端画布使用深色**。不得复制黑绿霓虹、Remote Lab 品牌或独立 App 导航。HTML 可点原型位于 `remote_lab_ui/`，最终 Flutter 实现以本节为准。

手机（`< WorkspaceBreakpoints.shellRail`）：

- 顶部 `AppBar`：
  - 标题 `科研终端` + `Icons.terminal_rounded`；
  - 中部/右侧显示当前主机 `gpu-lab-01`、绿色连接点和延迟；
  - 更多菜单包含“连接管理 / 断开 / 科研模式设置”。
- 第二行会话条：
  - 当前 shell/tmux 名称；
  - `+` 新建 tmux；
  - `tmux N` 打开底部会话列表。
- 主体：圆角深色 `TerminalView`，颜色从 `AppTheme.dark()` 派生，不使用全局霓虹绿。
- 输入辅助：横向滚动快捷键 `Ctrl / Esc / Tab / | / ~ / ↑ / ↓ / ← / →`，支持软键盘、CJK IME、长按选择和复制。
- 右下角上下文按钮：`AI 分析`，徽标表示存在未分析的新错误输出。
- 底部仍使用 AppShell 的主导航，不在科研页面内再做一套“终端/tmux/AI”导航。

AI 分析（手机底部 Sheet）：

- `showModalBottomSheet(useSafeArea: true, isScrollControlled: true)`，高度最多约 `74%`；
- 顶部：`AI 助手`、上下文范围（默认最近 36 行）；
- 分析卡：故障判断 + 明确的“判断依据”标签；
- 命令建议卡：
  - 标题、风险级别、本地风险理由；
  - 可横向/纵向滚动的等宽命令块；
  - `影响` 和 `不会` 两行边界说明；
  - 操作：`拒绝 / 编辑 / 确认执行`。
- 点 `确认执行` 后必须再显示最终审批 Sheet，明确主机、目录、完整命令和风险；最终按钮才创建 `ApprovedCommand`。

宽屏：

- 沿用现有 `WorkspaceBreakpoints`；
- 左侧为终端，右侧常驻 AI 助手（建议宽度 360–420）；
- tmux 作为终端上方的会话条/侧栏，不覆盖 AI 面板；
- 视觉组件全部使用 `Theme.of(context).colorScheme`、现有 14/18/22 圆角体系和 Noto Sans SC。

#### M7.4 SSH、凭证和连接生命周期

依赖（实现前仍需运行 `flutter pub outdated` 检查兼容性）：

```yaml
dependencies:
  dartssh2: ^2.22.3
  xterm: ^4.0.0
```

- 原生平台：Android / iOS / Windows / macOS / Linux。
- Web：不创建 `SSHSocket.connect()`；通过条件导入提供 unsupported stub，避免 `dart:io` 进入 Web 构建。
- 首版认证：密码、未加密/带口令的 OpenSSH 私钥；密码、私钥正文和私钥口令只写 `flutter_secure_storage`。
- `SshProfile` 仅保存：`id/name/host/port/username/authType/lastUsedAt`，不保存 secret。
- 首次连接必须显示服务端 host key fingerprint 并要求信任；后续 fingerprint 变化时阻止连接，不能静默接受。
- 连接与认证分别设置约 15 秒超时；前后台切换不自动执行命令。
- `ResearchTerminalController.dispose()`、关闭科研模式和用户主动断开时，必须关闭 shell stream、SSH client 和所有订阅。
- 私钥解密/KEX 不能阻塞 UI；需要时放到 isolate。
- 首版只允许**一个活动 SSH 主机**。tmux 负责远端任务持久化，不做多主机并行。

数据流：

```text
xterm Terminal.onOutput
        ↓ 用户键盘字节
ResearchSshClient.shell.write()
        ↓
远端 shell stdout/stderr
        ├──→ Terminal.write()                  # ANSI/VT 渲染
        └──→ TerminalTranscriptBuffer.append() # AI 可选纯文本上下文
```

终端 resize 必须把列/行同步到远端 PTY；不得只缩放 UI。

#### M7.5 tmux 逻辑

- tmux 是远端程序，不是本地多标签模拟。
- 连接后通过单独的非交互 session 执行：

```text
tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_windows}' 2>/dev/null
```

- 解析成 `TmuxSessionInfo(name, attached, windows)`；命令退出码表示 tmux 未安装或无会话时，展示可理解的空状态。
- 新建：用户输入合法 session 名后执行 `tmux new-session -s <quoted-name>`。
- 附加：向当前交互 shell 写入经过严格 shell quoting 的 `tmux attach-session -t <quoted-name>`。
- 断开 SSH 不会结束 tmux 内任务；UI 必须明确提示这一点。
- 首版不实现 Slurm 专用队列 UI；用户仍可在 shell 中手动使用 `sbatch/squeue/scancel`。

#### M7.6 AI 上下文与命令审批

`TerminalTranscriptBuffer`：

- 维护最多约 2,000 行或 512 KiB（先到者淘汰旧内容），避免训练日志无限占内存；
- AI 默认只取最近 36 行；用户可改为 20/50/100 行或手动选择；
- 发送前移除 ANSI escape、控制字符，并对常见敏感信息进行本地遮盖（API key、Bearer token、密码赋值、PEM 私钥块）；
- UI 必须预览“将发送给 AI 的内容”，未经用户动作不自动上传终端输出。

`CommandProposal` 至少包含：

```dart
class CommandProposal {
  final String diagnosis;
  final String command;
  final CommandRisk risk; // low / medium / high / blocked
  final List<String> evidence;
  final List<String> impacts;
  final List<String> nonImpacts;
  final String? rollback;
}
```

模型调用：

- 复用当前 active Provider 与 OpenAI-compatible provider，不新增另一套 API 配置。
- 使用独立科研 system prompt，要求只返回结构化 JSON；解析失败时只展示文字建议，不提供执行按钮。
- AI 的 `risk` 仅供解释；最终风险至少取 `max(modelRisk, localRiskClassifier)`。

本地风险规则（最低要求）：

- `blocked`：空命令、包含 NUL/不可见控制字符、无法解析的超长命令。
- `high`：`rm -rf`、`mkfs`、磁盘 `dd`、`shutdown/reboot`、递归 `chmod/chown`、`curl|sh`/`wget|sh`、修改防火墙、明显的提权或批量 kill。
- `medium`：`sudo`、包安装、进程终止、覆盖文件、提交/取消集群任务等。
- `low`：只读查询，或启动不覆盖现有检查点的新训练进程。

审批流程：

```text
AI 生成 CommandProposal
  → 用户查看
  → 可拒绝 / 编辑
  → 本地重新计算风险
  → 最终确认（主机 + cwd + 完整命令）
  → 创建 ApprovedCommand
  → ApprovedCommandExecutor 写入当前 shell
  → 输出继续进入 terminal + transcript buffer
```

任何测试都必须能证明：仅有 `CommandProposal` 时无法调用执行器；关闭弹窗、返回、切 tab、断线或 host 改变都会使审批失效。

#### M7.7 分阶段实现顺序

- [x] **M7-A 隐藏开关与动态导航**
  - `SettingsState.researchModeEnabled`，默认 false；
  - Settings 能力页实验功能卡；
  - `ShellTab` 枚举化和条件 destinations；
  - Web 禁用态；
  - 不引入 SSH 依赖也能先合并。
- [x] **M7-B SSH 终端基础**
  - 添加 `dartssh2` / `xterm`；
  - 主机配置、secure storage、host key 校验；
  - shell + PTY + resize + 断线重连 UI；
  - Android/iOS/Windows 最小实机验证（实机 SSH 仍待用户侧验证）。
- [x] **M7-C tmux 与移动端交互**
  - 会话列表、新建、附加；
  - 快捷键、软键盘、复制选择；
  - 旋转屏幕和后台恢复。
- [x] **M7-D AI 分析与人工审批**
  - transcript ring buffer + 脱敏预览；
  - 结构化 proposal；
  - 本地风险分类；
  - 双层确认和审批失效规则。
- [x] **M7-E 稳定性与安全收尾**
  - 生命周期、超时、host key 变化、坏网络；
  - 长日志内存上限；
  - 无密钥/日志泄漏；
  - `flutter analyze`、单测和原生/Web 构建。

#### M7.8 验收标准

- [x] 全新安装时看不到任何终端入口。
- [x] 只有打开设置开关后，手机底栏和桌面侧栏才出现“终端”。
- [x] 关闭开关后入口消失；当前 terminal tab 不发生 index 越界或空白页。
- [x] Web 构建成功且开关不可用；原生端可建立真实 SSH shell（真实 SSH 待用户验证）。
- [ ] 手机可输入中文/英文、Ctrl/Esc/Tab/方向键，旋转后 PTY 尺寸正确（代码已实现；真机待验证）。
- [ ] SSH 断开后远端 tmux 训练继续；重新连接可再次 attach（代码已实现；真机待验证）。
- [x] AI 只收到用户预览并确认的终端片段，敏感串被遮盖。
- [ ] AI 命令在最终确认前不会写入 shell；编辑后必须重新计算风险。
- [ ] 切换主机、断线、关闭 Sheet 或离开终端会使旧审批失效。
- [ ] 不实现 SFTP、Slurm 面板和实验记录，不借 M7 扩大首版范围。

---

## 7. 运行方式

```bash
cd E:\wweiyi\Project\Software\expert_chat
flutter run -d windows        # 或 -d chrome / -d macos / Android 设备
```
首次使用：右上角 ⚙️ 设置 → 填 Base URL（默认 `https://api.deepseek.com`）+ API Key → 选模型（`deepseek-reasoner` 带深度思考）→ 返回主界面发消息。

---

## 8. 风险与待定项

| 项 | 风险/说明 | 处置 |
|---|---|---|
| Web 端联网抓取 | CORS 限制无法直抓正文 | 用搜索 API 直接返回正文，或后期可选代理 |
| 大文档 | 上下文窗口溢出 | M6 本地 RAG |
| 搜索 API 成本 | 第三方按量计费 | 仅用于"发现"，正文自抓；默认关闭，用户自配 key |
| 移动端构建 | iOS 需 Mac+证书 | 桌面优先迭代，移动端 M3 后验证 |
| gpt_markdown 公式 | LaTeX 支持需确认 | 必要时补 flutter_math_fork |
| Flutter Web SSH | 浏览器没有原生 TCP socket | Web 隐藏科研入口；未来若需要必须单独建设 WebSocket SSH 网关 |
| SSH 主机伪装 | 首次连接或主机重装后 host key 变化 | 首次显示 fingerprint；已知主机变化时阻断并要求用户明确处理 |
| AI 建议误操作 | 模型可能误判风险或生成破坏性命令 | 本地风险分类 + 完整命令预览 + 每次人工确认；无永久授权 |
| 长训练日志 | xterm 与 AI transcript 可能持续占用内存 | transcript 使用行数/字节双上限；AI 默认只取最近 36 行 |
| App 断线 | 手机切后台或网络切换会中断 SSH | 训练放 tmux；前台恢复时提示重连/重新 attach，不伪装成仍在线 |

---

## 9. M7 技术依据（2026-07-28 核对）

- [`dartssh2`](https://pub.dev/packages/dartssh2)：当前 2.22.3，支持 Android / iOS / Linux / macOS / Windows，提供 SSH shell、PTY、密码/密钥认证和超时；官方明确说明浏览器不能直接使用原生 TCP `SSHSocket.connect()`。
- [`xterm`](https://pub.dev/packages/xterm)：当前 4.0.0，支持 Flutter 六端，包含移动端、CJK/IME、快捷键和动态主题能力；M7 只在原生端把它接到 SSH transport。
- 两个包均由 Terminal Studio 维护，并提供 xterm + dartssh2 的 SSH 示例；实现时应以当前锁文件解析结果和本项目 Flutter/Dart 版本为准，不盲目复制旧示例 API。
