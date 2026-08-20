#!/usr/bin/env bash
# Structured desktop-control via cua-router /cua endpoint (MCP transport).
#
# Unlike exec.sh (which runs JS in the sandboxed node_repl), this drives the
# signed `cua mcp` child hosted inside the cua-router python process, so macOS
# TCC attributes the Apple Events to the host app (e.g. Automan Desktop) and
# automation works even under codex 0.148+ seatbelt sandboxes.
#
# Usage:
#   bash cua.sh <tool> [json-arguments]
#   bash cua.sh get_app_state '{"app":"Finder"}'
#   bash cua.sh list_apps
#   bash cua.sh click '{"app":"Finder","x":100,"y":200}'
#
# Tools: list_apps get_app_state click perform_secondary_action set_value
#        select_text scroll drag press_key type_text
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${CUA_ROUTER_PORT:-18901}"
CUA_URL="http://127.0.0.1:${PORT}/cua"

TIMEOUT_MS=30000
OUTPUT_MODE="text"
ENSURE_START=1

usage() {
  cat <<EOF
Usage: $0 [options] <tool> [json-arguments]

Drive desktop control via the cua-router /cua endpoint (MCP transport).

Options:
  -t, --timeout MS    Timeout in milliseconds (default: 30000)
  --json              Print full JSON response
  --text              Print content[0].text only (default)
  --no-start          Do not auto-start cua-router via daemon.sh
  -h, --help          Show this help

Tools:
  list_apps get_app_state click perform_secondary_action set_value
  select_text scroll drag press_key type_text

Examples:
  $0 list_apps
  $0 get_app_state '{"app":"Finder"}'
  $0 click '{"app":"Finder","x":100,"y":200}'
  $0 press_key '{"app":"Finder","key":"Command+a"}'
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--timeout) TIMEOUT_MS="${2:?missing timeout value}"; shift 2 ;;
    --json) OUTPUT_MODE="json"; shift ;;
    --text) OUTPUT_MODE="text"; shift ;;
    --no-start) ENSURE_START=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) break ;;
  esac
done

TOOL="${1:-}"
# NOTE: do not use ${2:-{}} here — bash parses it as default "{" followed by a
# literal "}", which appends a stray brace to a provided JSON object (e.g.
# '{"app":"Finder"}' becomes '{"app":"Finder"}}'). Assign in two steps instead.
ARGS_JSON="${2:-}"
[ -z "$ARGS_JSON" ] && ARGS_JSON='{}'
if [ -z "$TOOL" ]; then
  usage >&2
  exit 1
fi

cua_token_file() {
  if [ -n "${CUA_ROUTER_APP_SERVER_TOKEN_FILE:-}" ]; then
    printf '%s' "$CUA_ROUTER_APP_SERVER_TOKEN_FILE"
    return 0
  fi
  local runtime="${CUA_ROUTER_RUNTIME_DIR:-}"
  if [ -z "$runtime" ]; then
    if [ -f "$SKILL_ROOT/runtime/app-server.token" ]; then
      runtime="$SKILL_ROOT/runtime"
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

ensure_service() {
  if [ "$ENSURE_START" -eq 1 ]; then
    # Honor an explicitly exported SKY_TRANSPORT; otherwise fall back to the
    # router default (node_repl). Do NOT hardcode mcp here: the standalone
    # `cua mcp` transport cannot service list_apps/get_app_state (CUAService
    # blocks on a missing app-server event-observer connection).
    bash "$SCRIPT_DIR/daemon.sh" start >/dev/null
  fi
}

ensure_service

REQUEST_NOT_CONNECTED=75
request_cua() {
  local token
  token="$(cua_read_token)"
  python3 - "$CUA_URL" "$TIMEOUT_MS" "$TOOL" "$ARGS_JSON" "$token" <<'PY'
import json
import socket
import sys
import urllib.error
import urllib.request

url, timeout_ms, tool, args_raw, token = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
)
try:
    arguments = json.loads(args_raw) if args_raw.strip() else {}
except json.JSONDecodeError as exc:
    print(f"[cua] invalid json arguments: {exc}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(arguments, dict):
    print("[cua] arguments must be a JSON object", file=sys.stderr)
    raise SystemExit(2)

payload = json.dumps({"tool": tool, "arguments": arguments, "timeout_ms": timeout_ms}).encode()
headers = {"Content-Type": "application/json"}
if token:
    headers["X-CUA-Token"] = token
req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
try:
    with urllib.request.urlopen(req, timeout=max(timeout_ms / 1000 + 10, 30)) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as exc:
    print(exc.read().decode(), file=sys.stderr)
    raise SystemExit(exc.code)
except urllib.error.URLError as exc:
    reason = exc.reason
    if isinstance(reason, ConnectionRefusedError):
        print(f"[cua] connection refused before request delivery: {reason}", file=sys.stderr)
        raise SystemExit(75)
    print(f"[cua] request failed: {reason}", file=sys.stderr)
    raise SystemExit(1)
PY
}

set +e
RESP="$(request_cua)"
request_status=$?
set -e
if [ "$request_status" -eq "$REQUEST_NOT_CONNECTED" ] && [ "$ENSURE_START" -eq 1 ]; then
  echo "[cua] connection failed; ensuring cua-router and retrying once" >&2
  ensure_service
  set +e
  RESP="$(request_cua)"
  request_status=$?
  set -e
fi
if [ "$request_status" -ne 0 ]; then
  exit "$request_status"
fi

if [ "$OUTPUT_MODE" = "json" ]; then
  printf '%s\n' "$RESP"
  exit 0
fi

python3 - "$RESP" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"[cua] invalid JSON response: {exc}", file=sys.stderr)
    print(raw, file=sys.stderr)
    raise SystemExit(1)

content = data.get("content") or []
parts = [item.get("text", "") for item in content
         if isinstance(item, dict) and item.get("type") == "text"]
text = "\n".join(parts)

if data.get("isError"):
    print(text or json.dumps(data, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(1)

print(text, end="")
if parts:
    print()
PY
