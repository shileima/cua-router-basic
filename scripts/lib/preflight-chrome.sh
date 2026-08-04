#!/usr/bin/env bash
# macOS Chrome preflight for sky/CUA desktop control.
# Detects Playwright-owned Chrome (often --no-startup-window) and missing windows,
# which cause sky.get_app_state({ app: "com.google.Chrome" }) to timeout (-10005).
set -euo pipefail

PREFLIGHT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$PREFLIGHT_LIB_DIR/common.sh"

PREFLIGHT_MODE="${CUA_ROUTER_CHROME_PREFLIGHT:-warn}"

preflight_is_macos() {
  [ "$(uname -s)" = "Darwin" ]
}

playwright_daemon_pids() {
  pgrep -f "playwright-core/lib/.*/cliDaemon\.js" 2>/dev/null || true
}

playwright_chrome_pids() {
  {
    pgrep -f "playwright_chromiumdev_profile" 2>/dev/null || true
    pgrep -f "Google Chrome.*--no-startup-window" 2>/dev/null || true
  } | sort -u
}

chrome_window_count() {
  osascript 2>/dev/null <<'APPLESCRIPT' || echo 0
tell application "System Events"
  if not (exists process "Google Chrome") then
    return 0
  end if
end tell
tell application "Google Chrome"
  return count of windows
end tell
APPLESCRIPT
}

preflight_detect_issues() {
  local issues=""
  local daemon_pids chrome_pids win_count

  daemon_pids="$(playwright_daemon_pids | tr '\n' ' ' | sed 's/ $//')"
  chrome_pids="$(playwright_chrome_pids | tr '\n' ' ' | sed 's/ $//')"
  win_count="$(chrome_window_count)"

  if [ -n "$daemon_pids" ] || [ -n "$chrome_pids" ]; then
    issues="${issues}playwright_chrome "
  fi

  if [ "${win_count:-0}" -eq 0 ]; then
    issues="${issues}no_chrome_windows "
  fi

  printf '%s' "$issues" | sed 's/ $//'
}

preflight_stop_playwright() {
  local pid

  for pid in $(playwright_daemon_pids); do
    warn "stopping Playwright daemon pid=${pid}"
    kill "$pid" 2>/dev/null || true
  done

  for pid in $(playwright_chrome_pids); do
    warn "stopping Playwright Chrome pid=${pid}"
    kill "$pid" 2>/dev/null || true
  done

  sleep 1

  for pid in $(playwright_daemon_pids); do
    kill -9 "$pid" 2>/dev/null || true
  done

  for pid in $(playwright_chrome_pids); do
    kill -9 "$pid" 2>/dev/null || true
  done
}

preflight_ensure_chrome_window() {
  local win_count

  win_count="$(chrome_window_count)"
  if [ "${win_count:-0}" -gt 0 ]; then
    return 0
  fi

  if pgrep -f "[G]oogle Chrome.app/Contents/MacOS/Google Chrome" >/dev/null 2>&1; then
    info "opening a Chrome window (process running, no windows)"
    osascript -e 'tell application "Google Chrome" to make new window' >/dev/null 2>&1 || true
  else
    info "launching Google Chrome"
    open -a "Google Chrome" >/dev/null 2>&1 || true
  fi

  sleep 2
}

# Returns 0 when Chrome is ready (or was fixed); 1 when issues remain.
cua_preflight_chrome() {
  local mode="${1:-$PREFLIGHT_MODE}"
  local issues daemon_pids chrome_pids

  if ! preflight_is_macos; then
    return 0
  fi

  case "$mode" in
    off) return 0 ;;
    warn|auto) ;;
    *)
      warn "unknown CUA_ROUTER_CHROME_PREFLIGHT=${mode}; treating as warn"
      mode="warn"
      ;;
  esac

  issues="$(preflight_detect_issues)"
  if [ -z "$issues" ]; then
    return 0
  fi

  if [[ "$issues" == *playwright_chrome* ]]; then
    daemon_pids="$(playwright_daemon_pids | tr '\n' ' ' | sed 's/ $//')"
    chrome_pids="$(playwright_chrome_pids | tr '\n' ' ' | sed 's/ $//')"
    warn "Playwright is holding Chrome; sky.get_app_state may timeout (-10005)"
    [ -n "$daemon_pids" ] && warn "  Playwright daemon pid(s): ${daemon_pids}"
    [ -n "$chrome_pids" ] && warn "  Playwright Chrome pid(s): ${chrome_pids}"
  fi

  if [[ "$issues" == *no_chrome_windows* ]]; then
    warn "Google Chrome has no visible windows; sky.get_app_state may timeout (-10005)"
  fi

  if [ "$mode" = "auto" ]; then
    if [[ "$issues" == *playwright_chrome* ]]; then
      preflight_stop_playwright
    fi
    if [[ "$issues" == *no_chrome_windows* ]]; then
      preflight_ensure_chrome_window
    fi

    issues="$(preflight_detect_issues)"
    if [ -z "$issues" ]; then
      info "Chrome preflight passed after auto-remediation"
      return 0
    fi

    warn "Chrome preflight still failing after auto-remediation: ${issues}"
    return 1
  fi

  warn "Set CUA_ROUTER_CHROME_PREFLIGHT=auto to stop Playwright and ensure a Chrome window"
  return 1
}

code_targets_chrome() {
  printf '%s' "$1" | grep -qE \
    'com\.google\.Chrome|["'\''`]Google Chrome["'\''`]|app:[[:space:]]*["'\''`](Google Chrome|com\.google\.Chrome)["'\''`]'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-status}"
  case "$cmd" in
    status)
      issues="$(preflight_detect_issues)"
      if [ -z "$issues" ]; then
        echo "[preflight-chrome] ok (windows=$(chrome_window_count))"
        exit 0
      fi
      echo "[preflight-chrome] issues: ${issues}"
      exit 1
      ;;
    fix)
      export CUA_ROUTER_CHROME_PREFLIGHT=auto
      cua_preflight_chrome auto
      ;;
    *)
      echo "Usage: $0 {status|fix}" >&2
      exit 1
      ;;
  esac
fi
