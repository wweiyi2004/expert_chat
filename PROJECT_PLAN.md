# Expert Chat — 跨平台 LLM 客户端 · 完整项目计划书

> 仿 [chat.deepseek.com](https://chat.deepseek.com/) 体验的客户端：**专家模式（深度思考）、智能联网、文件上传**，界面简洁，支持浅色 / 深色 / 跟随系统。
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

### 1.2 关键产品决策（已确认）
- **平台**：跨全平台（桌面 + 移动）—— Windows / macOS / Linux / iOS / Android / Web。
- **数据**：纯本地，无后端。API Key 与对话历史只存用户本机，客户端直连各家 API。
- **联网/文件**：自己选第三方搜索源 + 本地文件解析（官方那套服务端能力不开放，必须自建）。

### 1.3 非目标（至少初期不做）
- 不做账号系统、不做云同步、不做服务端代理。
- 不自建搜索引擎索引（不现实，用搜索 API）。
- 不做模型训练/微调。

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
│  settings（API/模型/主题）   history（抽屉）    │
├─────────────────────────────────────────────┤
│  状态层  state/  (Riverpod AsyncNotifier)      │
│  ChatController / SettingsController           │
├─────────────────────────────────────────────┤
│  领域层  domain/                                │
│  ┌────────────────┐   ┌──────────────────┐    │
│  │  LlmProvider   │   │   ToolEngine      │    │
│  │  (抽象接口)     │   │ 联网搜索 / 文件解析 │    │
│  └────────────────┘   └──────────────────┘    │
├─────────────────────────────────────────────┤
│  数据层  data/                                  │
│  SecureStorage(密钥) │ ConversationRepository   │
└─────────────────────────────────────────────┘
                │ 直连 HTTPS
                ▼  DeepSeek / OpenAI / Kimi / 智谱 …
```

**核心抽象**：
- `LlmProvider`（接口） + `OpenAiCompatibleProvider`（SSE 实现，已接 `content` 与 `reasoning_content`）。多家服务只是 baseUrl/model 不同。
- `ConversationRepository`（接口） + `JsonConversationRepository`（M1）→ 后续 `DriftConversationRepository`。

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
（后续将新增：`domain/tools/`（搜索/文件）、`data/db/`（drift）、`domain/rag/`。）

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
