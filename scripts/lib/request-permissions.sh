#!/usr/bin/env bash
# macOS Computer Use permission onboarding for cua-router / automan hosts.
#
# ChatGPT Desktop shows "Enable ChatGPT Computer Use" when the user first enables
# the plugin. cua-router normally prewarms CUAService with `open -g` (background),
# which never surfaces that UI. This helper opens the vendor authorization installer
# in the foreground so the user can click Allow for Accessibility + Screenshots.
#
# Usage (sourced or standalone):
#   bash scripts/lib/request-permissions.sh              # auto: skip if already ok
#   bash scripts/lib/request-permissions.sh --force       # always show installer
#   bash scripts/lib/request-permissions.sh --check      # exit 0 when AX probe ok
set -euo pipefail

REQ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_SCRIPT_DIR="$(cd "$REQ_LIB_DIR/.." && pwd)"
REQ_SKILL_ROOT="$(cd "$REQ_SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=common.sh
source "$REQ_LIB_DIR/common.sh"

PORT="${CUA_ROUTER_PORT:-18901}"
BASE="http://127.0.0.1:${PORT}"
PERMISSION_PROMPT="${CUA_ROUTER_PERMISSION_PROMPT:-auto}"
PERMISSION_WAIT_SECS="${CUA_ROUTER_PERMISSION_WAIT_SECS:-120}"

cua_main_app_path() {
  local p="$REQ_SKILL_ROOT/vendor/computer-use/Codex Computer Use.app"
  [ -d "$p" ] && printf '%s' "$p"
}

cua_installer_app_path() {
  local main app
  main="$(cua_main_app_path)" || return 1
  app="$main/Contents/SharedSupport/Codex Computer Use Installer.app"
  [ -d "$app" ] && printf '%s' "$app"
}

cua_router_live() {
  curl -sf "$BASE/health" >/dev/null 2>&1
}

# Returns machine-readable reason from /ready deep probe.
cua_ready_reason() {
  if ! cua_router_live; then
    printf 'router_down'
    return 0
  fi
  curl -sf -X POST "$BASE/ready" \
    -H 'Content-Type: application/json' \
    -d '{"deep":true}' 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason") or "")' 2>/dev/null \
    || printf 'probe_failed'
}

cua_permissions_granted() {
  local reason ready
  reason="$(cua_ready_reason)"
  case "$reason" in
    ok) return 0 ;;
    live) return 0 ;;
  esac
  if ! cua_router_live; then
    return 1
  fi
  ready="$(curl -sf -X POST "$BASE/ready" \
    -H 'Content-Type: application/json' \
    -d '{"deep":true}' 2>/dev/null \
    | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("ready") else "0")' 2>/dev/null \
    || printf '0')"
  [ "$ready" = "1" ]
}

cua_permissions_need_prompt() {
  local reason
  reason="$(cua_ready_reason)"
  case "$reason" in
    ok|live) return 1 ;;
    not_authorized|cua_service_rpc_failed|timeout|native_pipe*|cua_service_down|unexpected*)
      return 0
      ;;
    router_down|probe_failed|node_repl_down)
      return 0
      ;;
    *)
      # Conservative: unknown deep-probe failures often mean AX permissions missing.
      return 0
      ;;
  esac
}

cua_open_permission_ui() {
  local installer main
  installer="$(cua_installer_app_path || true)"
  main="$(cua_main_app_path || true)"

  if [ -n "$installer" ]; then
    info "opening Computer Use authorization installer (foreground)"
    # Foreground launch — do NOT use -g; that suppresses the onboarding window.
    open "$installer"
    return 0
  fi

  if [ -n "$main" ]; then
    warn "authorization installer missing; opening main Computer Use app"
    open "$main"
    return 0
  fi

  die "vendor Computer Use app not found under $REQ_SKILL_ROOT/vendor/computer-use/"
}

cua_wait_for_permissions() {
  local i reason
  info "waiting up to ${PERMISSION_WAIT_SECS}s for Accessibility + Screenshots approval..."
  for i in $(seq 1 "$PERMISSION_WAIT_SECS"); do
    if cua_permissions_granted; then
      info "Computer Use permissions verified"
      return 0
    fi
    if [ $((i % 10)) -eq 0 ]; then
      reason="$(cua_ready_reason)"
      warn "still waiting (${i}s): reason=${reason:-unknown} — complete the Enable ChatGPT Computer Use dialog"
    fi
    sleep 1
  done
  return 1
}

# Entry for daemon.sh / exec.sh. Returns 0 when permissions are usable.
cua_request_permissions_if_needed() {
  local mode="${1:-$PERMISSION_PROMPT}"

  [ "$(uname -s)" = "Darwin" ] || return 0

  case "$mode" in
    off) return 0 ;;
    force) ;;
    auto)
      if cua_permissions_granted; then
        return 0
      fi
      if ! cua_permissions_need_prompt; then
        return 0
      fi
      ;;
    *)
      warn "unknown CUA_ROUTER_PERMISSION_PROMPT=${mode}; treating as auto"
      ;;
  esac

  echo ""
  echo "[cua-router] Computer Use 需要 macOS 授权（辅助功能 + 屏幕录制）。"
  echo "[cua-router] 即将弹出「Enable ChatGPT Computer Use」窗口，请依次点击 Allow。"
  echo "[cua-router] 若未看到弹窗，请到 系统设置 → 隐私与安全性 手动勾选 Codex Computer Use。"
  echo ""

  cua_open_permission_ui
  cua_wait_for_permissions
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-run}"
  case "$cmd" in
    --check|check)
      if cua_permissions_granted; then
        echo "[request-permissions] ok"
        exit 0
      fi
      echo "[request-permissions] need_prompt reason=$(cua_ready_reason)"
      exit 1
      ;;
    --force|force)
      CUA_ROUTER_PERMISSION_PROMPT=force cua_request_permissions_if_needed force
      ;;
    --open|open)
      cua_open_permission_ui
      ;;
    run|--run|"")
      cua_request_permissions_if_needed "$PERMISSION_PROMPT"
      ;;
    *)
      echo "Usage: $0 {run|check|force|open}" >&2
      exit 1
      ;;
  esac
fi
