# Expert Chat 当前系统逻辑与演进架构

> 基线：Expert Chat `v3.3.0+4104`
>
> 最后更新：2026-08-17
>
> 本文区分“当前已经实现”与“下一阶段目标”，作为后续客户端、Gateway、AuthService 和服务器部署的统一依据。

## 1. 总体判断

Expert Chat 当前已经不是早期计划中的“纯客户端聊天工具”，而是一个：

> **本地优先的跨平台 AI 工作空间 + 可选的自建统一 Gateway。**

当前架构支持本地优先与多账户 Gateway 并存。聊天、学习、创作、记忆和科研终端主要在本机运行；需要服务端持续执行或处理二进制文档的能力进入 Gateway。AuthService 提供统一登录，Gateway 按 `sub` 完成账户隔离、分类授权、配额和审计。

现有设计中可以继续保留的部分：

- Flutter 客户端的分层结构与 Riverpod 依赖注入；
- Drift 本地数据模型及渐进迁移；
- 普通对话、学习、创作共用模型抽象；
- Gateway 的单入口、能力发现和模块注册约定；
- 长文件任务的持久化、幂等创建、重启恢复和取消；
- 文档编辑与格式转换的独立业务边界。

仍待后续阶段完成的部分：

- `hybrid` 模式仍保留共享 `GATEWAY_API_TOKEN` 供旧客户端迁移，尚未切到纯 OIDC；
- 普通聊天、学习、创作等仍直接从客户端调用模型，和 Gateway 形成两套执行路径；
- 本地数据没有账户归属，也没有跨设备同步协议。

身份与授权底座已经落地。下一阶段可集中于任务中心、文件库/知识库、增量事件消费和可选托管聊天，而不需要重做鉴权。

## 2. 产品能力地图

主界面采用语义化 Tab，手机使用底部导航，宽屏使用侧边导航；`IndexedStack` 保留各页面状态。

```text
Expert Chat
│
├── 会话
│   ├── 普通对话 / 深度思考
│   ├── 联网搜索与引用
│   ├── 本地文件上下文
│   ├── 图片理解与图片生成
│   ├── 文档编辑 / 格式转换
│   └── Gateway 长文件后台任务
│
├── 终端（实验功能开关控制）
│   ├── SSH / PTY
│   ├── tmux 会话
│   ├── 终端上下文分析
│   └── AI 命令建议 + 用户逐条审批
│
├── 学习（功能开关控制）
│   ├── AI 导师
│   ├── 课程树与节点学习
│   ├── 智能刷题与主观题批改
│   ├── 错题本
│   └── 复习卡与间隔重复
│
├── 创作（功能开关控制）
│   ├── 角色卡
│   ├── 世界信息
│   ├── 单角色 / 多角色故事
│   └── 导演故事与情节约束
│
└── 设置
    ├── 多模型 Provider
    ├── 上下文管理
    ├── 搜索、多媒体、语音
    ├── Expert Chat Gateway
    ├── 长期记忆
    ├── 外观与缓存
    └── GitHub Release / Shorebird 更新
```

这些模式不是独立 App，而是共享以下基础设施：

- `SettingsController`：模型、密钥、能力开关和 UI 设置；
- `ChatController`：对话树、流式生成、工具调用和持久化；
- `LlmProvider`：Chat Completions / Responses API 路由；
- `AppDatabase`：对话、消息、故事资产和学习数据；
- Gateway 客户端：能力发现、长任务、文档编辑和转换。

## 3. 当前客户端分层

