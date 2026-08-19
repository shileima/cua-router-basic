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

# Resolve the capability token for the protected /record endpoint. Priority:
# explicit token file → runtime dir override → cua-router-basic default runtime
# → /tmp fallback (mirrors daemon.sh cua_runtime_dir()).
cua_token_file() {
  if [ -n "${CUA_ROUTER_APP_SERVER_TOKEN_FILE:-}" ]; then
    printf '%s' "$CUA_ROUTER_APP_SERVER_TOKEN_FILE"
    return 0
  fi
  local runtime="${CUA_ROUTER_RUNTIME_DIR:-}"
  if [ -z "$runtime" ]; then
    if [ -f "$CUA_ROOT/runtime/app-server.token" ]; then
      runtime="$CUA_ROOT/runtime"
    else
      runtime="/tmp/cua-router-basic-runtime-$(id -u 2>/dev/null || printf '%s' "$USER")"
    fi
  fi
  printf '%s/app-server.token' "$runtime"
}

cua_read_token() {
  local f
  f="$(cua_token_file)"
  [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

# Check if a foreign (non-cua-router) process holds the event-stream observer.
# CUAService's event observer is a singleton: only one SkyComputerUseClient
# event-stream mcp can hold the connection at a time. If ChatGPT Desktop's
# app-server holds it, our recording will fail with -1743 or timeout.
check_foreign_event_observer() {
  local es_pids ppid pcmd
  es_pids="$(ps aux | grep '[S]kyComputerUseClient event-stream mcp' | awk '{print $2}' || true)"
  [ -z "${es_pids:-}" ] && return 0
  for pid in $es_pids; do
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -z "$ppid" ] && continue
    pcmd="$(ps -o command= -p "$ppid" 2>/dev/null)"
    # If parent is NOT our launchd-managed app-server, it's a foreign observer.
    case "$pcmd" in
      *"$CUA_ROOT/vendor/codex/bin/codex app-server"*) continue ;;  # ours
    esac
    echo "[event-stream] WARNING: foreign event-stream observer held by PID $pid (parent: $pcmd)" >&2
    echo "[event-stream] This will prevent recording. Killing it..." >&2
    kill "$pid" 2>/dev/null || true
  done
}

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
  if [ "$action" = "start" ]; then
    check_foreign_event_observer
  fi
  CUA_ROUTER_ENABLE_EVENT_STREAM=1 CUA_ROUTER_START_READINESS=off CUA_ROUTER_HEALTH_MODE=app-server \
    bash "$CUA_ROOT/scripts/daemon.sh" restart >/dev/null
  CUA_TOKEN="$(cua_read_token)"
  token_header=()
  [ -n "$CUA_TOKEN" ] && token_header=(-H "X-CUA-Token: $CUA_TOKEN")
  result="$(curl --fail --silent --show-error --max-time 45 \
    -X POST "$BASE/record" -H 'Content-Type: application/json' \
    "${token_header[@]}" \
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
