#!/usr/bin/env bash
# cua-router 守护进程管理：start / stop / status / restart
# 使用 nohup 脱离 Shell，避免 Agent 命令结束后 SIGHUP 杀进程。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
PORT="${CUA_ROUTER_PORT:-18901}"
PID_FILE="${CUA_ROUTER_PID_FILE:-/tmp/cua-router.pid}"
LOG_FILE="${CUA_ROUTER_LOG_FILE:-/tmp/cua-router.log}"
LOCK_FILE="${CUA_ROUTER_LOCK_FILE:-/tmp/cua-router-${PORT}.lock}"
BASE="http://localhost:${PORT}"
LOCK_HELD=0
APP_SERVER_PORT="${CUA_ROUTER_APP_SERVER_PORT:-$((PORT + 1))}"
APP_SERVER_WS="ws://127.0.0.1:${APP_SERVER_PORT}"
APP_SERVER_LABEL="com.meituan.cua-router.app-server.${PORT}"
APP_SERVER_LOG="${CUA_ROUTER_APP_SERVER_LOG:-/tmp/cua-router-app-server-${PORT}.log}"

CUA_SERVICE_BUNDLE_ID="${CUA_SERVICE_BUNDLE_ID:-com.openai.sky.CUAService}"
CUA_SERVICE_SOCKET="${CUA_SERVICE_SOCKET:-$HOME/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock}"
CUA_SERVICE_WAIT_SECS="${CUA_SERVICE_WAIT_SECS:-20}"

cua_runtime_dir() {
  if [ -n "${CUA_ROUTER_RUNTIME_DIR:-}" ]; then
    printf '%s' "$CUA_ROUTER_RUNTIME_DIR"
    return 0
  fi

  local default_runtime="$SKILL_ROOT/runtime"
  local probe="$default_runtime/.write-test"
  if mkdir -p "$default_runtime" 2>/dev/null && (: > "$probe") 2>/dev/null; then
    rm -f "$probe"
    printf '%s' "$default_runtime"
    return 0
  fi

  printf '/tmp/cua-router-basic-runtime-%s' "$(id -u 2>/dev/null || printf '%s' "$USER")"
}

export_cua_runtime_dir() {
  CUA_ROUTER_RUNTIME_DIR="$(cua_runtime_dir)"
  export CUA_ROUTER_RUNTIME_DIR
}

router_health_json() {
  curl -sf "$BASE/health" 2>/dev/null
}

# 浅探针（liveness）：仅验证 HTTP + app-server + node_repl 能跑 JS。
health_check() {
  if [ "${CUA_ROUTER_HEALTH_MODE:-exec}" = "app-server" ]; then
    router_health_json \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ready") else 1)'
    return $?
  fi

  curl -sf -X POST "$BASE/exec" \
    -H 'Content-Type: application/json' \
    -d '{"code":"nodeRepl.write(\"ok\")","timeout_ms":8000}' \
    2>/dev/null | grep -qE '"text"[[:space:]]*:[[:space:]]*"ok"'
}

router_identity_matches_current() {
  local body
  body="$(router_health_json)" || return 1
  python3 - "$SKILL_ROOT" "$body" <<'PY'
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

router_is_cua_service() {
  local body
  body="$(router_health_json)" || return 1
  python3 - "$body" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("service") == "cua-router-basic" else 1)
PY
}

active_router_pid() {
  local body
  body="$(router_health_json)" || return 1
  python3 - "$body" <<'PY'
import json
import sys

try:
    pid = int(json.loads(sys.argv[1]).get("pid", 0))
except Exception:
    sys.exit(1)
if pid > 1:
    print(pid)
else:
    sys.exit(1)
PY
}

