# Expert Chat Gateway 架构约定（兼容模式）

> 自 2026-08-25 起，单用户产品主链路已切换到 `server/mcp_server`。本文描述的 Gateway、OIDC、Entitlement 和 REST 路由仅用于旧多用户部署兼容，不再是 Flutter 文档能力的默认入口。

## 目标与安全边界

Expert Chat 只配置一个 Gateway 地址。长文档分析、文档编辑、格式转换以及未来的 OCR、知识库和批量导出，都是同一 Gateway 下可独立演进的能力模块。

生产访问令牌来自 AuthService OIDC Authorization Code + PKCE。Gateway 验证 RS256 签名、Issuer、Audience、过期时间和 `sub`，再使用自己的 Entitlement 数据判断具体业务权限。AuthService 只负责身份，不代替下游业务授权。

旧 `GATEWAY_API_TOKEN` 只用于迁移。`GATEWAY_AUTH_MODE` 支持：

- `legacy`：只接受共享 Token，适合本机开发；
- `hybrid`：同时接受 OIDC 和旧 Token，用于平滑迁移；
- `oidc`：只接受 OIDC，最终生产形态。

## 公共协议

稳定接口位于 `/v1`：

```text
GET    /health
GET    /v1/health
GET    /v1/me
GET    /v1/capabilities

POST/GET/DELETE /mcp    标准 MCP Streamable HTTP

POST   /v1/files
DELETE /v1/files/{file_id}
POST   /v1/tasks
GET    /v1/tasks/{task_id}
GET    /v1/tasks/{task_id}/events
POST   /v1/tasks/{task_id}/cancel

POST   /v1/documents/edit
POST   /v1/documents/convert

GET    /admin
GET    /v1/admin/overview
GET    /v1/admin/users
PUT    /v1/admin/users/{owner_sub}
GET    /v1/admin/tasks
POST   /v1/admin/tasks/{task_id}/cancel
GET    /v1/admin/audit
```

除健康检查和管理页面静态 HTML 外，请求统一携带：

```http
Authorization: Bearer <AuthService access token>
```

能力发现只返回当前账户获准使用的能力，并同时返回账户、权限和配额摘要。客户端不得根据服务器名称猜能力。

`/mcp` 使用同一个 Bearer Token、账户 `sub`、Entitlement、配额和审计边界。MCP SDK 负责协议版本、能力发现、JSON-RPC、Tools、Resources 和 OAuth Protected Resource Metadata；`/v1/capabilities` 仍是 Expert Chat App 的兼容能力清单，不冒充 MCP 握手。

## 模块与授权边界

```text
Flutter GatewayConnection（唯一 URL + 异步 Token Provider）
        │
        ├── GatewayClient              能力发现 / 账户状态
        ├── LongTaskGatewayClient      files / tasks / events
        └── DocumentServiceClient      documents/edit / convert

FastAPI Gateway
        │
        ├── Core                       JWT / entitlement / quota / audit
        ├── Long-task module           持久任务与增量事件
        ├── Document module            编辑与格式转换
        ├── Document MCP adapter       tools / resources / resource_link
        └── Admin                      用户、任务、配额、审计
```

文件和任务都保存 `owner_sub`。所有读取、删除、事件查询和取消操作必须在 SQL 查询边界同时匹配资源 ID 与 `owner_sub`。`client_request_id` 只在同一所有者内唯一。

当前业务权限：

```text
gateway.use
files.write
tasks.create
tasks.read
tasks.cancel
documents.edit
documents.convert
```

## 文档 MCP 契约

MCP Adapter 复用文档模块的纯文件处理函数和 Gateway 的持久文件表，不复制第二套编辑实现：

```text
MCP Host
  └── /mcp
      ├── list_documents
      ├── inspect_document
      ├── edit_document(file_id, DocumentPatch)
      ├── convert_document(file_id, target_format)
      └── expert-chat://documents/{file_id}/{metadata|text|binary}
                         │
                         ▼
              Gateway files + owner_sub
                         │
                         ▼
                 doc_edit 共享核心
```

规则：

- `file_id` 必须在 SQL 查询边界同时匹配当前 Token 的 `sub`；
- `edit_document` 需要 `documents.edit`，`convert_document` 需要 `documents.convert`；
- 编辑和转换只生成新文件，不覆盖源文件；
- Tool 结果同时包含结构化元数据和指向二进制 Resource 的 `resource_link`；
- 文本 Resource 有长度上限并明确标记截断，二进制 Resource 保留原始内容；
- 新二进制文件仍走 `POST /v1/files`，因为 MCP 没有通用的远程二进制 Resource 写入原语。

管理员由 Gateway 自己的 `GATEWAY_ADMIN_SUBS` 或用户 Entitlement 标记决定，不读取 AuthService 管理员角色。默认配额按账户设置存储容量与并发任务数；上传、任务创建和其他请求另有用户级速率限制。

## 新增能力的固定步骤

1. 分配稳定 capability id，例如 `ocr`，不复用已有 id 改语义。
2. 在独立 `APIRouter` 实现 `/v1/...` 路由和测试。
3. 定义独立业务权限，并在服务端接口入口检查；对象查询还必须校验所有者。
4. 在 `MODULES` 中同时注册 router 与 `GatewayCapability`，不要维护第二份能力清单。
5. Flutter 新建 capability client，复用 `GatewayConnection`，不得新增另一套 URL/Token。
6. UI 只在能力发现包含该 id 时展示；未知能力安全忽略。
7. 增加权限不足、跨用户越权、错误 Audience 和管理员审计测试。
8. 破坏业务协议时提升 capability version；破坏公共协议时提升 `protocol_version`。

## 持久任务约束

- 创建任务携带 `client_request_id`，服务端按账户幂等返回同一任务。
- 输出片段先写数据库再对客户端可见。
- 客户端持久化 `task_id`、累计输出和 `last_event_id`。
- Access Token 过期时刷新后继续查询，不重新创建任务。
- 客户端断线或退到后台不取消任务；恢复后补齐事件与最终快照。
- Gateway 重启将未结束任务重新排队，且保留原 `owner_sub`。
- 当前 SQLite + 内置 Worker 必须单进程；横向扩容时替换为外部数据库、对象存储和队列，但保持 HTTP 协议不变。