```text
┌──────────────────────────────────────────────────────────┐
│ UI：features/                                            │
│ 会话 │ 学习 │ 创作 │ 科研终端 │ 记忆 │ 设置             │
├──────────────────────────────────────────────────────────┤
│ 状态：state/                                             │
│ Chat │ Settings │ Study │ Memory │ Character │ Research │
├──────────────────────────────────────────────────────────┤
│ 领域：domain/                                            │
│ LLM │ Context │ Search │ Document │ Story │ Study │ SSH │
├──────────────────────────────────────────────────────────┤
│ 数据：data/                                              │
│ Drift │ Repository │ SharedPreferences │ SecureStorage  │
└───────────────┬───────────────────────┬──────────────────┘
                │                       │
                │ HTTPS/SSE 直连        │ Gateway HTTP
                ▼                       ▼
        云端模型 / 搜索 / 多媒体     Expert Chat Gateway
```

### 3.1 启动流程

1. 初始化 Flutter Binding；Windows 当前临时关闭 Semantics，规避引擎 UIA 崩溃。
2. 加载 `SharedPreferences`。
3. 创建单一 `AppDatabase` 实例。
4. 将早期 JSON 对话迁移到 Drift。
5. 迁移旧学习数据和学习会话元数据。
6. 使用 `ProviderScope` 注入 Preferences 和数据库。
7. 首帧后初始化通知、GitHub Release 检查和 Shorebird 补丁检查。

### 3.2 本地存储职责

| 数据类型 | 当前存储 | 说明 |
|---|---|---|
| 对话、消息、分支 | Drift / SQLite | 本机唯一数据源 |
| 故事角色、世界信息 | Drift / SQLite | 与对话模式关联 |
| 课程、节点、卡片、错题 | Drift / SQLite | 细粒度实体行 |
| 学习会话元数据 | Drift / SQLite | 关联对话，删除对话时级联删除 |
| 长任务本地状态 | 消息 `longTaskJson` | 保存任务 ID、状态和远端文件 ID |
| 长期记忆 | 本地 Markdown 文件 | AI 只生成候选，用户确认后写入 |
| 普通设置和功能开关 | SharedPreferences | 不应存放敏感密钥 |
| 模型、搜索、多媒体密钥 | SecureStorage | 按用途或 Provider 保存 |
| Gateway Access/Refresh Token | SecureStorage | AuthService OIDC 会话；请求前自动刷新 |
| 旧 Gateway Token | SecureStorage | 仅 `hybrid` 迁移回退 |
| SSH 密码和私钥 | SecureStorage | 非敏感主机信息与秘密分离 |

当前所有本地数据都没有 `user_id`，卸载、换设备或清除应用数据后不会自动恢复。

## 4. 当前请求调用逻辑

### 4.1 普通聊天

```text
用户输入
  │
  ├── 本地读取附件并提取文本
  ├── 按需召回长期记忆
  ├── 组装系统提示词 / 模式提示词
  ├── 上下文窗口裁剪
  ├── 可选搜索编排或模型官方搜索
  ▼
RoutingLlmProvider
  ├── Chat Completions
  └── Responses API（服务商官方 web_search）
  ▼
客户端直接访问云端模型
  ▼
SSE 增量写入 UI，并定期保存到 Drift
```

普通聊天使用当前 Provider 的 `Base URL + API Key + model`，不经过 Expert Chat Gateway。

对话消息采用树结构：`parentId` 表示父消息，`activeChildren` 表示每个分叉当前选择的子节点，因此编辑消息、重新生成和切换回答分支不会破坏其他分支。

### 4.2 联网搜索

当前有两种路径：

1. 服务商官方搜索：满足条件时使用 Responses API 的 `web_search`。
2. 客户端编排搜索：使用 DuckDuckGo、Tavily、Exa、博查等后端，抓取或整理结果，再把带编号来源注入模型上下文。

搜索活动和引用随消息持久化。搜索后端、网页抓取和普通模型调用仍主要发生在客户端。

### 4.3 本地文件上下文

- PDF、DOCX、XLSX、PPTX 和文本文件先在本机解析；
- 提取文本随附件写入对话；
- 普通请求受上下文窗口限制，会截断或裁剪；
- 为了文档回写和长任务上传，部分附件还会把原始字节以 Base64 保存在消息 JSON 中。

