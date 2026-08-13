#!/bin/sh
set -eu

root_dir="${1:-/opt/expert-chat-authservice}"
upstream="$root_dir/upstream"

test -d "$upstream/.git"
cd "$upstream"
if git apply --reverse --check ../expert-chat.patch >/dev/null 2>&1; then
  : # already applied
else
  git apply --check ../expert-chat.patch
  git apply ../expert-chat.patch
fi

commit="$(git rev-parse --short=12 HEAD)"
printf '%s\n' "$commit" > ../UPSTREAM_COMMIT
install -d -m 700 ../secrets
if [ ! -s ../secrets/jwt_private.pem ]; then
  openssl genrsa -out ../secrets/jwt_private.pem 2048 >/dev/null 2>&1
  openssl rsa -in ../secrets/jwt_private.pem -pubout \
    -out ../secrets/jwt_public.pem >/dev/null 2>&1
fi
chmod 600 ../secrets/*

if [ ! -s ../.env ]; then
  db_password="$(openssl rand -hex 32)"
  oidc_key="$(openssl rand -base64 32 | tr -d '\n')"
  cat > ../.env <<EOF
DB_PASSWORD=$db_password
JWT_ISSUER=https://125.208.22.148
JWT_AUDIENCE=https://125.208.22.148
OIDC_ENCRYPTION_KEY=$oidc_key
ADMIN_BOOTSTRAP_USERNAME=wweiyi-admin
AUTH_BACKEND_IMAGE=expert-chat-authservice-backend:$commit
AUTH_FRONTEND_IMAGE=expert-chat-authservice-frontend:$commit
DOTNET_REGISTRY=mcr.microsoft.com
NODE_REGISTRY=docker.io
NGINX_REGISTRY=docker.io
NPM_REGISTRY=https://registry.npmjs.org
EOF
  chmod 600 ../.env
fi

if [ ! -s ../.initial_admin_password ]; then
  openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-' \
    > ../.initial_admin_password
  printf '\n' >> ../.initial_admin_password
  chmod 600 ../.initial_admin_password
fi

image="$(sed -n 's/^AUTH_BACKEND_IMAGE=//p' ../.env | tail -1)"
dotnet_registry="$(sed -n 's/^DOTNET_REGISTRY=//p' ../.env | tail -1)"
docker build -f ../Dockerfile.backend \
  --build-arg "DOTNET_REGISTRY=${dotnet_registry:-mcr.microsoft.com}" \
  -t "$image" backend
frontend_image="$(sed -n 's/^AUTH_FRONTEND_IMAGE=//p' ../.env | tail -1)"
node_registry="$(sed -n 's/^NODE_REGISTRY=//p' ../.env | tail -1)"
nginx_registry="$(sed -n 's/^NGINX_REGISTRY=//p' ../.env | tail -1)"
npm_registry="$(sed -n 's/^NPM_REGISTRY=//p' ../.env | tail -1)"
docker build -f ../Dockerfile.frontend \
  --build-arg "NODE_REGISTRY=${node_registry:-docker.io}" \
  --build-arg "NGINX_REGISTRY=${nginx_registry:-docker.io}" \
  --build-arg "NPM_REGISTRY=${npm_registry:-https://registry.npmjs.org}" \
  -t "$frontend_image" frontend
printf 'AuthService backend and frontend built from upstream %s\n' "$commit"
