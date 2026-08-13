#!/bin/sh
set -eu

root_dir="${1:-/opt/expert-chat-authservice}"
cd "$root_dir"
umask 077

password="$(tr -d '\r\n' < .initial_admin_password)"
export EXPERT_CHAT_INITIAL_PASSWORD="$password"
python3 - <<'PY' > .register-request.json
import json, os
print(json.dumps({
    "username": "wweiyi-admin",
    "displayName": "Gateway 管理员",
    "email": "admin@wweiyi.com",
    "password": os.environ["EXPERT_CHAT_INITIAL_PASSWORD"],
}, ensure_ascii=False))
PY
python3 - <<'PY' > .login-request.json
import json, os
print(json.dumps({
    "email": "admin@wweiyi.com",
    "password": os.environ["EXPERT_CHAT_INITIAL_PASSWORD"],
}))
PY
unset EXPERT_CHAT_INITIAL_PASSWORD password

register_status="$(curl -sS -o .register-response.json -w '%{http_code}' \
  -H 'Content-Type: application/json' --data-binary @.register-request.json \
  http://127.0.0.1:8080/api/v1/auth/register)"
if [ "$register_status" != 200 ] && [ "$register_status" != 409 ]; then
  printf 'Admin registration failed with HTTP %s\n' "$register_status" >&2
  exit 1
fi

# Admin promotion is deliberately DB-backed and performed at application start.
docker compose -p expert-chat-auth -f compose.yml restart backend >/dev/null
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1 && break
  sleep 1
done

login_status="$(curl -sS -o .login-response.json -w '%{http_code}' \
  -H 'Content-Type: application/json' --data-binary @.login-request.json \
  http://127.0.0.1:8080/api/v1/auth/login)"
if [ "$login_status" != 200 ]; then
  printf 'Admin login failed with HTTP %s\n' "$login_status" >&2
  exit 1
fi

access_token="$(python3 -c "import json; print(json.load(open('.login-response.json'))['accessToken'])")"
admin_sub="$(python3 -c "import json; print(json.load(open('.login-response.json'))['userId'])")"
printf '%s\n' "$admin_sub" > .gateway_admin_sub

cat > .oidc-client-request.json <<'EOF'
{
  "clientId": "expert-chat",
  "displayName": "Expert Chat",
  "type": "public",
  "redirectUris": [
    "expertchat://auth/callback",
    "https://125.208.22.148/gateway/admin"
  ],
  "scopes": ["openid", "profile", "email", "offline_access"]
}
EOF

oidc_status="$(curl -sS -o .oidc-client-response.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $access_token" \
  --data-binary @.oidc-client-request.json \
  http://127.0.0.1:8080/api/v1/admin/oidc-clients)"
if [ "$oidc_status" = 409 ]; then
  python3 - <<'PY' > .oidc-client-update.json
import json
x=json.load(open('.oidc-client-request.json'))
print(json.dumps({k:x[k] for k in ('displayName','redirectUris','scopes')}))
PY
  oidc_status="$(curl -sS -o .oidc-client-response.json -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $access_token" \
    --data-binary @.oidc-client-update.json \
    http://127.0.0.1:8080/api/v1/admin/oidc-clients/expert-chat)"
fi
if [ "$oidc_status" != 200 ]; then
  printf 'OIDC client provisioning failed with HTTP %s\n' "$oidc_status" >&2
  exit 1
fi
python3 - <<'PY'
import json
x=json.load(open('.oidc-client-response.json'))
client=x.get('client', x)
actual=set(client.get('redirectUris', []))
expected={'expertchat://auth/callback', 'https://125.208.22.148/gateway/admin'}
if actual != expected or client.get('type') != 'public':
    raise SystemExit('OIDC client redirect/type verification failed')
PY

rm -f .register-request.json .register-response.json .login-request.json \
  .login-response.json .oidc-client-request.json .oidc-client-update.json \
  .oidc-client-response.json
printf 'Admin ready: username=wweiyi-admin sub=%s\n' "$admin_sub"
printf 'OIDC client ready: expert-chat (public, PKCE)\n'
