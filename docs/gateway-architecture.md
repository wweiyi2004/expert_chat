# Expert Chat Gateway 架构约定

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