这种方式离线性好，但大文件 Base64 会放大本地数据库，需要后续改为独立文件存储和引用。

### 4.4 学习与创作

学习和创作不是独立模型服务，目前都复用客户端活动 Provider：

- 学习：生成课程树、节点讲解、题目、主观题评分、复习卡和学习总结；
- 创作：角色、世界信息、情节约束、场景推进和多角色轮次；
- 结构化结果由客户端解析，失败时重试或使用本地回退结构；
- 超过 12000 字的课程材料目前先由客户端模型摘要，失败时截取前 12000 字。

因此，学习中的超长教材还没有自动转入 Gateway 长任务。

### 4.5 科研终端

```text
客户端 ──SSH──► 用户服务器 / tmux
   │
   ├── 用户选择终端上下文
   ├── 客户端模型生成 CommandProposal
   └── 用户查看、编辑、逐条批准后才写入 SSH
```

AI 不能直接调用 SSH 写入接口，审批对象是类型边界；这是应继续保留的安全规则。

### 4.6 多媒体与更新

- 视觉、图片生成、TTS 和 ASR 使用各自可选的 OpenAI-compatible 配置；
- API Key 保存在客户端 SecureStorage；
- 完整安装包通过 GitHub Releases 检查与下载；
- Dart 热更新通过 Shorebird 基座和 Patch 完成。

## 5. 当前 Gateway 逻辑

### 5.1 统一入口

客户端只配置一套 Gateway 地址，通过 `/v1/capabilities` 发现当前账户可用能力。请求令牌优先来自 AuthService，旧 Token 只作迁移回退：

```text
Expert Chat Gateway
│
├── Core
│   ├── /v1/health
│   ├── AuthService JWT / 旧 Token 迁移鉴权
│   ├── Entitlement / 配额 / 限流 / 审计
│   ├── /v1/me
│   └── 按账户过滤的 /v1/capabilities
│
├── long_tasks
│   ├── files
│   ├── tasks
│   ├── events
│   └── cancel
│
└── documents
    ├── document_edit
    └── document_convert

Admin
    ├── 用户、权限与配额
    ├── 全部任务与失败诊断
    └── 审计记录
```

新增模块应通过 `GatewayModuleRegistry` 同时注册路由和 capability，避免接口已经上线但能力发现未更新。

### 5.2 长文件任务

```text
App 上传原始文件
       │
       ▼
Gateway 保存文件记录和磁盘路径
       │
       ▼
创建任务（client_request_id 幂等）
       │
       ▼
解析文本 → 分块 → 逐块总结 → 多轮归并 → 最终回答
       │
       ▼
输出与事件先写 SQLite，再供 App 查询
       │
       ▼
App 轮询任务快照并更新消息
```

关键行为：

- 默认单文件上限 50 MB；
- 默认每块 12000 字符；
- 默认同时处理两个任务；
- 任务创建使用 `client_request_id` 防止客户端重试造成重复任务；
- App 持久化 `task_id`，重新启动后恢复轮询；
- Gateway 重启时把未完成任务重新排队；
- App 断线只显示重连状态，不会取消服务端任务；
- 完成或失败后，App 尝试删除本次上传的远端临时文件。

Gateway 已提供事件接口，但当前 App 主要轮询完整任务快照，没有按 `after=last_event_id` 增量回放事件。长输出越来越大时，应改为“事件增量 + 最终快照校正”。

### 5.3 文档服务

文档编辑和转换通过同步 Multipart 请求完成：

- 编辑：`POST /v1/documents/edit`；
- 转换：`POST /v1/documents/convert`；
- 支持 XLSX、DOCX、PPTX、TXT、MD、CSV、TSV；
- 临时目录按请求创建，响应完成后清理；
- 客户端会校验 capability、文件大小、错误结构和下载文件名。

文档能力适合短操作；如果未来加入 OCR、大批量转换或复杂 Office 生成，应统一转成持久任务，而不是无限提高 HTTP 超时。

