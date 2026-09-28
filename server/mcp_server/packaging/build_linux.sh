#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$SERVER_ROOT"
test -f pyproject.toml
uv sync --frozen --group packaging
DIST_ROOT="$(realpath -m "${1:-$SERVER_ROOT/dist}")"
case "$DIST_ROOT" in "$SERVER_ROOT/dist"|"$SERVER_ROOT/dist/"*) ;; *) echo 'Output must stay in server/dist' >&2; exit 1 ;; esac
uv run --frozen --group packaging python mcp_server/packaging/check_output.py "$DIST_ROOT/expert-chat-mcp"
uv run --frozen --group packaging pyinstaller --noconfirm --clean \
  --distpath "$DIST_ROOT" \
  --workpath "$SERVER_ROOT/build/pyinstaller" \
  "$SCRIPT_DIR/expert-chat-mcp.spec"
OUT="$DIST_ROOT/expert-chat-mcp"
cp "$SCRIPT_DIR/mcp.env.example" "$OUT/mcp.env.example"
"$OUT/expert-chat-mcp" --version
echo "Built $OUT/expert-chat-mcp"
