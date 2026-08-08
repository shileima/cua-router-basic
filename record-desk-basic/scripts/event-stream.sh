#!/usr/bin/env bash
# Record & Replay 录制控制入口。
#
# 关键架构：录制（event-stream）必须由 cua-router-basic 的 codex app-server 托管
# 才能工作——app-server 持有 CUAService 的事件观察者连接，录制事件才有地方串流。
# 裸 spawn `SkyComputerUseClient event-stream mcp` 会连上服务但永远收不到 XPC 回复
# （服务无处串流事件而挂起）。因此本脚本只做一件事：确保 cua-router 守护进程在跑，
# 然后把 start/status/stop 转成对 cua-router `/record` 端点的 HTTP 调用。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/resolve-cua-root.sh
source "$SCRIPT_DIR/lib/resolve-cua-root.sh"

PORT="${CUA_ROUTER_PORT:-18901}"
BASE="http://localhost:${PORT}"

usage() {
  cat <<EOF
Usage: $0 <start|status|stop>

  start    开始录制（最长 30 分钟）。经 cua-router app-server 驱动，无需系统弹窗。
  status   查询当前/最近一次录制状态，返回 metadataPath 与 eventsPath。
  stop     停止录制并返回产物路径（events.jsonl / session.json）。

环境变量：
  CUA_ROUTER_INSTALL_DIR   显式指定 cua-router-basic 根目录
  CUA_ROUTER_PORT          cua-router 监听端口（默认 18901）
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
action="$1"

case "$action" in
  -h|--help|help)
    usage
    exit 0
    ;;
  start|status|stop) ;;
  *)
    echo "Unknown action: $action" >&2
    usage >&2
    exit 1
    ;;
esac

CUA_ROOT="$(resolve_cua_root "$SKILL_ROOT")"

router_health_json() {
  curl -sf "$BASE/health" 2>/dev/null
}

router_healthy() {
  router_health_json \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ready") else 1)'
}

router_matches_cua_root() {
  local body
  body="$(router_health_json)" || return 1
  python3 - "$CUA_ROOT" "$body" <<'PY'
import json
import os
import sys

expected = os.path.realpath(sys.argv[1])
try:
    data = json.loads(sys.argv[2])
except Exception:
    sys.exit(1)

actual = data.get("skill_root") or ""
service = data.get("service") or ""
if service == "cua-router-basic" and actual and os.path.realpath(actual) == expected:
    sys.exit(0)
sys.exit(1)
PY
}

# 确保 cua-router 守护进程在跑（其 app-server 托管 event_stream mcp，并已连通 CUAService）。
if ! router_matches_cua_root; then
  if router_healthy; then
    rdb_info "cua-router 已运行但不是当前安装，正在切换到：$CUA_ROOT"
  else
    rdb_info "cua-router 未就绪，正在启动守护进程..."
  fi
  CUA_ROUTER_HEALTH_MODE=app-server bash "$CUA_ROOT/scripts/daemon.sh" start >&2 \
    || rdb_die "无法启动 cua-router 守护进程"
fi

router_matches_cua_root \
  || rdb_die "cua-router 服务身份校验失败，端口 ${PORT} 仍不是当前安装：$CUA_ROOT"

resp="$(curl -sf -X POST "$BASE/record" \
  -H 'Content-Type: application/json' \
  -d "{\"action\":\"$action\"}" 2>/dev/null)" \
  || rdb_die "调用 cua-router /record 失败（action=$action）"

# 结果是 MCP tool 结果：{ content:[{type:text,text:"<json>"}], isError? }。
# 抽出内层 text 打印，便于人和 Agent 直接读取 eventsPath/metadataPath/isRecording。
python3 - "$resp" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    obj = json.loads(raw)
except Exception:
    print(raw); sys.exit(0)
if obj.get("isError"):
    texts = [c.get("text", "") for c in obj.get("content", []) if c.get("type") == "text"]
    sys.stderr.write("[record-desk-basic] 录制调用返回错误：" + " ".join(texts) + "\n")
    sys.exit(1)
for c in obj.get("content", []):
    if c.get("type") == "text":
        print(c["text"])
PY