### 5.4 当前部署约束

- SQLite 与内置异步 Worker 位于同一进程；
- 必须使用一个 Uvicorn worker；
- 不能用多个 Gateway 实例同时写同一个数据目录；
- 横向扩容时应引入外部数据库、对象存储和任务队列，但保持 `/v1` 客户端协议稳定。

## 6. 当前多账户鉴权与隔离

生产调用链为 `AuthService OIDC -> RS256 JWT -> Gateway`。Gateway 严格验证 `iss`、`aud`、签名、`exp`、`iat` 和 `sub`；文件与任务表都保存 `owner_sub`，所有对象查询在 SQL 边界同时匹配资源 ID 与账户。

```text
AuthService sub
   │
   ├── files.owner_sub
   ├── tasks.owner_sub + UNIQUE(owner_sub, client_request_id)
   ├── user_entitlements（权限 / 配额 / enabled / admin）
   └── audit_logs
```

现有数据库启动时自动补列并把历史记录归入 `GATEWAY_LEGACY_OWNER_SUB=legacy-owner`。`hybrid` 模式允许旧 Token 继续访问这个迁移账户；新 OIDC 用户只能看到自己的资源。最终切到 `oidc` 后即可彻底停用共享 Token。

## 7. AuthService 与 Gateway 架构

### 7.1 职责划分

```text
┌──────────────────────────────────────────────────────────┐
│ AuthService：身份与 OIDC 控制面                          │
│ 账户 │ 登录 │ 会话 │ OIDC Client │ Token │ API Key     │
└──────────────────────────┬───────────────────────────────┘
                           │ JWT：sub / aud / scope / exp
                           ▼
┌──────────────────────────────────────────────────────────┐
│ 业务服务：资源与数据面                                   │
│ Expert Chat Gateway │ 其他项目 A │ 其他项目 B            │
│ 各自验证 Token，并管理自己的业务权限和数据归属           │
└──────────────────────────────────────────────────────────┘
```

AuthService 负责：

- 注册、登录和第三方登录；
- 会话、刷新令牌、设备与撤销；
- 为 Expert Chat 和其他项目注册独立 OIDC Client；
- 签发 RS256 JWT；
- 为无人值守程序提供 API Key 换短期 JWT；
- 用独立 Client ID / Audience 区分用户正在访问哪个项目。

Expert Chat Gateway 负责：

- 验证 Issuer、签名、过期时间和 Audience；
- 检查每个接口要求的 Gateway Entitlement；
- 使用 `sub` 作为稳定用户 ID；
- 隔离文件、任务、事件、知识库和用量；
- 管理 Gateway 自己的业务权限、配额和审计。

AuthService 不应保存模型 API Key，不应代理聊天或文件业务；Gateway 也不应自行维护第二套用户名密码。

实现时以 AuthService 当前仓库和决策记录为准：