router_identity_summary() {
  local body
  body="$(router_health_json)" || {
    echo "[cua-router] active service identity: unavailable"
    return 1
  }
  python3 - "$SKILL_ROOT" "$body" <<'PY'
import json
import os
import sys

expected = os.path.realpath(sys.argv[1])
try:
    data = json.loads(sys.argv[2])
except Exception as exc:
    print(f"[cua-router] active service identity: invalid health response ({exc})")
    print(f"[cua-router] expected root: {expected}")
    sys.exit(1)

actual = data.get("skill_root") or "<unknown>"
version = data.get("version") or "<unknown>"
pid = data.get("pid") or "<unknown>"
print(f"[cua-router] active service: root={actual} version={version} pid={pid}")
print(f"[cua-router] expected root: {expected}")
PY
}

# 深探针（readiness）：调用 /ready，真正强制 sky 原生管道连一次 CUAService。
health_check_deep() {
  curl -sf -X POST "$BASE/ready" \
    -H 'Content-Type: application/json' -d '{"deep":true}' \
    2>/dev/null | grep -qE '"ready"[[:space:]]*:[[:space:]]*true'
}

# CUAService 后台服务是否已在 listen（socket 文件存在）。
cua_service_running() {
  [ -S "$CUA_SERVICE_SOCKET" ]
}

cua_service_app_path() {
  local p="$SKILL_ROOT/vendor/computer-use/Codex Computer Use.app"
  [ -d "$p" ] && printf '%s' "$p"
}

# 预热 Sky Computer Use 后台服务（com.openai.sky.CUAService）：
# 它是按需启动、用完即退的后台 app，不常驻。若不提前拉起，首次 sky 调用要在
# native-pipe 硬编码的 5s 冷启动窗口内完成 open→初始化→建 socket，冷启动常超时
# → "Sky Computer Use native pipe startup failed"。这里提前把它叫起来并等 socket 就绪。
cua_service_ensure() {
  local force="${1:-0}"
  [ "$(uname -s)" = "Darwin" ] || return 0
  [ "$force" != "1" ] && cua_service_running && return 0

  if ! open -g -b "$CUA_SERVICE_BUNDLE_ID" >/dev/null 2>&1; then
    local app
    app="$(cua_service_app_path)"
    [ -n "$app" ] && open -g "$app" >/dev/null 2>&1 || true
  fi

  local i
  for i in $(seq 1 "$CUA_SERVICE_WAIT_SECS"); do
    cua_service_running && return 0
    sleep 1
  done
  return 1
}

pid_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

read_pid() {
  if [ -f "$PID_FILE" ]; then
    cat "$PID_FILE"
  fi
}

pid_matches_router() {
  local pid="$1" command
  pid_alive "$pid" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *"/scripts/cua-router.py --port $PORT"*) return 0 ;;
    *) return 1 ;;
  esac
}

pid_matches_current_install() {
  local pid="$1" command
  pid_matches_router "$pid" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *"$SCRIPT_DIR/cua-router.py --port $PORT"*) return 0 ;;
    *) return 1 ;;
  esac
}

acquire_lifecycle_lock() {
  local attempt owner
  command -v shlock >/dev/null 2>&1 || {
    echo "[cua-router] error: macOS shlock is required for lifecycle locking" >&2
    return 1
  }
  # Migrate stale directory locks created by versions before shlock was used.
  if [ -d "$LOCK_FILE" ]; then
    owner="$(cat "$LOCK_FILE/pid" 2>/dev/null || true)"
    if [ -z "$owner" ] || ! pid_alive "$owner"; then
      rm -rf "$LOCK_FILE"
    fi
  fi
  for attempt in $(seq 1 100); do
    if shlock -f "$LOCK_FILE" -p $$; then
      LOCK_HELD=1
      return 0
    fi
    sleep 0.1
  done
  owner="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  echo "[cua-router] error: lifecycle lock timeout: ${LOCK_FILE} (owner=${owner:-unknown})" >&2
  return 1
}

release_lifecycle_lock() {
  local owner
  if [ "$LOCK_HELD" -eq 1 ]; then
    owner="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    [ "$owner" = "$$" ] && rm -f "$LOCK_FILE"
    LOCK_HELD=0
  fi
}

