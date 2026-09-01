# Expert Chat MCP Server

面向单用户 Expert Chat 客户端的独立文档 MCP Server。运行它不会启动 Gateway REST、AuthService、管理页或后台任务；文件上传、检查、编辑、转换和下载都通过 MCP 完成。

Windows 和 Linux 都可以打成独立可执行文件，不要求目标机器安装 Python。

## 独立软件（推荐）

在对应系统上打包（PyInstaller 不能交叉编译：Windows 产物在 Windows 打，Linux 产物在 Linux 打）。在 `server` 目录执行：

```powershell
# Windows
.\mcp_server\packaging\build_windows.ps1
```

```bash
# Linux
chmod +x mcp_server/packaging/build_linux.sh
./mcp_server/packaging/build_linux.sh
```

产物在 `server/dist/expert-chat-mcp/`：

- Windows：`expert-chat-mcp.exe`
- Linux：`expert-chat-mcp`

首次运行会在同目录生成 `mcp.env`（含 Token）和 `mcp_data/`。把 Endpoint `http://127.0.0.1:8790/mcp` 和 Token 填进 App 设置即可。

```powershell
.\expert-chat-mcp.exe
.\expert-chat-mcp.exe --host 0.0.0.0 --port 8790
```

```bash
./expert-chat-mcp
./expert-chat-mcp --host 0.0.0.0 --port 8790
```

公网部署必须走 HTTPS，并设置 `MCP_PUBLIC_URL`、`MCP_ISSUER`、`MCP_ALLOWED_HOSTS`。

## 本地启动（源码）

```powershell
cd server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r mcp_server/requirements.txt

$env:MCP_API_TOKEN = 'change-me'
$env:MCP_DATA_DIR = './mcp_data'
uvicorn mcp_server.app.main:app --host 127.0.0.1 --port 8790 --workers 1
```

MCP Endpoint：`http://127.0.0.1:8790/mcp`。

## Docker

```bash
cd server
docker build -f mcp_server/Dockerfile -t expert-chat-mcp:1.0.0 .
docker run -d --name expert-chat-mcp --restart unless-stopped \
  -p 127.0.0.1:8790:8790 \
  -v /data/expert-chat-mcp:/data \
  -e MCP_API_TOKEN='replace-with-a-random-token' \
  expert-chat-mcp:1.0.0
```

公网部署必须使用 HTTPS，并设置 `MCP_PUBLIC_URL`、`MCP_ISSUER`、`MCP_ALLOWED_HOSTS`。`MCP_API_TOKEN` 不能为空，否则所有受保护的 MCP 请求都会被拒绝。

## Tools

- 客户端内部上传：`begin_upload`、`append_upload`、`finish_upload`、`abort_upload`
- 模型文档能力：`list_documents`、`inspect_document`、`edit_document`、`convert_document`
- 清理：`delete_document`

上传使用 1 MiB Base64 分块，仍然是标准 `tools/call`，不再依赖 `/v1/files` REST API。
