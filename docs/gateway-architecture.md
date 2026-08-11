# Expert Chat Gateway 架构约定

## 目标

Expert Chat 只配置一个 Gateway 地址和一个访问 Token。长文档分析、文档编辑、格式转换以及未来的 OCR、知识库、批量导出等能力，都是同一 Gateway 下可独立演进的能力模块。

统一不等于巨型接口。公共层只负责连接、鉴权、版本和能力发现；业务模块拥有自己的路由、请求模型、任务与测试。

## 公共协议

所有稳定接口位于 `/v1`：

```text
GET    /v1/health
GET    /v1/capabilities

POST   /v1/files
DELETE /v1/files/{file_id}
POST   /v1/tasks
GET    /v1/tasks/{task_id}
GET    /v1/tasks/{task_id}/events
POST   /v1/tasks/{task_id}/cancel

POST   /v1/documents/edit
POST   /v1/documents/convert
```

除健康检查外统一使用：

```http
Authorization: Bearer <GATEWAY_API_TOKEN>
```

能力发现响应：

```json
{
  "protocol_version": 1,
  "gateway_version": "0.2.0",
  "capabilities": {
    "long_tasks": {"version": 1},
    "document_edit": {"version": 1, "formats": ["xlsx", "docx"]},
    "document_convert": {"version": 1}
  }
}
```

客户端不根据服务器名称猜能力，只根据 capability id 决定是否展示入口。

## 模块边界

```text
Flutter GatewayConnection（唯一 URL / Token）
        │
        ├── GatewayClient              能力发现
        ├── LongTaskGatewayClient      files / tasks / events
        └── DocumentServiceClient      documents/edit / convert

FastAPI Gateway
        │
        ├── Core                       auth / health / capabilities
        ├── Long-task module           持久任务与增量事件
        └── Document module            编辑与格式转换
```

服务端模块通过 `GatewayModuleRegistry` 注册。一个模块同时提交 `router` 和若干 `GatewayCapability`；同一注册表负责挂载路由与生成 `/v1/capabilities`，避免“接口已经上线但客户端发现不到”的双份配置。重复 capability id 会在启动时直接报错。

## 新增能力的固定步骤

1. 为能力分配稳定 id，例如 `ocr`，不复用已有 id 改语义。
2. 服务端在独立 `APIRouter` 中实现 `/v1/...` 路由和测试。
3. 在 `MODULES` 中添加一个 `GatewayModule`，同时注册 router、能力版本、限制及可选元数据；不要手写第二份能力发现响应。
4. Flutter 新建独立 capability client，参数统一使用 `GatewayConnection`，不得再创建 Base URL/Token 设置。
5. UI 只在能力清单包含该 id 时出现；未知能力安全忽略。
6. 协议发生破坏性变化时提升该能力的 version；公共协议破坏时提升 `protocol_version`。

## 持久任务约束

- 创建任务携带 `client_request_id`，服务端幂等返回同一任务。
- 输出片段先写数据库再对客户端可见。
- 客户端持久化 `task_id`、累计输出和 `last_event_id`。
- 客户端断线不取消任务；恢复后查询快照并补齐结果。
- Gateway 进程重启将未结束任务重新排队。横向扩容时应把内置 Worker 替换为外部队列，但保持 HTTP 协议不变。
