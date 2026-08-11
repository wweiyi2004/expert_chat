# Document capability module

这里保留 Expert Chat Gateway 的文档编辑与格式转换实现。正式部署请运行统一的 [`server/gateway`](../gateway)，不要再为 App 配置第二套地址或 Token。

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
