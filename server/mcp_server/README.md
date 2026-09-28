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
uv sync --frozen

$env:MCP_API_TOKEN = 'change-me'
$env:MCP_DATA_DIR = './mcp_data'
uv run --frozen uvicorn mcp_server.app.main:app --host 127.0.0.1 --port 8790 --workers 1
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

## 维护与恢复

开发/打包要求 Python 3.12、uv 0.11.2；依赖统一来自 `server/uv.lock` 和带哈希的 `requirements.lock`。不要分别手动升级不同入口的依赖副本。详见 [维护制度](../../docs/MAINTENANCE.md)。

`GET /health` 仅返回可用性，不包含文档、路径或令牌。容器使用 UID 10001，挂载目录需允许该 UID 读写。

上传中断会依据已提交偏移恢复；完成上传使用稳定目标和持久回执，重复完成不会重复创建文档。默认清理 24 小时前的暂存上传/回执，正式文档不会自动删除。解析、编辑和转换在有时间与内存限制的独立进程内执行。

打包后可在根目录运行隔离验收（只使用临时目录和回环地址）：

```powershell
uv run --project server --frozen python server/mcp_server/packaging/smoke.py server/dist/expert-chat-mcp/expert-chat-mcp.exe
```

Linux 使用同目录的 `expert-chat-mcp` 无扩展名文件。测试验证实际打包程序的上传、重复完成、子进程编辑、下载和删除。

打包器拒绝清理含 `mcp.env`、运行数据或未知文件的旧输出目录。部署时将程序复制到独立运行目录；不要在使用中的程序目录原地重新打包。需要保留旧输出时，可指定新的构建目录：

```powershell
.\mcp_server\packaging\build_windows.ps1 -DistDirectory E:\path\to\expert_chat\server\dist\new-build
```

Linux 脚本第一个参数可指定 `server/dist` 下的新目录。启动配置优先级为命令行 > 环境变量 > 配置文件 > 默认值；仅提供环境变量 Token 时不会把它写到程序旁的配置文件。
