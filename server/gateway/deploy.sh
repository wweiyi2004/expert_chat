#!/bin/sh
set -eu

image="${1:-expert-chat-gateway:0.3.1}"
container="expert-chat-gateway"
# Loopback by default: the public edge is Nginx (80/443) only.
# Override with GATEWAY_BIND_ADDRESS=0.0.0.0 only behind a private firewall.
bind_address="${GATEWAY_BIND_ADDRESS:-127.0.0.1}"
env_file="/etc/expert-chat-gateway.env"
data_dir="/data/expert-chat-gateway"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
rollback_container="${container}-rollback-${stamp}"

docker image inspect "$image" >/dev/null
test -f "$env_file"
test -d "$data_dir"

install -d -m 700 "$data_dir/backups"
docker exec -e BACKUP_PATH="/data/backups/gateway-before-${stamp}.sqlite3" \
  "$container" python -c \
  "import os, sqlite3; s=sqlite3.connect('/data/gateway.sqlite3'); d=sqlite3.connect(os.environ['BACKUP_PATH']); s.backup(d); d.close(); s.close()"
chmod 600 "$data_dir/backups/gateway-before-${stamp}.sqlite3"
cp -p "$env_file" "$data_dir/backups/expert-chat-gateway-${stamp}.env"

grep -q '^GATEWAY_AUTH_MODE=' "$env_file" || printf '\nGATEWAY_AUTH_MODE=hybrid\n' >> "$env_file"
grep -q '^GATEWAY_LEGACY_ADMIN=' "$env_file" || printf 'GATEWAY_LEGACY_ADMIN=true\n' >> "$env_file"
grep -q '^GATEWAY_LEGACY_OWNER_SUB=' "$env_file" || printf 'GATEWAY_LEGACY_OWNER_SUB=legacy-owner\n' >> "$env_file"
grep -q '^GATEWAY_RATE_LIMIT_REQUESTS=' "$env_file" || printf 'GATEWAY_RATE_LIMIT_REQUESTS=180\n' >> "$env_file"
grep -q '^GATEWAY_RATE_LIMIT_UPLOADS=' "$env_file" || printf 'GATEWAY_RATE_LIMIT_UPLOADS=20\n' >> "$env_file"

rollback() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  if docker inspect "$rollback_container" >/dev/null 2>&1; then
    docker rename "$rollback_container" "$container"
    docker start "$container" >/dev/null
  fi
}

docker stop -t 30 "$container" >/dev/null
docker rename "$container" "$rollback_container"
trap rollback INT TERM HUP

if ! docker run -d \
  --name "$container" \
  --restart unless-stopped \
  --cpus 1 \
  --memory 1536m \
  --pids-limit 256 \
  --log-driver local \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -p "$bind_address:8790:8790" \
  -v "$data_dir:/data" \
  --env-file "$env_file" \
  "$image" >/dev/null; then
  rollback
  exit 1
fi

ready=0
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8790/health > /tmp/gateway-health.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  docker logs --tail 50 "$container" >&2 || true
  rollback
  exit 1
fi

gateway_token="$(sed -n 's/^GATEWAY_API_TOKEN=//p' "$env_file" | tail -1)"
curl -fsS -H "Authorization: Bearer $gateway_token" \
  http://127.0.0.1:8790/v1/capabilities > /tmp/gateway-capabilities.json

trap - INT TERM HUP
cat /tmp/gateway-health.json
python3 -c \
  "import json; x=json.load(open('/tmp/gateway-capabilities.json')); print({'version': x['gateway_version'], 'capabilities': sorted(x['capabilities']), 'account': x['account']['sub'], 'admin': x['account']['is_admin']})"
docker ps --filter "name=$container" --format '{{.Names}} {{.Image}} {{.Status}}'
printf 'Rollback container retained: %s\n' "$rollback_container"
