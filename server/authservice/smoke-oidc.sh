#!/bin/sh
set -eu

root_dir="${1:-/opt/expert-chat-authservice}"
base_url="${2:-https://125.208.22.148}"
temp_dir="$(mktemp -d /tmp/expert-chat-oidc.XXXXXX)"
trap 'case "$temp_dir" in /tmp/expert-chat-oidc.*) rm -rf -- "$temp_dir";; esac' EXIT
umask 077

password="$(tr -d '\r\n' < "$root_dir/.initial_admin_password")"
export EXPERT_CHAT_INITIAL_PASSWORD="$password"
python3 - <<'PY' > "$temp_dir/login.json"
import json, os
print(json.dumps({
    "email": "admin@wweiyi.com",
    "password": os.environ["EXPERT_CHAT_INITIAL_PASSWORD"],
}))
PY
unset EXPERT_CHAT_INITIAL_PASSWORD password

curl -fsS -c "$temp_dir/cookies" -H 'Content-Type: application/json' \
  --data-binary @"$temp_dir/login.json" \
  "$base_url/api/v1/auth/login" >/dev/null

verifier="$(openssl rand -base64 64 | tr -d '\n=/' | tr '+' '-')"
challenge="$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | \
  openssl base64 -A | tr '+/' '-_' | tr -d '=')"
state="$(openssl rand -hex 24)"
authorize_url="$(python3 - "$base_url" "$challenge" "$state" <<'PY'
import sys, urllib.parse
base, challenge, state = sys.argv[1:]
query = urllib.parse.urlencode({
    'client_id': 'expert-chat',
    'redirect_uri': 'expertchat://auth/callback',
    'response_type': 'code',
    'scope': 'openid profile email offline_access',
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
    'state': state,
})
print(base + '/connect/authorize?' + query)
PY
)"

status="$(curl -sS -b "$temp_dir/cookies" -D "$temp_dir/authorize.headers" \
  -o "$temp_dir/authorize.body" -w '%{http_code}' "$authorize_url")"
if [ "$status" != 302 ]; then
  printf 'Authorization failed with HTTP %s\n' "$status" >&2
  exit 1
fi
location="$(sed -n 's/^[Ll]ocation: //p' "$temp_dir/authorize.headers" | tr -d '\r' | tail -1)"
export OIDC_LOCATION="$location" OIDC_EXPECTED_STATE="$state"
code="$(python3 - <<'PY'
import os, urllib.parse
uri=urllib.parse.urlparse(os.environ['OIDC_LOCATION'])
params=urllib.parse.parse_qs(uri.query)
if params.get('state', [''])[0] != os.environ['OIDC_EXPECTED_STATE']:
    raise SystemExit('OIDC state mismatch')
print(params.get('code', [''])[0])
PY
)"
unset OIDC_LOCATION OIDC_EXPECTED_STATE
test -n "$code"

curl -fsS -o "$temp_dir/token.json" \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode client_id=expert-chat \
  --data-urlencode redirect_uri=expertchat://auth/callback \
  --data-urlencode "code=$code" \
  --data-urlencode "code_verifier=$verifier" \
  "$base_url/connect/token"

access_token="$(python3 -c "import json; print(json.load(open('$temp_dir/token.json'))['access_token'])")"
curl -fsS -H "Authorization: Bearer $access_token" \
  "$base_url/gateway/v1/me" > "$temp_dir/me.json"
curl -fsS -H "Authorization: Bearer $access_token" \
  "$base_url/gateway/v1/admin/overview" > "$temp_dir/overview.json"
python3 - "$temp_dir/token.json" "$temp_dir/me.json" <<'PY'
import base64, json, sys
tokens=json.load(open(sys.argv[1]))
payload=tokens['access_token'].split('.')[1]
payload += '=' * (-len(payload) % 4)
claims=json.loads(base64.urlsafe_b64decode(payload))
me=json.load(open(sys.argv[2]))
assert claims['sub'] == me['sub']
assert claims['aud'] == 'expert-chat' or 'expert-chat' in claims['aud']
assert me['auth_kind'] == 'oidc'
print({
    'sub': me['sub'],
    'audience': claims['aud'],
    'auth_kind': me['auth_kind'],
    'is_admin': me['is_admin'],
})
PY
