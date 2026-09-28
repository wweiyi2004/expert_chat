# Expert Chat

跨平台 Flutter LLM 客户端，支持多种 OpenAI 兼容 API（如 DeepSeek 等）。

## 功能特性

- **多模型对话** — 支持配置多个 LLM 提供商，自由切换
- **Jev 技能路由（可选）** — 在设置 → 模型 → 预设提示词中独立配置 TypeSafe Key；Jev 选择聊天技能，现有模型生成回答，超时或低置信度自动回退。[使用与验证说明](docs/JEV-ROUTING.md)
- **Windows 电脑操作（可选）** — 本地 stdio MCP 接入 Cua Driver，任务模式下后台优先操作窗口，每次动作后回读核验，支持停止。[配置与验证说明](docs/COMPUTER-USE.md)
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

## 思考与工具过程保护

- DeepSeek 在正文或工具调用出现前有客户端思考上限：低强度 30 秒 / 6,000 字符，高强度 60 秒 / 12,000 字符，最大强度 120 秒 / 24,000 字符，先达到任一阈值就停止该请求。字符数不是服务商 token 数；正在执行的官方搜索不计入思考计时，正文长度也不受这个上限限制。
- 达到上限，或请求结束却只有思考没有正文时，最多重试一次关闭思考的请求。保留原问题与已有工具结果，不把未完成思考复制成答案。回退仍只输出思考时，最多等待 20 秒 / 4,000 字符后报错；用户主动停止不会触发重试。回退属于一次新的模型请求，可能产生额外用量。
- 搜索与生图按实际步骤显示运行、完成、失败或中断；生图分为提示词优化、参考图准备和图片生成。提示词优化使用低思考强度，失败时使用原始描述继续生图。
- 较长思考默认预览末尾 1,000 字符，可展开全文；历史记录仍保留完整内容。

