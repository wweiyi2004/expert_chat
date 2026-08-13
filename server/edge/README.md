# HTTPS 边缘入口

Nginx 为 AuthService 和 Gateway 提供统一 IP HTTPS：

```text
https://125.208.22.148/          -> AuthService 127.0.0.1:8080
https://125.208.22.148/gateway/  -> Gateway     127.0.0.1:8790
```

[`install-edge.sh`](install-edge.sh) 先加载仅 ACME 的 HTTP 配置，签发 Let’s Encrypt short-lived IP 证书，再切换完整反代，并建立每天两次的续期检查与 Nginx reload hook。

完整配置包含：HTTP 到 HTTPS 308、TLS 1.2/1.3、HSTS、安全响应头、55 MiB 请求上限、上传不缓冲、长任务超时，以及普通、登录/Token、上传三组限流。业务容器只绑定回环地址，公网不直接开放 8080/8790。

验证：

```bash
nginx -t
systemctl status expert-chat-certbot-renew.timer
certbot certificates
curl https://125.208.22.148/health
curl https://125.208.22.148/gateway/health
```
