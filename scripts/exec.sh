#!/usr/bin/env bash
# 通过 cua-router /exec 端点执行 JS，并解析 nodeRepl.write 输出。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${CUA_ROUTER_PORT:-18901}"
EXEC_URL="http://127.0.0.1:${PORT}/exec"

# Resolve the capability token file used by the protected /exec endpoint.
# Priority: explicit token file → runtime dir override → default runtime →
# /tmp fallback (mirrors daemon.sh cua_runtime_dir()).
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

TIMEOUT_MS=30000
OUTPUT_MODE="text"
ENSURE_START=1
CODE_FILE=""

usage() {
  cat <<EOF
Usage: $0 [options] [code]

Execute JavaScript via cua-router /exec endpoint.

Options:
  -t, --timeout MS    Timeout in milliseconds (default: 30000)
  -f, --file PATH     Read code from file
  --json              Print full JSON response
  --text              Print content[0].text only (default)
  --no-start          Do not auto-start cua-router via daemon.sh
  -h, --help          Show this help

Notes:
  - node_repl does NOT return the last expression; use nodeRepl.write(...) to output.
  - See SKILL.md "执行 JS 与读取结果" for details.

Examples:
  $0 'nodeRepl.write("ok")'
  $0 -t 60000 -f navigate.js
  $0 --json '{ const s = await ax.get("com.google.Chrome"); nodeRepl.write(JSON.stringify(ax.summarize(s))); }'
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--timeout)
      TIMEOUT_MS="${2:?missing timeout value}"
      shift 2
      ;;
    -f|--file)
      CODE_FILE="${2:?missing file path}"
      shift 2
      ;;
    --json)
      OUTPUT_MODE="json"
      shift
      ;;
    --text)
      OUTPUT_MODE="text"
      shift
      ;;
    --no-start)
      ENSURE_START=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

read_code() {
  if [ -n "$CODE_FILE" ]; then
    if [ ! -f "$CODE_FILE" ]; then
      echo "[exec] file not found: $CODE_FILE" >&2
      exit 1
    fi
    cat "$CODE_FILE"
    return
  fi

  if [ $# -gt 0 ]; then
    printf '%s' "$*"
    return
  fi

  if [ ! -t 0 ]; then
    cat
    return
  fi

  usage >&2
  exit 1
}

wrap_code_for_repl() {
  printf '{\n%s\n}' "$1"
}

ensure_service() {
  if [ "$ENSURE_START" -eq 1 ]; then
    CUA_ROUTER_START_READINESS=off \
      CUA_ROUTER_HEALTH_MODE=app-server \
      bash "$SCRIPT_DIR/daemon.sh" start >/dev/null
    if [ "${CUA_ROUTER_EXEC_PREWARM:-auto}" != "off" ] \
      && printf '%s' "$CODE" | grep -qE '\b(ax|sky|atomic)\.'; then
      # Playback snippets usually need CUAService immediately. Prewarm only for
      # Computer Use code; recording still starts with readiness off in
      # record-desk-basic to avoid stealing the event-stream observer.
      bash "$SCRIPT_DIR/daemon.sh" ready >/dev/null || true
    fi
  fi
}

maybe_request_permissions() {
  if ! printf '%s' "$CODE" | grep -qE '\b(ax|sky|atomic)\.'; then
    return 0
  fi
  if [ "${CUA_ROUTER_PERMISSION_PROMPT:-auto}" = "off" ]; then
    return 0
  fi
  if [ ! -f "$SCRIPT_DIR/lib/request-permissions.sh" ]; then
    return 0
  fi
  # shellcheck source=lib/request-permissions.sh
  source "$SCRIPT_DIR/lib/request-permissions.sh"
  cua_request_permissions_if_needed "${CUA_ROUTER_PERMISSION_PROMPT:-auto}" || {
    echo "[exec] Computer Use permissions required; run: bash $SCRIPT_DIR/daemon.sh authorize" >&2
    exit 1
  }
}

maybe_preflight_chrome() {
  if ! printf '%s' "$CODE" | grep -qE 'com\.google\.Chrome|["'\''`]Google Chrome["'\''`]'; then
    return 0
  fi

  # shellcheck source=lib/preflight-chrome.sh
  source "$SCRIPT_DIR/lib/preflight-chrome.sh"
  local mode="${CUA_ROUTER_CHROME_PREFLIGHT:-auto}"
  if ! cua_preflight_chrome "$mode"; then
    echo "[exec] Chrome preflight failed; see warnings above" >&2
    exit 1
  fi
}

CODE="$(read_code "$@")"
if [ -z "$CODE" ]; then
  echo "[exec] empty code" >&2
  exit 1
fi
CODE="$(wrap_code_for_repl "$CODE")"

ensure_service
maybe_request_permissions
maybe_preflight_chrome

REQUEST_NOT_CONNECTED=75
request_exec() {
  # Read the token fresh on each request so a daemon restart that rotates the
  # token does not strand a cached value.
  local token
  token="$(cua_read_token)"
  python3 - "$EXEC_URL" "$TIMEOUT_MS" "$CODE" "$token" <<'PY'
import json
import socket
import sys
import urllib.error
import urllib.request

url, timeout_ms, code, token = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
payload = json.dumps({"code": code, "timeout_ms": timeout_ms}).encode()
headers = {"Content-Type": "application/json"}
if token:
    headers["X-CUA-Token"] = token
req = urllib.request.Request(
    url,
    data=payload,
    headers=headers,
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=max(timeout_ms / 1000 + 10, 30)) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as exc:
    print(exc.read().decode(), file=sys.stderr)
    raise SystemExit(exc.code)
except urllib.error.URLError as exc:
    reason = exc.reason
    if isinstance(reason, ConnectionRefusedError):
        print(f"[exec] connection refused before request delivery: {reason}", file=sys.stderr)
        raise SystemExit(75)
    if isinstance(reason, (socket.timeout, TimeoutError)):
        print(f"[exec] request timed out; not retrying because delivery is uncertain: {reason}", file=sys.stderr)
    else:
        print(f"[exec] request failed; not retrying because delivery is uncertain: {reason}", file=sys.stderr)
    raise SystemExit(1)
PY
}

set +e
RESP="$(request_exec)"
request_status=$?
set -e
if [ "$request_status" -eq "$REQUEST_NOT_CONNECTED" ] && [ "$ENSURE_START" -eq 1 ]; then
  echo "[exec] connection failed; ensuring cua-router and retrying once" >&2
  ensure_service
  set +e
  RESP="$(request_exec)"
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
    print(f"[exec] invalid JSON response: {exc}", file=sys.stderr)
    print(raw, file=sys.stderr)
    raise SystemExit(1)

if data.get("isError"):
    text = ""
    content = data.get("content") or []
    if content and isinstance(content[0], dict):
        text = content[0].get("text", "")
    print(text or json.dumps(data, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(1)

content = data.get("content") or []
if not content:
    print("", end="")
    raise SystemExit(0)

parts = []
for item in content:
    if isinstance(item, dict) and item.get("type") == "text":
        parts.append(item.get("text", ""))

print("\n".join(parts), end="")
if parts:
    print()
PY
