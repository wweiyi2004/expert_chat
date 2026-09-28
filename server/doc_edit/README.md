**旧文档 REST 适配层**

纯文件处理、解析预算和隔离进程现在位于 [`document_core`](../document_core)。主部署入口为 [`mcp_server`](../mcp_server)，此模块保留 REST 兼容和 Gateway 挂载。

使用 Python 3.12 和共同锁文件，从 `server` 目录启动：

```powershell
cd server
uv sync --frozen
$env:GATEWAY_API_TOKEN = 'change-me'
uv run --frozen uvicorn doc_edit.app.main:app --host 127.0.0.1 --port 8787
```

保留 `POST /v1/documents/edit` 和 `POST /v1/documents/convert`。协议见 [文档协议](../../docs/document-edit-contract.md)。

独立容器必须使用 `server` 作为构建上下文，以包含共享处理模块：

```sh
docker build -f doc_edit/Dockerfile -t expert-chat-doc-edit:local .
```

资源预算、依赖更新及运行数据备份见 [维护制度](../../docs/MAINTENANCE.md)。
