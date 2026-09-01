# Expert Chat

跨平台 Flutter LLM 客户端，支持多种 OpenAI 兼容 API（如 DeepSeek 等）。

## 功能特性

- **多模型对话** — 支持配置多个 LLM 提供商，自由切换
- **流式输出** — 实时流式显示 AI 回复
- **思考过程展示** — 可展开查看模型的推理过程（thinking）
- **文件解析** — 支持上传 PDF、DOCX、Excel、TXT 等文件作为上下文
- **文档 MCP** — Expert Chat 作为 MCP Client，直接发现并调用自建 MCP Server 的文档检查、编辑和转换工具
- **纯 MCP 文件链路** — 文件通过 MCP 分块 Tools 上传，结果通过 MCP Resources 下载，不依赖 Gateway REST
- **单用户部署** — 一个 MCP Token、一套持久文件目录；无需 AuthService、Gateway 管理面或多租户配额
- **视觉理解** — 对话模型本身支持视觉时（如 DeepSeek `deepseek-v4-flash-vision-exp`、GPT-4o）可直接看图；官方 DeepSeek 会走 Files API 上传后按 `file_id` 引用，避免多轮重复内联 base64。也可单独配置 OpenAI 兼容视觉 API，由 `analyze_image` 调用
- **图片生成** — 可单独配置 `/images/generations`，在对话中生成并保存图片
- **上下文管理** — 配置模型窗口、回复预留和历史条数，超限时仅压缩临时请求
- **本地长期记忆** — 支持手动“记住”和“更多 → 整理候选记忆”；AI 只生成候选，逐条确认后才写入 Markdown；新旧记忆不一致时可选择替换、两条都保留或忽略；支持手机分享备份、安全导入合并、常驻/按需召回、来源记录与敏感凭证拦截
- **语音输入** — 调用手机/电脑的系统语音识别；首次点击麦克风时才申请权限，中文识别结果只写入输入框供确认和编辑，不会自动发送，也不在应用中保存原始录音
- **缓存清理** — 一键清除临时网页预览、图片内存与短期搜索缓存，不影响用户数据
- **联网搜索** — 可选「API 提供商官方联网」（DeepSeek Responses `web_search`，V4 flash / pro / vision-exp）、DuckDuckGo 免费搜索（尽力而为）或 Tavily / Exa / 博查等搜索 API + 本地网页正文抓取
- **对话管理** — 创建、删除、导出对话历史
- **Markdown 渲染** — 完整支持代码高亮、表格、链接等 Markdown 语法
- **安全存储** — API 密钥通过 `flutter_secure_storage` 加密存储
- **跨平台** — 支持 Windows、macOS、iOS、Android

## 技术栈

| 层级 | 技术 |
|------|------|
| 状态管理 | Riverpod |
| 数据库 | Drift (SQLite) |
| 网络请求 | Dio |
| 安全存储 | flutter_secure_storage |
| 文件解析 | syncfusion_flutter_pdf / docx_to_text / excel |
| UI 字体 | Noto Sans SC |

## 开始使用

### 环境要求

- Flutter SDK >= 3.12.0
- Dart SDK >= 3.12.0

### 安装运行

```bash
# 克隆仓库
git clone https://github.com/<your-username>/expert_chat.git
cd expert_chat

# 安装依赖
flutter pub get

# 生成 Drift 数据库代码
dart run build_runner build

# 运行应用
flutter run
```

### 配置 API

1. 启动应用后进入 **设置** 页面
2. 填写 LLM API 的 Base URL、API Key 和模型名称
3. （可选）联网搜索可选「API 提供商官方联网」（DeepSeek V4，无需搜索 Key）、DuckDuckGo 免费后端，或 Tavily / Exa / 博查（需搜索 API Key）
4. （可选）看图：把聊天模型换成 DeepSeek `deepseek-v4-flash-vision-exp` 等视觉模型，或在“多媒体能力”中单独配置视觉 API；生图同样在该分类配置
5. 在“上下文管理”中按所用模型设置上下文窗口；DeepSeek V4 为 1M（最大输出 384K），默认仍按 256K 起算，可在设置中改为 1M
6. （可选）运行独立 [`server/mcp_server`](server/mcp_server)
7. 在“能力 → Expert Chat MCP Server”填写服务地址和 `MCP_API_TOKEN`
8. 点击“连接并发现 MCP Tools”；文档编辑和转换随后直接走 MCP

## 项目结构

```
lib/
├── core/              # 全局配置（主题、Provider）
├── data/              # 数据层（数据库、Repository）
│   └── db/            # Drift 数据库定义
├── domain/            # 业务逻辑
│   ├── export/        # 对话导出
│   ├── llm/           # LLM 调用封装
│   ├── media/         # 生图与 TTS 调用封装
│   ├── speech/        # 系统语音输入封装
│   └── tools/         # 文件解析、搜索等工具
├── features/          # UI 页面
│   ├── chat/          # 聊天界面
│   └── settings/      # 设置界面
└── state/             # 状态管理（Controller）
server/
├── mcp_server/        # 当前单用户文档 MCP Server
├── doc_edit/          # MCP Server 复用的纯文档处理核心
├── gateway/           # 旧 REST/多账户部署兼容代码
├── authservice/       # 旧多账户部署兼容代码
└── edge/              # 可选 HTTPS 反向代理
```

## 架构文档

- [当前系统逻辑与 MCP 架构](docs/system-architecture-and-logic.md)
- [独立 MCP Server 使用说明](server/mcp_server/README.md)

## 许可证

本项目仅供学习交流使用。
