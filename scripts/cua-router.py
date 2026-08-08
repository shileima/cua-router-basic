#!/usr/bin/env python3
"""
newapi computer-use tool_call 路由器

职责：
  1. 作为 newapi proxy 的下游：接收 responses API 请求
  2. 当模型返回 node_repl.js tool_call 时，通过 app-server stdio IPC 执行
  3. 把执行结果回填给 responses API，继续 mcp_loop

用法：
  python3 cua-router.py          # 前台运行，监听 localhost:18901
  python3 cua-router.py --port 18901

架构：
  newapi (upstream) → cua-router (this) → app-server stdio IPC
                                          └→ node_repl → @oai/sky → SkyComputerUseService
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from vendor_paths import (
    client_mjs,
    computer_use_app,
    codex_bin,
    ensure_vendor,
    write_runtime_config,
    RUNTIME,
    SKILL_ROOT,
)

CLIENT_MJS = client_mjs().as_posix()
NEWAPI_BASE = os.environ.get(
    "CUA_ROUTER_NEWAPI_BASE",
    "https://newapi.waimai.test.sankuai.com/v1",
)
DEFAULT_MODEL = os.environ.get("CUA_ROUTER_MODEL", "gpt-5.4-responses")

SKY_BOOTSTRAP = f"""
const {{ setupComputerUseRuntime }} = await import("{CLIENT_MJS}");
await setupComputerUseRuntime({{ globals: globalThis }});
console.log("sky bootstrapped, keys:", Object.keys(globalThis.sky).join(","));
"""

# Readiness deep-probe: forces the sky native pipe to actually connect to the
# Sky Computer Use background service (com.openai.sky.CUAService). list_apps is
# the lightest sky RPC — no target app, read-only, does not change focus — yet it
# still requires the native socket + CUAService to be alive, so it is the ideal
# signal that the whole desktop-control stack (layer ⑤) is ready, not just node_repl.
SKY_READINESS_PROBE = f"""
{{
  if (typeof globalThis.sky === "undefined" || !globalThis.sky) {{
    const mod = await import("{CLIENT_MJS}");
    await mod.setupComputerUseRuntime({{ globals: globalThis }});
  }}
  const apps = await globalThis.sky.list_apps();
  const n = Array.isArray(apps) ? apps.length : (apps && apps.apps ? apps.apps.length : -1);
  nodeRepl.write("cua-ready:" + n);
}}
"""

def wrap_js_for_repl(code: str) -> str:
    """Run each /exec snippet in its own scope to avoid REPL redeclare noise."""
    if not code.strip():
        return code
    return f"{{\n{code}\n}}"


# Unix domain socket the CUAService listens on once it is up.
CUA_SERVICE_SOCKET = os.path.expanduser(
    "~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock"
)


def _skill_version() -> str:
    try:
        meta = json.loads((SKILL_ROOT / ".meta.json").read_text(encoding="utf-8"))
    except Exception:
        return ""
    return str(meta.get("version", ""))


def router_identity() -> dict:
    """Stable identity used by shell wrappers to reject stale router daemons."""
    return {
        "service": "cua-router-basic",
        "skill_root": str(SKILL_ROOT),
        "runtime_dir": str(RUNTIME),
        "computer_use_app": str(computer_use_app()),
        "codex_bin": str(codex_bin()),
        "version": _skill_version(),
        "pid": os.getpid(),
    }

# ──────────────────────────────────────────────
# app-server session (singleton, lazy-init)
# ──────────────────────────────────────────────

class AppServerSession:
    def __init__(self):
        self._proc = None
        self._responses: list[dict] = []
        self._lock = threading.Lock()
        self._req_id = 0
        self._thread_id: Optional[str] = None
        self._sky_bootstrapped = False

    def _next_id(self) -> int:
        self._req_id += 1
        return self._req_id

    def _start(self):
        ensure_vendor()
        config_path = write_runtime_config()
        codex = str(codex_bin())
        env = os.environ.copy()
        env["CODEX_HOME"] = str(RUNTIME)

        print(f"[app-server] starting via bundled codex: {codex}", flush=True)
        print(f"[app-server] config: {config_path}", flush=True)
        self._proc = subprocess.Popen(
            [codex, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=str(SKILL_ROOT),
        )
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._read_stderr_loop, daemon=True).start()

        r = self._req(self._next_id(), "initialize", {
            "clientInfo": {"name": "cua-router", "version": "1.0"},
            "capabilities": {"experimentalApi": True}
        })
        if not r:
            raise RuntimeError("app-server initialize timeout")

        time.sleep(0.5)
        r = self._req(self._next_id(), "thread/start", {"approvalPolicy": "never"})
        if not r:
            raise RuntimeError("thread/start timeout")
        self._thread_id = r["result"]["thread"]["id"]
        print(f"[app-server] ready, threadId={self._thread_id}", flush=True)

        # wait for node_repl to be ready
        deadline = time.time() + 15
        while time.time() < deadline:
            for n in self._responses:
                p = n.get("params", {})
                if (p.get("name") == "node_repl" and p.get("status") == "ready"):
                    print("[app-server] node_repl ready", flush=True)
                    return
            time.sleep(0.3)
        print("[app-server] warning: node_repl ready event not seen", flush=True)

    def _read_loop(self):
        for raw in self._proc.stdout:
            try:
                msg = json.loads(raw)
                with self._lock:
                    self._responses.append(msg)
            except Exception:
                pass

    def _read_stderr_loop(self):
        for raw in self._proc.stderr:
            line = raw.decode(errors="replace").rstrip()
            if line:
                print(f"[app-server:stderr] {line}", flush=True)

    def _req(self, id_: int, method: str, params: Any, timeout: float = 15.0) -> Optional[Dict]:
        msg = {"jsonrpc": "2.0", "id": id_, "method": method, "params": params}
        self._proc.stdin.write((json.dumps(msg) + "\n").encode())
        self._proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(0.2)
            with self._lock:
                for r in self._responses:
                    if r.get("id") == id_:
                        return r
        return None

    def ensure(self):
        with self._lock:
            need_start = self._proc is None or self._proc.poll() is not None
        if need_start:
            self._start()

    def call_js(self, code: str, timeout_ms: int = 30000) -> dict:
        """Execute JS via node_repl and return MCP tool result."""
        self.ensure()

        if not self._sky_bootstrapped:
            id_ = self._next_id()
            r = self._req(id_, "mcpServer/tool/call", {
                "server": "node_repl",
                "threadId": self._thread_id,
                "tool": "js",
                "arguments": {"code": wrap_js_for_repl(SKY_BOOTSTRAP), "title": "bootstrap sky", "timeout_ms": 10000}
            }, timeout=15)
            if r and not r.get("result", {}).get("isError"):
                self._sky_bootstrapped = True

        id_ = self._next_id()
        r = self._req(id_, "mcpServer/tool/call", {
            "server": "node_repl",
            "threadId": self._thread_id,
            "tool": "js",
            "arguments": {"code": wrap_js_for_repl(code), "title": "cua", "timeout_ms": timeout_ms}
        }, timeout=timeout_ms / 1000 + 5)

        if r is None:
            return {"content": [{"type": "text", "text": "timeout"}], "isError": True}
        return r.get("result", {"content": [{"type": "text", "text": "no result"}], "isError": True})

    def call_event_stream(self, action: str, timeout_ms: int = 30000) -> dict:
        """Drive Record & Replay via the app-server-hosted event_stream mcp.

        Recording only works when the event-stream mcp server is hosted by the
        SAME codex app-server that holds the CUAService event-observer
        connection. A standalone `SkyComputerUseClient event-stream mcp` client
        connects but never receives an XPC reply (the service has nowhere to
        stream events), so we always route through this app-server session.
        """
        self.ensure()
        tool = f"event_stream_{action}"
        id_ = self._next_id()
        r = self._req(id_, "mcpServer/tool/call", {
            "server": "event_stream",
            "threadId": self._thread_id,
            "tool": tool,
            "arguments": {},
        }, timeout=timeout_ms / 1000 + 5)
        if r is None:
            return {"content": [{"type": "text", "text": "timeout"}], "isError": True}
        return r.get("result", {"content": [{"type": "text", "text": "no result"}], "isError": True})


_session = AppServerSession()


# ──────────────────────────────────────────────
# responses API tool_call executor
# ──────────────────────────────────────────────

def execute_tool_call(tool_name: str, arguments: dict) -> dict:
    """Route a tool_call to node_repl and return the result in responses API format."""
    if tool_name == "js":
        code = arguments.get("code", "")
        timeout_ms = arguments.get("timeout_ms", 30000)
        result = _session.call_js(code, timeout_ms)
        # convert MCP content → responses API tool_result content
        content = []
        for item in result.get("content", []):
            if item.get("type") == "text":
                content.append({"type": "text", "text": item["text"]})
            elif item.get("type") == "image_url":
                content.append({"type": "image_url", "image_url": {"url": item["imageUrl"]}})
        return {
            "output": content,
            "isError": result.get("isError", False)
        }
    return {"output": [{"type": "text", "text": f"unknown tool: {tool_name}"}], "isError": True}


# ──────────────────────────────────────────────
# readiness probe (liveness of node_repl + real sky native pipe)
# ──────────────────────────────────────────────

def _content_text(result: dict) -> str:
    for item in (result or {}).get("content", []) or []:
        if isinstance(item, dict) and item.get("type") == "text":
            return item.get("text", "")
    return ""


def _classify_probe_error(text: str) -> str:
    """Map a raw sky error string to a stable machine-readable reason code."""
    low = (text or "").lower()
    if (
        "native pipe startup failed" in low
        or "native pipe is unavailable" in low
        or "service startup request failed" in low
        or "closed before response" in low
    ):
        return "cua_service_down"
    if "timed out" in low or "timeout" in low:
        return "timeout"
    if (
        "not authorized" in low
        or "approval" in low
        or "permission" in low
        or "accessibility" in low
        or "screen recording" in low
    ):
        return "not_authorized"
    if "version mismatch" in low or "incompatible" in low:
        return "version_mismatch"
    return (text or "").strip()[:200] or "unknown"


def probe_ready(deep: bool = True) -> dict:
    """
    Structured readiness probe used by /ready and daemon.sh.

    Tiers:
      - socket : whether the CUAService unix socket file exists (cheap, filesystem)
      - live   : node_repl can run trivial JS (layers ②③)
      - sky    : sky.list_apps() succeeds → native pipe + CUAService are up (layer ⑤)
    ready = live and (sky when deep). reason carries a stable code on failure.
    """
    import stat as _stat

    res = {
        "ready": False,
        "live": False,
        "sky": False,
        "socket": False,
        "reason": "",
        "ts": int(time.time()),
    }
    res.update(router_identity())

    try:
        st = os.stat(CUA_SERVICE_SOCKET)
        res["socket"] = _stat.S_ISSOCK(st.st_mode)
    except OSError:
        res["socket"] = False

    try:
        live = _session.call_js('nodeRepl.write("ok")', 6000)
    except Exception as exc:  # noqa: BLE001 - surfaced as reason
        res["reason"] = f"router_error: {exc}"
        return res

    res["live"] = (not live.get("isError")) and _content_text(live).strip() == "ok"
    if not res["live"]:
        res["reason"] = "node_repl_down"
        return res

    if not deep:
        res["ready"] = True
        res["reason"] = "live"
        return res

    try:
        probe = _session.call_js(SKY_READINESS_PROBE, 12000)
    except Exception as exc:  # noqa: BLE001 - surfaced as reason
        res["reason"] = f"probe_error: {exc}"
        return res

    ptext = _content_text(probe)
    if probe.get("isError"):
        res["reason"] = _classify_probe_error(ptext)
    elif ptext.startswith("cua-ready"):
        res["sky"] = True
    else:
        res["reason"] = ("unexpected: " + ptext.strip()[:180]) or "unexpected"

    res["ready"] = res["live"] and res["sky"]
    if res["ready"]:
        res["reason"] = "ok"
        # If sky works the socket is necessarily up, even if the stat() above raced.
        res["socket"] = True
    return res


def probe_app_server_live() -> dict:
    res = {
        "ready": False,
        "live": False,
        "sky": False,
        "socket": False,
        "reason": "",
        "ts": int(time.time()),
    }
    res.update(router_identity())
    try:
        _session.ensure()
    except Exception as exc:  # noqa: BLE001 - surfaced as reason
        res["reason"] = f"router_error: {exc}"
        return res

    res["ready"] = True
    res["live"] = True
    res["reason"] = "app_server_live"
    return res


# ──────────────────────────────────────────────
# HTTP proxy + mcp_loop
# ──────────────────────────────────────────────

import urllib.request
import urllib.error

def forward_to_newapi(path: str, body: bytes, headers: dict) -> tuple[int, bytes, str]:
    url = NEWAPI_BASE + path
    h = {k: v for k, v in headers.items()
         if k.lower() in ("authorization", "content-type", "openai-beta", "x-request-id")}
    h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, resp.read(), resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        body_err = e.read()
        print(f"[newapi] HTTP {e.code}: {body_err[:200]}", flush=True)
        return e.code, body_err, "application/json"
    except Exception as e:
        print(f"[newapi] request error: {e}", flush=True)
        raise


def run_mcp_loop(request_body: dict, auth_header: str = "") -> bytes:
    """
    Execute one responses API round-trip.
    If the model returns node_repl tool_calls, execute them and continue.
    """
    import copy

    body = copy.deepcopy(request_body)
    # force stream=False for simplicity
    body["stream"] = False
    # apply default model if not specified
    body.setdefault("model", DEFAULT_MODEL)

    for round_num in range(40):
        raw_body = json.dumps(body).encode()
        headers = {"Authorization": auth_header or f"Bearer {_get_api_key()}"}
        status, resp_bytes, _ = forward_to_newapi("/responses", raw_body, headers)

        if status != 200:
            return resp_bytes

        resp = json.loads(resp_bytes)
        output = resp.get("output", [])

        # find tool_calls for node_repl tools
        tool_calls = [item for item in output
                      if item.get("type") == "function_call"
                      and item.get("name") in ("js", "js_reset", "js_add_node_module_dir")]

        if not tool_calls:
            return resp_bytes

        print(f"[mcp_loop] round {round_num}: executing {len(tool_calls)} tool_call(s)", flush=True)

        # execute each tool_call
        tool_results = []
        for tc in tool_calls:
            args = json.loads(tc.get("arguments", "{}"))
            result = execute_tool_call(tc["name"], args)
            tool_results.append({
                "type": "function_call_output",
                "call_id": tc["call_id"],
                "output": json.dumps(result["output"])
            })
            print(f"  [{tc['name']}] → isError={result['isError']}", flush=True)

        # append output + tool_results to input for next round
        body.setdefault("input", [])
        if isinstance(body["input"], str):
            body["input"] = [{"type": "message", "role": "user", "content": body["input"]}]
        body["input"] = list(body["input"]) + list(output) + tool_results

    return resp_bytes


def _get_api_key() -> str:
    return os.environ.get("CUA_ROUTER_API_KEY") or os.environ.get("NEWAPI_API_KEY") or ""


# ──────────────────────────────────────────────
# HTTP server
# ──────────────────────────────────────────────

class RouterHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[http] {fmt % args}", flush=True)

    def _write_json(self, obj: dict, status: int = 200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle_ready(self, deep: bool):
        try:
            self._write_json(probe_ready(deep=deep))
        except Exception as exc:  # noqa: BLE001
            print(f"[ready] error: {exc}", flush=True)
            self._write_json({"ready": False, "live": False, "sky": False,
                              "socket": False, "reason": f"error: {exc}"}, 200)

    def _handle_health(self):
        try:
            self._write_json(probe_app_server_live())
        except Exception as exc:  # noqa: BLE001
            print(f"[health] error: {exc}", flush=True)
            self._write_json({"ready": False, "live": False, "sky": False,
                              "socket": False, "reason": f"error: {exc}"}, 200)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        # /ready → full deep probe (default);  /health → shallow liveness only
        if path == "/ready":
            self._handle_ready(deep=True)
            return
        if path == "/health":
            self._handle_health()
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        try:
            req_body = json.loads(body)
        except Exception:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad json")
            return

        if self.path.split("?", 1)[0] == "/ready":
            self._handle_ready(deep=bool(req_body.get("deep", True)))
            return

        if self.path.split("?", 1)[0] == "/record":
            # Record & Replay control endpoint. body: {"action": "start|status|stop"}
            action = str(req_body.get("action", "status")).strip()
            if action not in ("start", "status", "stop"):
                resp_bytes = json.dumps({
                    "isError": True,
                    "content": [{"type": "text", "text": f"unknown action: {action}"}],
                }).encode()
            else:
                try:
                    result = _session.call_event_stream(action)
                    resp_bytes = json.dumps(result, ensure_ascii=False).encode()
                except Exception as e:  # noqa: BLE001
                    print(f"[record] error: {e}", flush=True)
                    resp_bytes = json.dumps({
                        "isError": True,
                        "content": [{"type": "text", "text": str(e)}],
                    }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp_bytes)))
            self.end_headers()
            self.wfile.write(resp_bytes)
            return

        if self.path == "/exec":
            # Direct JS execution endpoint, bypasses newapi
            code = req_body.get("code", "")
            timeout_ms = req_body.get("timeout_ms", 30000)
            try:
                result = _session.call_js(code, timeout_ms)
                resp_bytes = json.dumps(result).encode()
            except Exception as e:
                print(f"[exec] error: {e}", flush=True)
                resp_bytes = json.dumps({"isError": True, "content": [{"type": "text", "text": str(e)}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp_bytes)))
            self.end_headers()
            self.wfile.write(resp_bytes)
            return

        print(f"[router] {self.path} model={req_body.get('model','?')}", flush=True)
        auth = self.headers.get("Authorization", "")
        try:
            resp_bytes = run_mcp_loop(req_body, auth_header=auth)
        except Exception as e:
            print(f"[router] error: {e}", flush=True)
            resp_bytes = json.dumps({"error": str(e)}).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp_bytes)))
        self.end_headers()
        self.wfile.write(resp_bytes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18901)
    args = parser.parse_args()

    try:
        ensure_vendor()
        write_runtime_config()
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

    print(f"[cua-router] skill root: {SKILL_ROOT}", flush=True)
    print(f"[cua-router] warming up bundled app-server...", flush=True)
    _session.ensure()

    print(f"[cua-router] listening on http://localhost:{args.port}", flush=True)
    server = HTTPServer(("127.0.0.1", args.port), RouterHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[cua-router] stopped")
