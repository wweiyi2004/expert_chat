#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$SERVER_ROOT"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
.venv/bin/python -m pip install -U pip
.venv/bin/python -m pip install -r mcp_server/requirements.txt
.venv/bin/python -m pip install pyinstaller

.venv/bin/pyinstaller --noconfirm --clean \
  --distpath "$SERVER_ROOT/dist" \
  --workpath "$SERVER_ROOT/build/pyinstaller" \
  "$SCRIPT_DIR/expert-chat-mcp.spec"

OUT="$SERVER_ROOT/dist/expert-chat-mcp"
cp "$SCRIPT_DIR/mcp.env.example" "$OUT/mcp.env.example"
chmod +x "$OUT/expert-chat-mcp"
echo "Built $OUT/expert-chat-mcp"
echo "Run that binary; it writes mcp.env beside itself on first launch."
