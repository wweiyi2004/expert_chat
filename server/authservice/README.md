# AuthService 集成层

本目录把上游 [shenxianovo/AuthService](https://github.com/shenxianovo/AuthService) 作为独立身份服务接入 Expert Chat，不复制其源码。

## 边界

- AuthService：账户、密码/第三方登录、会话、OIDC、Token 与 OIDC Client 管理；
- Gateway：按 JWT `sub` 隔离文件和任务，并管理业务权限、配额、管理员与审计；
- Flutter：Authorization Code + PKCE 登录，使用 SecureStorage 保存 Access/Refresh Token，按需自动刷新。

AuthService 明确不承担下游 RBAC。每个其他项目都可以注册自己的 Client ID、Redirect URI 和 Audience，并在自己的数据库里管理 Entitlement。

## 为什么有补丁

[`expert-chat.patch`](expert-chat.patch) 只做两项兼容性改动：

1. 给 OIDC access token 设置当前 Client ID 为资源 Audience，使 Gateway 能拒绝签给其他项目的 Token；
2. 允许 public + PKCE 客户端使用 RFC 8252 私有 URI scheme，例如 `expertchat://auth/callback`，同时仍拒绝 confidential client 的自定义 scheme 和非 loopback HTTP。

升级上游时先执行 `git apply --check ../expert-chat.patch`；若失败，必须人工复核对应安全语义，不可直接跳过。

## 部署

```bash
git clone --depth 1 https://github.com/shenxianovo/AuthService.git \
  /opt/expert-chat-authservice/upstream
cp server/authservice/* /opt/expert-chat-authservice/
chmod 700 /opt/expert-chat-authservice/*.sh

/opt/expert-chat-authservice/bootstrap.sh /opt/expert-chat-authservice
cd /opt/expert-chat-authservice
docker compose -p expert-chat-auth -f compose.yml up -d --pull never
/opt/expert-chat-authservice/provision-expert-chat.sh
/opt/expert-chat-authservice/smoke-oidc.sh
```

`bootstrap.sh` 幂等应用补丁、生成 RSA/数据库/OIDC 密钥并构建前后端；生成的 `.env`、`secrets/` 与 `.initial_admin_password` 权限均应为 root-only，绝不能提交 Git。

默认容器上限约为：PostgreSQL 640 MiB、后端 1 GiB、前端 192 MiB。前端只绑定 `127.0.0.1:8080`，由 Nginx 提供公网 HTTPS。

## 当前 Expert Chat OIDC 参数

```text
Client ID    expert-chat
Client type  public（无 Client Secret）
Redirect URI expertchat://auth/callback（客户端）
             https://125.208.22.148/gateway/admin（管理页）
Scopes       openid profile email offline_access
Audience     expert-chat
```

初始管理员用户名为 `wweiyi-admin`，邮箱为 `admin@wweiyi.com`。初始密码只保存在服务器 `/opt/expert-chat-authservice/.initial_admin_password`；首次登录后应修改。

## 备份和回滚

升级前至少备份：

- Compose volume `expert-chat-auth_db-data`；
- `.env`、`secrets/`、`.gateway_admin_sub`；
- 当前上游提交号 `UPSTREAM_COMMIT`；
- 当前 backend/frontend 镜像标签。

回滚时恢复相同数据库卷、密钥和旧镜像，不要重新生成 RSA/OIDC 密钥，否则现有会话与 Token 会全部失效。

当前部署的 root-only 基线备份位于 `/opt/expert-chat-authservice/backups/`；数据库使用 PostgreSQL custom-format dump，可先用 `pg_restore -l` 做目录校验。
