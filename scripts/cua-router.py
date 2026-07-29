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
                "arguments": {"code": SKY_BOOTSTRAP, "title": "bootstrap sky", "timeout_ms": 10000}
            }, timeout=15)
            if r and not r.get("result", {}).get("isError"):
                self._sky_bootstrapped = True

        id_ = self._next_id()
        r = self._req(id_, "mcpServer/tool/call", {
            "server": "node_repl",
            "threadId": self._thread_id,
            "tool": "js",
            "arguments": {"code": code, "title": "cua", "timeout_ms": timeout_ms}
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
