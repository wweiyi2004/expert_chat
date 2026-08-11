# Expert Chat

跨平台 Flutter LLM 客户端，支持多种 OpenAI 兼容 API（如 DeepSeek 等）。

## 功能特性

- **多模型对话** — 支持配置多个 LLM 提供商，自由切换
- **流式输出** — 实时流式显示 AI 回复
- **思考过程展示** — 可展开查看模型的推理过程（thinking）
- **文件解析** — 支持上传 PDF、DOCX、Excel、TXT 等文件作为上下文
- **持久化文件长任务** — 可连接自建 Gateway；应用退到后台或关闭后服务端继续解析超长文档，重新打开自动补齐进度和增量结果
- **统一文件 Gateway** — 一套地址和 Token 同时承载长文件分析、文档编辑与格式转换，并通过能力发现继续扩展 OCR、知识库等模块
- **视觉理解** — 可单独配置 OpenAI 兼容视觉 API，上传图片进行分析
- **图片生成** — 可单独配置 `/images/generations`，在对话中生成并保存图片
- **上下文管理** — 配置模型窗口、回复预留和历史条数，超限时仅压缩临时请求
- **本地长期记忆** — 支持手动“记住”和“更多 → 整理候选记忆”；AI 只生成候选，逐条确认后才写入 Markdown；新旧记忆不一致时可选择替换、两条都保留或忽略；支持手机分享备份、安全导入合并、常驻/按需召回、来源记录与敏感凭证拦截
- **语音输入** — 调用手机/电脑的系统语音识别；首次点击麦克风时才申请权限，中文识别结果只写入输入框供确认和编辑，不会自动发送，也不在应用中保存原始录音
- **缓存清理** — 一键清除临时网页预览、图片内存与短期搜索缓存，不影响用户数据
- **联网搜索** — 可选「API 提供商官方联网」（DeepSeek Responses `web_search`，当前 `deepseek-v4-flash`）、DuckDuckGo 免费搜索（尽力而为）或 Tavily / Exa / 博查等搜索 API + 本地网页正文抓取
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
3. （可选）联网搜索可选「API 提供商官方联网」（DeepSeek flash，无需搜索 Key）、DuckDuckGo 免费后端，或 Tavily / Exa / 博查（需搜索 API Key）
4. （可选）在“多媒体能力”中分别配置视觉与生图；未完整配置的能力不会出现在聊天界面
5. 在“上下文管理”中按所用模型设置上下文窗口；默认使用 256K
6. （可选）运行 [`server/gateway`](server/gateway) 并在“能力 → Expert Chat Gateway”中填写唯一地址与 Token，再点击“连接并发现能力”；上游模型密钥只保存在服务器

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
├── gateway/           # 统一入口、能力发现、长任务与断线恢复
└── doc_edit/          # 被 Gateway 挂载的文档编辑/转换模块
```

## 许可证

本项目仅供学习交流使用。
