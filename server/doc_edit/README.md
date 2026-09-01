# Document capability module

这里提供文档编辑与格式转换的纯文件处理核心。当前正式部署运行独立 [`server/mcp_server`](../mcp_server)，由 MCP Tools 调用本模块；Gateway REST 入口仅保留兼容。

模块仍可独立启动，主要用于兼容旧部署和开发调试：

```powershell
cd server/doc_edit
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
$env:GATEWAY_API_TOKEN = 'change-me'
uvicorn app.main:app --host 0.0.0.0 --port 8787
```

正式 Gateway 会直接挂载本模块导出的 `APIRouter`：

- `POST /v1/documents/edit`
- `POST /v1/documents/convert`

协议见 [`docs/document-edit-contract.md`](../../docs/document-edit-contract.md)，模块扩展规范见 [`docs/gateway-architecture.md`](../../docs/gateway-architecture.md)。