cua_preflight_chrome_warn() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  [ -f "$SCRIPT_DIR/lib/preflight-chrome.sh" ] || return 0
  # shellcheck source=lib/preflight-chrome.sh
  source "$SCRIPT_DIR/lib/preflight-chrome.sh"
  CUA_ROUTER_CHROME_PREFLIGHT=warn cua_preflight_chrome warn || true
}

# 浅探活通过后调用：Chrome 预检 + 预热 CUAService + 深就绪校验。
cua_finalize_ready() {
  cua_preflight_chrome_warn

  if health_check_deep; then
    echo "[cua-router] cua readiness: ready (sky 原生管道已连通 CUAService)"
    return 0
  fi

  echo "[cua-router] cua readiness: 未就绪，正在预热 CUAService(${CUA_SERVICE_BUNDLE_ID})..." >&2
  cua_service_ensure 1 \
    || echo "[cua-router] warning: 等待 ${CUA_SERVICE_WAIT_SECS}s 后 CUAService socket 仍未出现" >&2

  local i
  for i in 1 2 3 4 5; do
    if health_check_deep; then
      echo "[cua-router] cua readiness: ready(预热后)"
      return 0
    fi
    sleep 1
  done

  echo "[cua-router] warning: cua 未就绪(sky 原生管道未连通)。执行 'bash $0 ready' 查看原因。" >&2
  return 1
}

start_readiness_enabled() {
  # A deep node_repl probe opens the single Sky event observer. Do not run it
  # automatically because Record & Replay must own that observer connection.
  [ "${CUA_ROUTER_START_READINESS:-off}" != "off" ]
}

