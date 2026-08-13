# Expert Chat Gateway

统一承载超长文件后台任务、文档编辑/转换、账户隔离、分类授权、配额和审计。它不是 OpenAI API 的复刻；上游只需提供兼容 `/chat/completions` 的模型接口。

完整模块规则见 [Gateway 架构约定](../../docs/gateway-architecture.md)。

## 本地开发

从 `server` 目录运行，以便加载 Gateway 与文档模块：

```powershell
cd server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r gateway/requirements.txt

$env:GATEWAY_AUTH_MODE = 'legacy'
$env:GATEWAY_API_TOKEN = 'change-me'
$env:LLM_BASE_URL = 'https://api.deepseek.com'
$env:LLM_API_KEY = 'your-upstream-key'
$env:LLM_MODEL = 'deepseek-chat'
uvicorn gateway.app.main:app --host 127.0.0.1 --port 8790 --workers 1
```

本机开发可在软件设置中填写 `http://127.0.0.1:8790` 和相同旧 Token。生产环境应使用 HTTPS + AuthService OIDC。

## 生产鉴权

推荐迁移期配置：

```env
GATEWAY_AUTH_MODE=hybrid
GATEWAY_API_TOKEN=<只供旧客户端迁移的随机值>
GATEWAY_LEGACY_OWNER_SUB=legacy-owner
GATEWAY_LEGACY_ADMIN=true

GATEWAY_OIDC_ISSUER=https://auth.example.com/
GATEWAY_OIDC_AUDIENCE=expert-chat
GATEWAY_OIDC_REQUIRE_AUDIENCE=true
GATEWAY_OIDC_JWKS_URL=https://auth.example.com/.well-known/jwks.json
GATEWAY_ADMIN_SUBS=<AuthService user sub，可逗号分隔>
```

迁移结束后改为 `GATEWAY_AUTH_MODE=oidc` 并删除 `GATEWAY_API_TOKEN`。不要把 AuthService 的管理员角色当成 Gateway 业务权限；Gateway 的 Entitlement 表才是能力、配额与管理员权限的来源。

## Docker 与升级

```bash
cd server
docker build -f gateway/Dockerfile -t expert-chat-gateway:0.3.1 .
docker run -d --name expert-chat-gateway \
  --restart unless-stopped --cpus 1 --memory 1536m \
  -p 127.0.0.1:8790:8790 \
  -v /data/expert-chat-gateway:/data \
  --env-file /etc/expert-chat-gateway.env \
  expert-chat-gateway:0.3.1
```

[`deploy.sh`](deploy.sh) 会先在线备份 SQLite 与环境文件，保留旧容器用于回滚，再健康检查新版本。公网只应开放 Nginx 的 80/443，8790 绑定回环地址。

## 管理能力

- 管理页面：`GET /admin`
- 当前账户：`GET /v1/me`
- 总览：`GET /v1/admin/overview`
- 用户、权限与配额：`GET/PUT /v1/admin/users`
- 全部任务与强制取消：`GET /v1/admin/tasks`、`POST .../cancel`
- 审计：`GET /v1/admin/audit`

管理页面可直接通过 AuthService OIDC + PKCE 登录，并在 401 时刷新一次 Token。Access/Refresh Token 只保存在当前浏览器标签页的 `sessionStorage`；手工粘贴 Token 仅作为运维回退。

## 关键环境变量

| 名称 | 默认值 | 说明 |
|---|---:|---|
| `GATEWAY_DATA_DIR` | `./data` | SQLite、上传与临时目录 |
| `GATEWAY_AUTH_MODE` | `legacy` | `legacy` / `hybrid` / `oidc` |
| `GATEWAY_API_TOKEN` | 空 | 旧客户端迁移 Token |
| `GATEWAY_OIDC_ISSUER` | 空 | JWT Issuer，必须精确匹配 |
| `GATEWAY_OIDC_AUDIENCE` | 空 | 期望 Audience |
| `GATEWAY_ADMIN_SUBS` | 空 | 初始 Gateway 管理员 `sub` |
| `GATEWAY_DEFAULT_PERMISSIONS` | 全部现有能力 | 新账户默认业务权限 |
| `GATEWAY_DEFAULT_STORAGE_MB` | `512` | 新账户默认存储配额 |
| `GATEWAY_DEFAULT_CONCURRENT_TASKS` | `2` | 新账户并发任务配额 |
| `GATEWAY_RATE_LIMIT_REQUESTS` | `180` | 用户每分钟普通请求上限 |
| `GATEWAY_RATE_LIMIT_UPLOADS` | `20` | 用户每分钟上传上限 |
| `GATEWAY_MAX_FILE_MB` | `50` | 单文件上限 |
| `GATEWAY_CHUNK_CHARS` | `12000` | 文档分块字符数 |
| `GATEWAY_CONCURRENCY` | `2` | 全局同时处理任务数 |
| `GATEWAY_TASK_RETENTION_DAYS` | `30` | 终态任务保留天数；`0` 不清理 |
| `LLM_BASE_URL` | 空 | 上游兼容 API Base URL |
| `LLM_API_KEY` | 空 | 仅服务器保存的上游密钥 |
| `LLM_MODEL` | 空 | 长任务默认模型 |

当前 Worker 内置于单进程，并使用 SQLite 恢复重启时未完成的任务，因此必须使用 `--workers 1`。