- [AuthService](https://github.com/shenxianovo/AuthService)
- [OIDC Provider 设计](https://github.com/shenxianovo/AuthService/blob/main/docs/adr-016-openiddict-oidc-provider.md)
- [API Key 换取短期 JWT](https://github.com/shenxianovo/AuthService/blob/main/docs/adr-009-api-key-exchange.md)
- [OIDC Client 管理与下游权限边界](https://github.com/shenxianovo/AuthService/blob/main/docs/adr-017-admin-role-and-ui-managed-oidc-clients.md)

### 7.2 客户端配置

移动端和桌面端属于公开客户端，不应内置 `client_secret`。推荐配置：

```text
AuthService Base URL    = https://125.208.22.148
OIDC Client ID          = expert-chat
Redirect URI            = expertchat://auth/callback
Scopes                  = openid profile email offline_access
Gateway Audience        = expert-chat
Gateway Base URL        = https://125.208.22.148/gateway
```

登录使用 Authorization Code + PKCE。Access Token 和 Refresh Token 存入 SecureStorage，Gateway 请求自动添加：

```http
Authorization: Bearer <AuthService access token>
```

共享 `GATEWAY_API_TOKEN` 只可保留为迁移期或内部运维凭据，不再作为普通用户入口。

### 7.3 服务分类与 Entitlement

每个项目是独立 OIDC Client，并拥有独立 Audience。AuthService 当前只签发身份/OIDC scope；Expert Chat 的业务权限由 Gateway 保存：

```text
gateway.use
files.write
tasks.create
tasks.read
tasks.cancel
documents.edit
documents.convert
```

未来可在 Gateway 增加：

```text
knowledge.read
knowledge.write
ocr.run
usage.read
admin.gateway
```

AuthService 项目明确把下游业务权限留给下游服务，因此当前管理页在 Gateway，而不是伪装成 AuthService 的角色或 scope。若未来需要一个面板跨项目统一授权，应增加独立 **Service Entitlement 控制面**，再把授权同步/查询到各下游服务。

推荐的授权分层：

```text
第一层：AuthService 的 OIDC Client 与 Audience 隔离项目
第二层：Gateway Entitlement 限制可调用的业务能力
第三层：Gateway 根据 sub 限制具体资源所有权
```

### 7.4 Gateway 数据迁移

当前关键表结构已经包含：

```text
files
  owner_sub NOT NULL

tasks
  owner_sub NOT NULL
  UNIQUE(owner_sub, client_request_id)

events
  通过 task_id 继承任务所有者
```

所有对象接口都必须同时匹配资源 ID 和用户：

```sql
SELECT *
FROM tasks
WHERE id = ? AND owner_sub = ?;
```

不能先按 ID 取出对象，再只在 UI 隐藏；所有权检查必须在服务端查询边界完成。

旧共享 Token 数据迁移时应显式指定一个迁移所有者，不能把历史任务自动暴露给所有新账户。

## 8. 当前已实现调用链

```text
用户
 │
 ▼
Expert Chat ──OIDC + PKCE──► AuthService
 │                              │
 │◄──── Access/Refresh Token ───┘
 │
 │ Bearer JWT
 ▼
Expert Chat Gateway
 │
 ├── 验证 issuer / signature / exp
 ├── 验证 audience / Gateway Entitlement
 ├── 读取 sub
 ├── 按 sub 隔离数据
 ├── 执行长任务 / 文档 / 知识库
 └── 使用服务器保存的上游模型密钥
```

其他项目复用同一个 AuthService，但使用各自的 Client ID、Redirect URI、Audience、OIDC Scope 和业务数据库。

## 9. 模型调用策略需要固定的产品决策

当前是混合模式：

```text
普通对话 / 学习 / 创作 ──► 客户端 BYOK 直连模型
长文件任务             ──► Gateway 使用服务器模型
```

接入账户系统后，建议正式定义两种运行方式，而不是悄悄混用：

### 个人 Provider 模式

- 用户在本机配置自己的模型 Base URL 和 API Key；
- 普通聊天、学习和创作继续直连；
- AuthService 只负责账户和 Gateway 服务授权；
- 密钥不进入 Gateway，也不跨设备同步。

### 托管服务模式

- 用户登录后使用服务器提供的模型；
- 普通聊天、学习和创作也通过 Gateway；
- 服务器按用户计量、限额和审计；
- 上游 Base URL 和 API Key 只保存在服务器。

推荐保留两种模式，由部署策略决定是否开放个人 Provider；不要强制所有用户把个人 API Key 上传服务器。

## 10. 当前结构风险与后续顺序

### 10.1 高优先级

1. **退出迁移模式**：确认旧客户端全部升级后，将 Gateway 从 `hybrid` 切到 `oidc` 并删除共享 Token。
2. **统一 Token 失败体验**：刷新令牌失效时明确回到登录状态，同时保留本地草稿和远端任务引用。
3. **明确模型运行模式**：区分个人 Provider 与托管服务，避免用户误以为所有功能都经过 Gateway。
4. **管理员易用性**：管理页面后续可直接复用 AuthService 登录会话，避免手工粘贴管理员 Access Token。

### 10.2 中优先级

1. `ChatController` 已超过 4600 行，承担会话、搜索、工具、图片、故事、文档和长任务编排，应逐步拆成用例服务。
2. `SettingsController` 同时管理模型、媒体、Gateway 和功能开关，应拆分账户设置、模型设置和能力设置。
3. Gateway `main.py` 同时包含 HTTP、SQLite、文件解析和任务执行；应将长任务拆成独立模块，真正与文档模块保持同一注册规范。
4. 客户端应消费增量事件接口，减少长输出轮询时反复下载完整文本。
5. 附件原始 Base64 应迁移到本地文件库，数据库只保存引用和校验信息。

### 10.3 后续扩展

- 统一任务中心；
- 文件库与对象存储；
- 知识库和引用定位；
- OCR；
- 用户配额、用量与审计；
- 多设备同步；
- 外部队列和横向扩容。

## 11. 实施状态与下一阶段

### 阶段 A：冻结协议（已完成）

- 明确 AuthService Issuer、Client ID、Redirect URI 和 Gateway Audience；
- 定义 Entitlement 清单和接口权限矩阵；
- Service Entitlement 已落在 Gateway；
- 定义个人 Provider / 托管服务两种模式。

### 阶段 B：Gateway 资源服务器（已完成）

- 增加 OIDC Discovery / JWKS 验证；
- 增加 `sub`、`aud` 与 Entitlement 校验；
- 数据库加入 `owner_sub`；
- 改造全部文件、任务、事件、取消和文档接口；
- 当前生产以 `hybrid` 运行，待旧客户端完成迁移后关闭共享 Token。

### 阶段 C：客户端登录（已完成）

- 增加 AuthService 配置与 OIDC PKCE；
- 增加登录、账户、退出和 Token 刷新；
- SecureStorage 保存令牌；
- Gateway 客户端改用用户 Access Token；
- 后台任务恢复时处理 Token 过期。

### 阶段 D：分类授权与多项目复用（Expert Chat 已完成）

- AuthService 注册 Expert Chat 与其他项目的独立 Client；
- Gateway 已落实 Entitlement、配额、管理员和审计；
- Gateway 为每个 capability 设置 required permission；
- 已增加跨用户越权、缺少权限和管理员边界测试；其他项目仍需各自注册 Client/Audience。

### 阶段 E：托管模型与云端产品能力

- 按产品决策把普通聊天、学习和创作接入 Gateway；
- 增加用量、配额、任务中心、知识库和跨设备同步；
- 再考虑外部数据库、对象存储与任务队列。

## 12. 验收底线

多账户版本发布前必须满足：

- App 安装包中没有 OIDC Client Secret；
- Gateway 不接受错误 Issuer、Audience、过期 Token 或缺少 Entitlement 的请求；
- 用户甲无法通过猜测 ID 读取、取消或删除用户乙的资源；
- `client_request_id` 只在同一用户内幂等；
- Token 刷新不会重复创建任务；
- Gateway 重启后任务仍归属于原用户；
- 服务端模型密钥不会返回客户端；
- AuthService 管理员角色不会被误用为 Gateway 业务权限；
- 旧共享 Token 数据有明确迁移所有者和回滚方案；
- 普通聊天到底是 BYOK 还是托管服务，在 UI 中明确可见。

## 13. 文档优先级

从本文开始，架构判断顺序为：

1. 当前代码与自动化测试；
2. 本文描述的当前逻辑和目标边界；
3. `docs/gateway-architecture.md` 的 Gateway 扩展协议；
4. 各功能专项设计和 Release Notes；
5. `PROJECT_PLAN.md` 仅作为早期历史计划，其中“纯客户端、无后端”已经过时。