app_server_start() {
  local runtime="$CUA_ROUTER_RUNTIME_DIR"
  local token_file="$runtime/app-server.token"
  local plist="$runtime/app-server.plist"
  local codex="$SKILL_ROOT/vendor/codex/bin/codex"

  python3 - "$runtime" "$token_file" "$plist" "$codex" "$APP_SERVER_WS" "$APP_SERVER_LABEL" "$APP_SERVER_LOG" <<'PY'
import os
import plistlib
import secrets
import sys

runtime, token_file, plist, codex, endpoint, label, log_file = sys.argv[1:]
os.makedirs(runtime, mode=0o700, exist_ok=True)
os.chmod(runtime, 0o700)
with open(token_file, "w", encoding="utf-8") as handle:
    handle.write(secrets.token_urlsafe(32))
os.chmod(token_file, 0o600)
payload = {
    "Label": label,
    "ProgramArguments": [
        codex, "app-server", "--listen", endpoint,
        "--ws-auth", "capability-token", "--ws-token-file", token_file,
    ],
    "EnvironmentVariables": {
        "CODEX_HOME": runtime,
        "HOME": os.path.expanduser("~"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    },
    "WorkingDirectory": os.path.dirname(os.path.dirname(codex)),
    "RunAtLoad": True,
    "KeepAlive": False,
    "StandardOutPath": log_file,
    "StandardErrorPath": log_file,
}
with open(plist, "wb") as handle:
    plistlib.dump(payload, handle)
PY

  launchctl bootout "gui/$(id -u)/$APP_SERVER_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  for _ in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:${APP_SERVER_PORT}/readyz" >/dev/null 2>&1; then
      export CUA_ROUTER_APP_SERVER_WS="$APP_SERVER_WS"
      export CUA_ROUTER_APP_SERVER_TOKEN_FILE="$token_file"
      return 0
    fi
    sleep 1
  done
  echo "[cua-router] bundled app-server failed to start; see ${APP_SERVER_LOG}" >&2
  return 1
}

app_server_stop() {
  launchctl bootout "gui/$(id -u)/$APP_SERVER_LABEL" >/dev/null 2>&1 || true
}

cmd_start() {
  if health_check; then
    if router_identity_matches_current; then
      echo "[cua-router] already healthy on ${BASE}"
      pid="$(read_pid || true)"
      [ -n "${pid:-}" ] && echo "[cua-router] pid=${pid}"
      if ! start_readiness_enabled; then
        return 0
      fi
      if cua_finalize_ready; then
        return 0
      fi
      if [ "${CUA_ROUTER_AUTO_RESTART_ON_NOT_READY:-0}" = "1" ] \
        && [ "${CUA_ROUTER_READY_RESTARTED:-0}" != "1" ]; then
        echo "[cua-router] sky 未就绪，自动重启 cua-router 以重建 app-server 连接..." >&2
        cmd_stop
        sleep 2
        CUA_ROUTER_READY_RESTARTED=1 cmd_start
        return $?
      fi
      return 0
    fi

    if router_is_cua_service && [ "${CUA_ROUTER_FORCE_TAKEOVER:-0}" != "1" ]; then
      echo "[cua-router] reusing healthy service from another install on ${BASE}"
      router_identity_summary
      echo "[cua-router] set CUA_ROUTER_FORCE_TAKEOVER=1 to replace it explicitly"
      if start_readiness_enabled; then
        cua_finalize_ready || true
      fi
      return 0
    fi

    if [ "${CUA_ROUTER_FORCE_TAKEOVER:-0}" != "1" ]; then
      echo "[cua-router] error: ${BASE} is occupied by another service; refusing automatic takeover" >&2
      return 1
    fi

    echo "[cua-router] explicit takeover requested; stopping the active service on ${BASE}..." >&2
    router_identity_summary >&2 || true
    cmd_stop
    sleep 2
    if health_check; then
      echo "[cua-router] error: failed to stop the active service on port ${PORT}" >&2
      return 1
    fi
  fi

  old_pid="$(read_pid || true)"
  if [ -n "${old_pid:-}" ]; then
    if pid_alive "$old_pid"; then
      if ! health_check; then
        if pid_matches_current_install "$old_pid" \
          || { [ "${CUA_ROUTER_FORCE_TAKEOVER:-0}" = "1" ] && pid_matches_router "$old_pid"; }; then
          echo "[cua-router] pid ${old_pid} alive but unhealthy, restarting..."
          kill "$old_pid" 2>/dev/null || true
          sleep 1
        else
          echo "[cua-router] foreign pid ${old_pid} is alive but unhealthy; refusing automatic takeover" >&2
          echo "[cua-router] set CUA_ROUTER_FORCE_TAKEOVER=1 to replace it explicitly" >&2
          return 1
        fi
      fi
    else
      rm -f "$PID_FILE"
    fi
  fi

  if ! vendor_ready "$SKILL_ROOT"; then
    echo "[cua-router] vendor missing, bootstrapping (auto)..." >&2
    # Intranet installs keep vendor download on the intranet (no GitHub).
    apply_intranet_release_base "$SKILL_ROOT"
    bash "$SCRIPT_DIR/install-full.sh" --skill-root "$SKILL_ROOT" --vendor-mode auto --no-cursor
  fi

  export_cua_runtime_dir
  echo "[cua-router] runtime=${CUA_ROUTER_RUNTIME_DIR}"
  python3 -c "import sys; sys.path.insert(0, '$SCRIPT_DIR'); import vendor_paths; vendor_paths.write_runtime_config()"
  app_server_start

  nohup python3 "$SCRIPT_DIR/cua-router.py" --port "$PORT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "[cua-router] started pid=$(cat "$PID_FILE"), log=${LOG_FILE}"

  for i in $(seq 1 45); do
    if health_check; then
      echo "[cua-router] ready after ${i}s"
      if start_readiness_enabled; then
        cua_finalize_ready || true
      fi
      return 0
    fi
    sleep 1
  done

  echo "[cua-router] warning: health check timeout, see ${LOG_FILE}" >&2
  return 1
}

cmd_stop() {
  local pid="" stopped=0

  if health_check; then
    if router_identity_matches_current || [ "${CUA_ROUTER_FORCE_TAKEOVER:-0}" = "1" ]; then
      pid="$(active_router_pid || true)"
    else
      echo "[cua-router] refusing to stop healthy service from another install on ${BASE}" >&2
      router_identity_summary >&2 || true
      echo "[cua-router] set CUA_ROUTER_FORCE_TAKEOVER=1 to stop it explicitly" >&2
      return 2
    fi
  else
    pid="$(read_pid || true)"
    if [ -n "${pid:-}" ] && ! pid_matches_current_install "$pid"; then
      if [ "${CUA_ROUTER_FORCE_TAKEOVER:-0}" != "1" ]; then
        echo "[cua-router] ignoring stale or foreign pid file: ${pid}" >&2
        pid=""
      elif ! pid_matches_router "$pid"; then
        echo "[cua-router] refusing takeover: pid ${pid} is not a cua-router on port ${PORT}" >&2
        pid=""
      fi
    fi
  fi

  if [ -n "${pid:-}" ] && ! pid_matches_router "$pid"; then
    echo "[cua-router] refusing to stop pid ${pid}: process identity is not cua-router on port ${PORT}" >&2
    return 1
  fi

  if [ -n "${pid:-}" ] && pid_alive "$pid" && kill "$pid" 2>/dev/null; then
    echo "[cua-router] stopping pid=${pid}"
    stopped=1
    for _ in 1 2 3 4 5; do
      pid_alive "$pid" || break
      sleep 1
    done
    if pid_alive "$pid"; then
      echo "[cua-router] warning: pid ${pid} did not exit after SIGTERM" >&2
      return 1
    fi
    echo "[cua-router] stopped pid=${pid}"
  fi

  if [ "$stopped" -eq 1 ] || ! health_check; then
    rm -f "$PID_FILE"
  fi
  app_server_stop
  if [ "$stopped" -eq 0 ]; then
    echo "[cua-router] not running"
  fi
}

cmd_status() {
  local deep=0
  [ "${1:-}" = "--deep" ] && deep=1

  pid="$(read_pid || true)"
  if health_check; then
    echo "[cua-router] running and healthy on ${BASE}"
    [ -n "${pid:-}" ] && echo "[cua-router] pid=${pid}"
    if router_identity_matches_current; then
      echo "[cua-router] identity: current install"
    else
      echo "[cua-router] warning: identity mismatch with current install" >&2
      router_identity_summary >&2 || true
    fi
    if cua_service_running; then
      echo "[cua-router] CUAService socket: present"
    else
      echo "[cua-router] CUAService socket: ABSENT (后台服务未运行)"
    fi
    if [ "$deep" -eq 1 ]; then
      if health_check_deep; then
        echo "[cua-router] readiness(deep): ready"
      else
        echo "[cua-router] readiness(deep): NOT ready — run 'bash $0 ready'"
      fi
    fi
    return 0
  fi
  echo "[cua-router] not responding on http://localhost:${PORT}"
  if [ -n "${pid:-}" ]; then
    if pid_alive "$pid"; then
      echo "[cua-router] pid=${pid} (process alive, service unhealthy)"
    else
      echo "[cua-router] stale pid file: ${pid}"
    fi
  fi
  return 1
}

# 打印 /ready 的结构化 JSON（ready/live/sky/socket/reason），供人或前端排障。
cmd_ready() {
  if ! health_check; then
    echo '{"ready":false,"live":false,"sky":false,"socket":false,"reason":"router_down"}'
    return 1
  fi
  curl -s -X POST "$BASE/ready" \
    -H 'Content-Type: application/json' -d '{"deep":true}' 2>/dev/null
  echo
}

cmd_restart() {
  cmd_stop
  sleep 2
  cmd_start
}

usage() {
  echo "Usage: $0 {start|stop|status [--deep]|ready|restart}" >&2
}

main() {
  cmd="${1:-start}"
  shift || true
  case "$cmd" in
    start|stop|restart)
      acquire_lifecycle_lock
      trap release_lifecycle_lock EXIT
      trap 'release_lifecycle_lock; exit 130' INT
      trap 'release_lifecycle_lock; exit 143' TERM
      ;;
  esac
  case "$cmd" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status "$@" ;;
    ready) cmd_ready ;;
    restart) cmd_restart ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
