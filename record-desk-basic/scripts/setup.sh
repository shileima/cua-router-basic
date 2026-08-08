#!/usr/bin/env bash
# 校验 record-desk-basic 依赖：确认能定位 cua-router-basic 的 SkyComputerUseClient，
# 并（可选）预热后台 CUAService。不重复 vendor。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/resolve-cua-root.sh
source "$SCRIPT_DIR/lib/resolve-cua-root.sh"

CUA_ROOT="$(resolve_cua_root "$SKILL_ROOT")"
CLIENT="$(sky_client_bin "$CUA_ROOT")"

rdb_info "cua-router-basic: $CUA_ROOT"
rdb_info "SkyComputerUseClient: $CLIENT"
[ -x "$CLIENT" ] || rdb_die "SkyComputerUseClient 不可执行。请先完成 cua-router-basic 的 vendor（见其 references/install.md）。"

# 探测 event-stream 子命令是否可用。
if "$CLIENT" event-stream --help >/dev/null 2>&1; then
  rdb_info "event-stream 子命令可用 ✅"
else
  rdb_die "该 SkyComputerUseClient 不支持 event-stream 子命令；请升级 cua-router-basic 的 vendor 二进制。"
fi

# 可选：拉起 cua-router 守护进程（其 codex app-server 托管 event_stream，并连通 CUAService）。
# 录制必须经这条链驱动；失败不致命（首次可能需在系统设置里授予屏幕录制/辅助功能）。
if [ "${RECORD_DESK_WARM:-1}" = "1" ]; then
  PORT="${CUA_ROUTER_PORT:-18901}"
  if bash "$CUA_ROOT/scripts/daemon.sh" start >/dev/null 2>&1; then
    rdb_info "cua-router 守护进程已就绪 ✅（http://localhost:${PORT}）"
    # 冒烟：经 /record 查一次状态，确认 event_stream 已被 app-server 托管。
    record_resp="$(curl -sf -X POST "http://localhost:${PORT}/record" \
      -H 'Content-Type: application/json' -d '{"action":"status"}' 2>/dev/null)" \
      || rdb_die "event_stream 冒烟检查失败：无法调用 /record status"
    if python3 - "$record_resp" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    obj = json.loads(raw)
except Exception:
    sys.exit(1)

if not obj.get("isError"):
    sys.exit(0)

text = " ".join(
    c.get("text", "")
    for c in obj.get("content", [])
    if isinstance(c, dict) and c.get("type") == "text"
)

# 空闲状态下 status 可能用账号 feature-flag 错误作探测结果；start 仍可正常发起。
if "Record & Replay is not enabled for this user" in text:
    sys.exit(0)

print(f"[record-desk-basic] /record status error: {text}", file=sys.stderr)
sys.exit(1)
PY
    then
      rdb_info "event_stream 已由 app-server 托管，/record 可用 ✅"
    else
      rdb_die "event_stream 已注册但不可用；请先修复 /record status 返回错误"
    fi
  else
    rdb_info "warning: cua-router 守护进程未就绪；首次录制前请先 bash \"$CUA_ROOT/scripts/daemon.sh\" start"
  fi
fi

rdb_info "record-desk-basic 依赖校验通过。运行录制： bash \"$SKILL_ROOT/scripts/event-stream.sh\" start"
