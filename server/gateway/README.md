# Expert Chat Gateway

Expert Chat 的统一自建后端。一套地址和 Token 同时提供：

- 超长文件的持久化后台任务、增量事件和断线恢复；
- `xlsx` / `docx` / `pptx` / `txt` / `md` / `csv` / `tsv` 编辑；
- 支持格式间的文档转换；
- `/v1/capabilities` 能力发现，供未来继续添加 OCR、知识库等模块。

Gateway 不是 OpenAI API 的复刻。它面向 Expert Chat 的文件业务，上游模型可以是任意 OpenAI-compatible `/chat/completions` 服务。

完整扩展约定见 [`docs/gateway-architecture.md`](../../docs/gateway-architecture.md)。

## 本地运行

从 `server` 目录启动，以便 Gateway 同时加载长任务和文档模块：

```powershell
cd server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r gateway/requirements.txt

$env:GATEWAY_API_TOKEN = 'change-me'
$env:LLM_BASE_URL = 'https://api.deepseek.com'
$env:LLM_API_KEY = 'your-upstream-key'
$env:LLM_MODEL = 'deepseek-chat'
uvicorn gateway.app.main:app --host 0.0.0.0 --port 8790 --workers 1
```

然后在软件设置的「Expert Chat Gateway」中填写 `http://127.0.0.1:8790` 和相同 Token，点击「连接并发现能力」。也可以把上游换成 Ollama、vLLM 等兼容服务。

## Docker

同样从 `server` 目录构建：

```bash
cd server
docker build -f gateway/Dockerfile -t expert-chat-gateway .
docker run -d --name expert-chat-gateway \
  -p 8790:8790 -v expert-chat-data:/data \
  -e GATEWAY_API_TOKEN=change-me \
  -e LLM_BASE_URL=https://api.deepseek.com \
  -e LLM_API_KEY=your-upstream-key \
  -e LLM_MODEL=deepseek-chat \
  expert-chat-gateway
```

当前长任务 Worker 内置于单进程，并通过 SQLite 恢复服务重启时未完成的任务，因此必须使用 `--workers 1`。需要横向扩容时可把调度层替换为外部队列，客户端协议无需改变。

## 接口

- `GET /v1/health`
- `GET /v1/capabilities`
- `POST /v1/files`
- `DELETE /v1/files/{file_id}`
- `POST /v1/tasks`
- `GET /v1/tasks/{task_id}`
- `GET /v1/tasks/{task_id}/events?after=0`
- `POST /v1/tasks/{task_id}/cancel`
- `POST /v1/documents/edit`
- `POST /v1/documents/convert`

除健康检查外，请求统一使用 `Authorization: Bearer <GATEWAY_API_TOKEN>`。不设置 Token 时允许无鉴权访问，仅适合本机开发。

关键环境变量：

| 名称 | 默认值 | 说明 |
|---|---:|---|
| `GATEWAY_DATA_DIR` | `./data` | SQLite、上传文件与临时文档目录 |
| `GATEWAY_API_TOKEN` | 空 | 所有能力共用的客户端访问 Token |
| `LLM_BASE_URL` | 空 | 上游兼容 API Base URL |
| `LLM_API_KEY` | 空 | 上游密钥，只保存在服务器 |
| `LLM_MODEL` | 空 | 长任务默认模型 |
| `GATEWAY_MAX_FILE_MB` | `50` | 单文件上限 |
| `GATEWAY_CHUNK_CHARS` | `12000` | 文档分段字符数 |
| `GATEWAY_CONCURRENCY` | `2` | 同时处理的长任务数 |