思考开关遵循 [DeepSeek 官方接口说明](https://api-docs.deepseek.com/guides/thinking_mode/)；不支持关闭思考的兼容网关仍可能返回错误，此时客户端停止请求并提供重试入口。

## 任务执行与步骤恢复

- 输入区的「图片」菜单统一提供独立生图与回答配图；「后台执行」只在旧服务器确实支持长任务时出现。MCP 主链路与旧 Gateway 兼容能力均保留。
- 设置 → 能力 → 任务执行预算可选择快速（120 秒 / 1 次搜索 / 4 次工具）、标准（300 秒 / 3 次搜索 / 12 次工具）、深入（900 秒 / 8 次搜索 / 32 次工具）或自定义。已有安装迁移为自定义，保留原有搜索轮数等设置；首次安装默认标准。
- 同一轮的模型回退和工具循环共享规划、工具执行预算；正常正文输出不计时。达到预算后只发起一次关闭思考、关闭工具的整理请求，20 秒内仍无正文则停止。独立生图没有可整理的正文时直接停止本地等待。
- 官方搜索的次数只能依据服务端实际报告的步骤统计；服务端不报告步骤时仍受执行时间约束。不展示推测的完成百分比。本地取消不保证远端已经停止或不会计费。
- 执行记录保存步骤耗时、结果摘要与可恢复参数，可查看结果、用已有资料重新回答，或单独重试失败的搜索、网页读取、生图步骤。重试创建新回复分支，保留原记录；重复点击不会并发提交。生图重试需要确认费用，复用已完成的提示词优化。
- 当前不自动重放文档修改和未知 MCP 工具；缺少安全恢复信息时界面说明原因。应用重启后，本地未完成步骤显示中断，不自动重新执行。

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

- Flutter 3.44.0（Dart 3.12.0，版本记录在 `.fvmrc`）
- 服务端开发：Python 3.12、uv 0.11.2
- 实验 Web 原型：Node.js 24

### 安装运行

```bash
# 克隆仓库
git clone https://github.com/wweiyi2004/expert_chat.git
cd expert_chat

# 按已验证的锁文件安装依赖
flutter pub get --enforce-lockfile

# 生成 Drift 数据库代码
dart run build_runner build

# 运行应用
flutter run
```

### 配置 API

1. 首次使用点击首页 **连接模型，开始使用**，选择预设服务商或自定义兼容服务，填写 API Key 和模型名称
2. 点击 **测试连接**；模型返回正文后，点击 **保存并开始对话**。也可以在设置 → 模型中进入引导。测试最多等待 20 秒，只发送独立的简短消息，可能产生少量用量，不携带历史对话或资料；取消或失败不保存本次配置
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
├── document_core/     # 共享文档核心、资源受限进程和 MCP 协议
├── doc_edit/          # 旧文档 REST 适配层
├── gateway/           # 旧 REST/多账户部署兼容代码
├── authservice/       # 旧多账户部署兼容代码
└── edge/              # 可选 HTTPS 反向代理
```

## 架构文档

### 第二期：数据备份、项目与生图版本

- **完整备份与恢复**：设置 → 数据。`.ecbackup` 含会话/分支、角色/世界书、学习、长期记忆、素材字节、项目、生图记录和常用偏好；预览、版本与 SHA-256 校验后导入为新副本，不覆盖原会话/文件。设置恢复默认关闭，恢复日志会在启动时处理未提交操作。
- 备份**不加密**，上限 **128 MB**，当前支持桌面/移动应用和数据结构 15、16 的完整备份；已知 v15 结构会转换后导入，未知或更新结构会拒绝。安全存储密钥及服务商/网关/终端连接配置不包含在内；用户在聊天、资料或提示词中手写的敏感信息仍会保留。远程链接不会自动下载，导入的远程任务不会自动重启。API 配置仍由原有独立迁移入口管理。
- **项目与资料**：侧边栏“更多新建方式”或设置 → 数据。可新建项目、移动会话、编辑说明、关联素材库文档。在项目页新建的会话绑定该项目；普通“新对话”仍未归类。对话请求固定本轮说明/资料快照；项目文件最多 20 份，单份不超过 15 MB，资料文本总预算 32000 字，超限及解析失败显示在思考面板结果中，后续仍受上下文预算裁剪。不建立向量库，不自动 OCR，也不把项目文档自动用于纯生图请求。
- 项目内保存/整理的记忆只在本项目召回，原有记忆保持全局。删除项目仅解除会话与素材关联；其记忆保留原作用域，不会意外升级为全局记忆。
- **生图版本记录**：素材库历史按钮或设置 → 数据。保存原始描述、实际发送提示词、API 修订描述、模型、服务来源（无密钥/查询参数）、尺寸及参考图校验信息；支持复制、两版对比和确认后按原参数生成。再次生成跳过提示词优化，保留父版本。素材按内容去重，版本按请求分别保存；删图不会删参数。旧版本图片不推测补填来源参数；接口未提供随机种子，因此不承诺像素级复现。

数据结构由 v15 升至 v16。新增回归测试位于 `full_backup_test.dart`、`project_generation_test.dart`、`phase2_migration_ui_test.dart`。

- [当前系统逻辑与 MCP 架构](docs/system-architecture-and-logic.md)
- [独立 MCP Server 使用说明](server/mcp_server/README.md)
- [数据可靠性与原生验证](docs/RELIABILITY.md)
- [首次配置与错误恢复](docs/ONBOARDING-AND-RECOVERY.md)
- [项目与素材浏览](docs/WORKSPACE-BROWSING.md)
- [备份兼容与问题反馈](docs/BACKUP-COMPATIBILITY-AND-SUPPORT.md)

## 开发与维护

- [开发与统一检查](CONTRIBUTING.md)：`python scripts/check.py --quick` 或完整 `python scripts/check.py --security`。
- [维护制度与发布追溯](docs/MAINTENANCE.md)：每周依赖检查、每月恢复演练、版本及产物证据。
- [依赖组合与兼容记录](docs/DEPENDENCY-DECISIONS.md)、[Windows 无障碍限制](docs/WINDOWS-ACCESSIBILITY.md)。
- [2026-09-22 项目审查](docs/reviews/2026-09-22-maintenance-audit.md)及[修复与验证记录](docs/reviews/2026-09-22-maintenance-remediation.md)。

## 许可证

本项目仅供学习交流使用。
