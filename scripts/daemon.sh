#!/usr/bin/env bash
# cua-router 守护进程管理：start / stop / status / restart
# 使用 nohup 脱离 Shell，避免 Agent 命令结束后 SIGHUP 杀进程。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
PORT="${CUA_ROUTER_PORT:-18901}"
PID_FILE="${CUA_ROUTER_PID_FILE:-/tmp/cua-router.pid}"
LOG_FILE="${CUA_ROUTER_LOG_FILE:-/tmp/cua-router.log}"

CUA_SERVICE_BUNDLE_ID="${CUA_SERVICE_BUNDLE_ID:-com.openai.sky.CUAService}"
CUA_SERVICE_SOCKET="${CUA_SERVICE_SOCKET:-$HOME/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock}"
CUA_SERVICE_WAIT_SECS="${CUA_SERVICE_WAIT_SECS:-20}"

# 浅探针（liveness）：仅验证 HTTP + app-server + node_repl 能跑 JS。
health_check() {
  curl -sf -X POST "http://localhost:${PORT}/exec" \
    -H 'Content-Type: application/json' \
    -d '{"code":"nodeRepl.write(\"ok\")","timeout_ms":8000}' \
    2>/dev/null | grep -qE '"text"[[:space:]]*:[[:space:]]*"ok"'
}

# 深探针（readiness）：调用 /ready，真正强制 sky 原生管道连一次 CUAService。
health_check_deep() {
  curl -sf -X POST "http://localhost:${PORT}/ready" \
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
  [ "$(uname -s)" = "Darwin" ] || return 0
  cua_service_running && return 0

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

cua_preflight_chrome_warn() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  [ -f "$SCRIPT_DIR/lib/preflight-chrome.sh" ] || return 0
  # shellcheck source=lib/preflight-chrome.sh
  source "$SCRIPT_DIR/lib/preflight-chrome.sh"
  CUA_ROUTER_CHROME_PREFLIGHT=warn cua_preflight_chrome warn || true
}

# 浅探活通过后调用：Chrome 预检 + 预热 CUAService + 深就绪校验。
# 就绪失败不阻断 start（liveness 已 OK），只告警并提示 `daemon.sh ready` 排查。
cua_finalize_ready() {
  cua_preflight_chrome_warn

  if health_check_deep; then
    echo "[cua-router] cua readiness: ready (sky 原生管道已连通 CUAService)"
    return 0
  fi

  echo "[cua-router] cua readiness: 未就绪，正在预热 CUAService(${CUA_SERVICE_BUNDLE_ID})..." >&2
  cua_service_ensure \
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
  return 0
}

cmd_start() {
  if health_check; then
    echo "[cua-router] already healthy on http://localhost:${PORT}"
    pid="$(read_pid || true)"
    [ -n "${pid:-}" ] && echo "[cua-router] pid=${pid}"
    cua_finalize_ready
    return 0
  fi

  old_pid="$(read_pid || true)"
  if [ -n "${old_pid:-}" ]; then
    if pid_alive "$old_pid"; then
      if ! health_check; then
        echo "[cua-router] pid ${old_pid} alive but unhealthy, restarting..."
        kill "$old_pid" 2>/dev/null || true
        sleep 1
      fi
    else
      rm -f "$PID_FILE"
    fi
  fi

  if ! vendor_ready "$SKILL_ROOT"; then
    echo "[cua-router] vendor missing, bootstrapping (auto)..." >&2
    bash "$SCRIPT_DIR/install-full.sh" --skill-root "$SKILL_ROOT" --vendor-mode auto --no-cursor
  fi

  nohup python3 "$SCRIPT_DIR/cua-router.py" --port "$PORT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "[cua-router] started pid=$(cat "$PID_FILE"), log=${LOG_FILE}"

  for i in $(seq 1 45); do
    if health_check; then
      echo "[cua-router] ready after ${i}s"
      cua_finalize_ready
      return 0
    fi
    sleep 1
  done

  echo "[cua-router] warning: health check timeout, see ${LOG_FILE}" >&2
  return 1
}

cmd_stop() {
  stopped=0
  pid="$(read_pid || true)"
  if [ -n "${pid:-}" ] && pid_alive "$pid"; then
    if kill "$pid" 2>/dev/null; then
      echo "[cua-router] stopped pid=${pid}"
      stopped=1
    fi
  fi
  rm -f "$PID_FILE"

  if [ "$stopped" -eq 0 ]; then
    if pkill -f "scripts/cua-router.py --port ${PORT}" 2>/dev/null; then
      echo "[cua-router] stopped by pattern match"
      stopped=1
    else
      if health_check && command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -nP -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)"
        if [ -n "$pids" ]; then
          killed=0
          for p in $pids; do
            if kill "$p" 2>/dev/null; then
              killed=1
            fi
          done
          if [ "$killed" -eq 1 ]; then
            echo "[cua-router] stopped listener on port ${PORT}: ${pids}"
            stopped=1
          else
            echo "[cua-router] warning: failed to stop listener on port ${PORT}: ${pids}" >&2
          fi
        fi
      fi
    fi
  fi

  if [ "$stopped" -eq 1 ]; then
    for _ in 1 2 3 4 5; do
      health_check || return 0
      sleep 1
    done
  fi

  if [ "$stopped" -eq 0 ]; then
    echo "[cua-router] not running"
  fi
}

cmd_status() {
  local deep=0
  [ "${1:-}" = "--deep" ] && deep=1

  pid="$(read_pid || true)"
  if health_check; then
    echo "[cua-router] running and healthy on http://localhost:${PORT}"
    [ -n "${pid:-}" ] && echo "[cua-router] pid=${pid}"
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
  curl -s -X POST "http://localhost:${PORT}/ready" \
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
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status "$@" ;;
    ready) cmd_ready ;;
    restart) cmd_restart ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
