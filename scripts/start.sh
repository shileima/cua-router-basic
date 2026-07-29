#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${CUA_ROUTER_PORT:-18901}"

if [ ! -x "$SKILL_ROOT/vendor/codex/bin/codex" ]; then
  echo "vendor 未就绪，正在执行 setup-vendor.sh..." >&2
  bash "$SCRIPT_DIR/setup-vendor.sh"
fi

exec python3 "$SCRIPT_DIR/cua-router.py" --port "$PORT"
