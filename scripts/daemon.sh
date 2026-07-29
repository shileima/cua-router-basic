#!/usr/bin/env bash
# cua-router 守护进程管理：start / stop / status / restart
# 使用 nohup 脱离 Shell，避免 Agent 命令结束后 SIGHUP 杀进程。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${CUA_ROUTER_PORT:-18901}"
PID_FILE="${CUA_ROUTER_PID_FILE:-/tmp/cua-router.pid}"
LOG_FILE="${CUA_ROUTER_LOG_FILE:-/tmp/cua-router.log}"

health_check() {
  curl -sf -X POST "http://localhost:${PORT}/exec" \
    -H 'Content-Type: application/json' \
    -d '{"code":"nodeRepl.write(\"ok\")","timeout_ms":8000}' \
    2>/dev/null | grep -qE '"text"[[:space:]]*:[[:space:]]*"ok"'
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

cmd_start() {
  if health_check; then
    echo "[cua-router] already healthy on http://localhost:${PORT}"
    pid="$(read_pid || true)"
    [ -n "${pid:-}" ] && echo "[cua-router] pid=${pid}"
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

  if [ ! -x "$SKILL_ROOT/vendor/codex/bin/codex" ]; then
    echo "[cua-router] vendor missing, running setup-vendor.sh..." >&2
    bash "$SCRIPT_DIR/setup-vendor.sh"
  fi

  nohup python3 "$SCRIPT_DIR/cua-router.py" --port "$PORT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "[cua-router] started pid=$(cat "$PID_FILE"), log=${LOG_FILE}"

  for i in $(seq 1 45); do
    if health_check; then
      echo "[cua-router] ready after ${i}s"
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
    kill "$pid" 2>/dev/null || true
    echo "[cua-router] stopped pid=${pid}"
    stopped=1
  fi
  rm -f "$PID_FILE"

  if [ "$stopped" -eq 0 ]; then
    if pkill -f "scripts/cua-router.py --port ${PORT}" 2>/dev/null; then
      echo "[cua-router] stopped by pattern match"
    else
      echo "[cua-router] not running"
    fi
  fi
}

cmd_status() {
  pid="$(read_pid || true)"
  if health_check; then
    echo "[cua-router] running and healthy on http://localhost:${PORT}"
    [ -n "${pid:-}" ] && echo "[cua-router] pid=${pid}"
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

cmd_restart() {
  cmd_stop
  sleep 2
  cmd_start
}

usage() {
  echo "Usage: $0 {start|stop|status|restart}" >&2
}

main() {
  cmd="${1:-start}"
  case "$cmd" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    restart) cmd_restart ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
