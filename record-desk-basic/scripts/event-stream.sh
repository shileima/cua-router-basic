#!/usr/bin/env bash
# Record & Replay 录制控制入口。
#
# Shell 与 stdio MCP 两种入口都通过 cua-router 的共享 app-server 会话控制录制，
# 避免宿主裸 spawn SkyComputerUseClient 绕过可信进程链和事件观察者上下文。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/resolve-cua-root.sh
source "$SCRIPT_DIR/lib/resolve-cua-root.sh"

PORT="${CUA_ROUTER_PORT:-18901}"
BASE="http://localhost:${PORT}"

usage() {
  cat <<EOF
Usage: $0 <start|status|stop|mcp>

  start    通过 cua-router 开始录制。
  status   通过 cua-router 查询录制状态。
  stop     通过 cua-router 停止录制并返回产物路径。
  mcp      以 stdio MCP server 暴露 event_stream_start/status/stop。

环境变量：
  CUA_ROUTER_INSTALL_DIR   显式指定 cua-router-basic 根目录
  CUA_ROUTER_PORT          cua-router 监听端口（默认 18901）
  CUA_ROUTER_INSTALL_DIR   mcp 代理启动/定位 cua-router 使用的技能目录
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
action="$1"

case "$action" in
  -h|--help|help)
    usage
    exit 0
    ;;
  start|status|stop|mcp) ;;
  *)
    echo "Unknown action: $action" >&2
    usage >&2
    exit 1
    ;;
esac

CUA_ROOT="$(resolve_cua_root "$SKILL_ROOT")"

if [ "$action" != "mcp" ]; then
  CUA_ROUTER_ENABLE_EVENT_STREAM=1 CUA_ROUTER_START_READINESS=off CUA_ROUTER_HEALTH_MODE=app-server \
    bash "$CUA_ROOT/scripts/daemon.sh" restart >/dev/null
  result="$(curl --fail --silent --show-error --max-time 45 \
    -X POST "$BASE/record" -H 'Content-Type: application/json' \
    -d "{\"action\":\"$action\"}")"
  if [ "$action" = "stop" ]; then
    CUA_ROUTER_ENABLE_EVENT_STREAM=0 CUA_ROUTER_START_READINESS=off CUA_ROUTER_HEALTH_MODE=app-server \
      bash "$CUA_ROOT/scripts/daemon.sh" restart >/dev/null || true
  fi
  printf '%s\n' "$result"
  exit 0
fi

if [ "$action" = "mcp" ]; then
  CUA_ROUTER_ENABLE_EVENT_STREAM=1 CUA_ROUTER_START_READINESS=off CUA_ROUTER_HEALTH_MODE=app-server \
    bash "$CUA_ROOT/scripts/daemon.sh" restart >/dev/null
  export RDB_CUA_ROOT="$CUA_ROOT"
  exec python3 "$SCRIPT_DIR/event-stream-mcp.py"
fi
