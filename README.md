# Expert Chat

跨平台 Flutter LLM 客户端，支持多种 OpenAI 兼容 API（如 DeepSeek 等）。

## 功能特性

- **多模型对话** — 支持配置多个 LLM 提供商，自由切换
- **流式输出** — 实时流式显示 AI 回复
- **思考过程展示** — 可展开查看模型的推理过程（thinking）
- **文件解析** — 支持上传 PDF、DOCX、Excel、TXT 等文件作为上下文
- **联网搜索** — 集成搜索 API，支持联网获取实时信息
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
3. （可选）配置搜索 API Key 以启用联网搜索功能

## 项目结构

```
lib/
├── core/              # 全局配置（主题、Provider）
├── data/              # 数据层（数据库、Repository）
│   └── db/            # Drift 数据库定义
├── domain/            # 业务逻辑
│   ├── export/        # 对话导出
│   ├── llm/           # LLM 调用封装
│   └── tools/         # 文件解析、搜索等工具
├── features/          # UI 页面
│   ├── chat/          # 聊天界面
│   └── settings/      # 设置界面
└── state/             # 状态管理（Controller）
```

## 许可证

本项目仅供学习交流使用。
