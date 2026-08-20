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
import contextlib
import json
import os
import base64
import hashlib
import hmac
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
from cua_mcp_client import CuaMcpClient, CUA_MCP_TOOLS

CLIENT_MJS = client_mjs().as_posix()

# Desktop-control transport selector.
#   node_repl (default legacy) : sky.* runs inside node_repl via the native
#                                pipe. Broken under codex 0.148+ seatbelt
#                                sandboxes (no nativePipe, connect() EPERM).
#   mcp (default)              : desktop control runs in THIS python process
#                                via the signed `cua mcp` stdio child, so the
#                                responsible process is the host app (e.g.
#                                Automan Desktop) and TCC automation works.
# Defaults to node_repl: the app-server-hosted node_repl holds the CUAService
# event-observer connection that list_apps/get_app_state require. The standalone
# `cua mcp` child (SKY_TRANSPORT=mcp) lacks that connection and hangs, so it is
# opt-in only. Set SKY_TRANSPORT=mcp to force the (currently unusable) mcp path.
SKY_TRANSPORT = os.environ.get("SKY_TRANSPORT", "node_repl").strip().lower()

# Lazily-created singleton MCP client (only used when SKY_TRANSPORT == "mcp").
_mcp_client: Optional["CuaMcpClient"] = None
_mcp_client_lock = threading.Lock()


def mcp_client() -> "CuaMcpClient":
    global _mcp_client
    if _mcp_client is None:
        with _mcp_client_lock:
            if _mcp_client is None:
                _mcp_client = CuaMcpClient()
    return _mcp_client
NEWAPI_BASE = os.environ.get(
    "CUA_ROUTER_NEWAPI_BASE",
    "https://newapi.waimai.test.sankuai.com/v1",
)
DEFAULT_MODEL = os.environ.get("CUA_ROUTER_MODEL", "gpt-5.4-responses")


class RouterHTTPServer(ThreadingHTTPServer):
    """Keep liveness endpoints responsive while a deep sky probe is blocked."""

    daemon_threads = True
    allow_reuse_address = True


SKY_BOOTSTRAP = f"""
const {{ setupComputerUseRuntime }} = await import("{CLIENT_MJS}");
await setupComputerUseRuntime({{ globals: globalThis }});
console.log("sky bootstrapped, keys:", Object.keys(globalThis.sky).join(","));
"""

# Readiness deep-probe: list_apps only proves the native pipe is connected.
# A real AX snapshot is required to prove desktop-control calls will work.
SKY_READINESS_PROBE = f"""
{{
  if (typeof globalThis.sky === "undefined" || !globalThis.sky) {{
    const mod = await import("{CLIENT_MJS}");
    await mod.setupComputerUseRuntime({{ globals: globalThis }});
  }}
  const apps = await globalThis.sky.list_apps();
  const n = Array.isArray(apps) ? apps.length : (apps && apps.apps ? apps.apps.length : -1);
  const readyApp = "com.apple.finder";
  const state = await globalThis.sky.get_app_state({{ app: readyApp, disableDiff: true }});
  const textLen = String((state && state.text) || "").length;
  nodeRepl.write("cua-ready:" + n + ":ax:" + readyApp + ":" + textLen);
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
# local endpoint hardening (P0): capability-token + Host allowlist
# ──────────────────────────────────────────────
#
# The HTTP endpoints that execute arbitrary JS / drive the desktop (/exec,
# /record and the mcp_loop root) must not be callable by any local process or
# by a browser page (CSRF / DNS-rebinding). We therefore require a shared
# capability token AND a localhost Host header on those endpoints. Liveness
# probes (/health, /ready) return status only and stay open so that daemon.sh
# and humans can keep using `curl localhost:<port>/health` for triage.

# The capability token file. Reuse the app-server token when present so shell
# wrappers that already resolve the runtime dir need no extra state; otherwise
# fall back to a router-scoped token file created on demand.
ROUTER_TOKEN_FILE = Path(
    os.environ.get("CUA_ROUTER_APP_SERVER_TOKEN_FILE")
    or (RUNTIME / "app-server.token")
)


def _read_router_token() -> str:
    """Read the capability token from disk on every call (no caching).

    Reading fresh avoids 401s after `daemon.sh restart` rotates the token while
    a long-lived client still holds an old value.
    """
    try:
        return ROUTER_TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _host_is_localhost(host_header: str, port: int) -> bool:
    """Accept only loopback Host headers, with lenient port handling.

    Guards against DNS-rebinding where a browser resolves attacker.com to
    127.0.0.1 but sends Host: attacker.com. IPv6 literals and an omitted port
    are allowed as long as the host part is loopback.
    """
    host = (host_header or "").strip()
    if not host:
        return False
    # Strip an IPv6 bracket form like [::1]:18901 → host="::1", rest=":18901"
    if host.startswith("["):
        end = host.find("]")
        if end == -1:
            return False
        hostname = host[1:end]
        remainder = host[end + 1:]
        port_part = remainder[1:] if remainder.startswith(":") else ""
    else:
        hostname, _, port_part = host.partition(":")
    if hostname not in ("127.0.0.1", "localhost", "::1"):
        return False
    if port_part and port_part != str(port):
        return False
    return True


def _extract_request_token(headers) -> str:
    """Pull the caller token from either X-CUA-Token or Authorization: Bearer."""
    token = (headers.get("X-CUA-Token") or "").strip()
    if token:
        return token
    auth = (headers.get("Authorization") or "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return ""

# ──────────────────────────────────────────────
# app-server session (singleton, lazy-init)
# ──────────────────────────────────────────────

class WebSocketTransport:
    """Minimal RFC 6455 client for the local vendor app-server."""

    def __init__(self, url: str, token: str):
        from urllib.parse import urlparse
        parsed = urlparse(url)
        self._sock = socket.create_connection((parsed.hostname, parsed.port), timeout=10)
        self._sock.settimeout(None)
        key = base64.b64encode(os.urandom(16)).decode()
        path = parsed.path or "/"
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {parsed.hostname}:{parsed.port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n"
        )
        self._sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += self._sock.recv(4096)
        if not response.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(f"app-server websocket handshake failed: {response.splitlines()[0].decode()}")
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if f"sec-websocket-accept: {expected}".lower() not in response.decode(errors="replace").lower():
            raise RuntimeError("app-server websocket handshake returned an invalid accept key")
        self._write_lock = threading.Lock()

    def _read_exact(self, size: int) -> bytes:
        data = b""
        while len(data) < size:
            chunk = self._sock.recv(size - len(data))
            if not chunk:
                raise EOFError("app-server websocket closed")
            data += chunk
        return data

    def recv(self) -> bytes:
        while True:
            first, second = self._read_exact(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8))[0]
            payload = self._read_exact(length)
            if opcode == 0x8:
                raise EOFError("app-server websocket closed")
            if opcode == 0x9:
                self._send_frame(payload, opcode=0xA)
                continue
            if opcode == 0x1:
                return payload

    def _send_frame(self, payload: bytes, opcode: int = 0x1):
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0xFE]) + struct.pack("!H", length)
        else:
            header += bytes([0xFF]) + struct.pack("!Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        with self._write_lock:
            self._sock.sendall(header + mask + masked)

    def send(self, payload: bytes):
        self._send_frame(payload)

    def close(self):
        with contextlib.suppress(Exception):
            self._send_frame(b"", opcode=0x8)
        with contextlib.suppress(Exception):
            self._sock.close()


class AppServerSession:
    def __init__(self):
        self._proc = None
        self._transport = None
        self._responses: list[dict] = []
        self._lock = threading.Lock()
        self._idle = threading.Condition(self._lock)
        self._call_lock = threading.Lock()
        self._active_calls = 0
        self._closing = False
        self._starting = False
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

        endpoint = os.environ.get("CUA_ROUTER_APP_SERVER_WS", "")
        token_file = os.environ.get("CUA_ROUTER_APP_SERVER_TOKEN_FILE", "")
        if endpoint and token_file:
            token = Path(token_file).read_text(encoding="utf-8").strip()
            print(f"[app-server] connecting to bundled launchd app-server: {endpoint}", flush=True)
            self._transport = WebSocketTransport(endpoint, token)
            threading.Thread(target=self._read_loop, daemon=True).start()
        else:
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
            "capabilities": {"experimentalApi": True, "mcpServerOpenaiFormElicitation": True}
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
        while True:
            try:
                raw = self._transport.recv() if self._transport else self._proc.stdout.readline()
                if not raw:
                    return
                msg = json.loads(raw)
                with self._lock:
                    self._responses.append(msg)
            except Exception as exc:
                print(f"[app-server] read loop stopped: {exc}", flush=True)
                return

    def _read_stderr_loop(self):
        for raw in self._proc.stderr:
            line = raw.decode(errors="replace").rstrip()
            if line:
                print(f"[app-server:stderr] {line}", flush=True)

    def _req(self, id_: int, method: str, params: Any, timeout: float = 15.0) -> Optional[Dict]:
        msg = {"jsonrpc": "2.0", "id": id_, "method": method, "params": params}
        payload = json.dumps(msg).encode()
        if self._transport:
            self._transport.send(payload)
        else:
            self._proc.stdin.write(payload + b"\n")
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
        with self._idle:
            while self._starting and not self._closing:
                self._idle.wait()
            if self._closing:
                raise RuntimeError("app-server session is shutting down")
            if self._transport is not None:
                return
            if self._proc is not None and self._proc.poll() is None:
                return
            self._starting = True
        try:
            self._start()
        finally:
            with self._idle:
                self._starting = False
                self._idle.notify_all()

    @contextlib.contextmanager
    def _operation(self):
        with self._idle:
            if self._closing:
                raise RuntimeError("app-server session is shutting down")
            self._active_calls += 1
        try:
            yield
        finally:
            with self._idle:
                self._active_calls -= 1
                if self._active_calls == 0:
                    self._idle.notify_all()

    def close(self):
        """Terminate the bundled app-server owned by this router."""
        with self._idle:
            self._closing = True
            while self._active_calls or self._starting:
                self._idle.wait()
            proc = self._proc
            transport = self._transport
            self._proc = None
            self._transport = None
            self._thread_id = None
            self._sky_bootstrapped = False
        if transport is not None:
            transport.close()
        if proc is None or proc.poll() is not None:
            return
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)

    def call_js(self, code: str, timeout_ms: int = 30000) -> dict:
        """Execute JS via node_repl and return MCP tool result."""
        with self._call_lock:
            with self._operation():
                return self._call_js(code, timeout_ms)

    def _call_js(self, code: str, timeout_ms: int) -> dict:
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
        with self._operation():
            return self._call_event_stream(action, timeout_ms)

    def _call_event_stream(self, action: str, timeout_ms: int) -> dict:
        """Drive Record & Replay via the app-server-hosted event_stream mcp.

        Recording only works when the event-stream mcp server is hosted by the
        SAME codex app-server that holds the CUAService event-observer
        connection. A standalone `SkyComputerUseClient event-stream mcp` client
        connects but never receives an XPC reply (the service has nowhere to
        stream events), so we always route through this app-server session.
        """
        try:
            # Recording requires event_stream in app-server config.toml; callers
            # should restart daemon with CUA_ROUTER_ENABLE_EVENT_STREAM=1 first.
            os.environ["CUA_ROUTER_ENABLE_EVENT_STREAM"] = "1"
            write_runtime_config()
        except Exception as exc:  # noqa: BLE001 - surfaced to /record callers
            return {
                "content": [{"type": "text", "text": f"record runtime unavailable: {exc}"}],
                "isError": True,
            }

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
        result = r.get("result", {"content": [{"type": "text", "text": "no result"}], "isError": True})
        text = _content_text(result)
        if text.strip() == "no result":
            config_path = RUNTIME / "config.toml"
            has_es = (
                config_path.exists()
                and "[mcp_servers.event_stream]" in config_path.read_text(encoding="utf-8")
            )
            hint = (
                "event_stream MCP 未加载。请先执行："
                "CUA_ROUTER_ENABLE_EVENT_STREAM=1 bash \"$SKILL_ROOT/scripts/daemon.sh\" restart"
            )
            if not has_es:
                hint += "（runtime/config.toml 缺少 event_stream 段）"
            return {"content": [{"type": "text", "text": hint}], "isError": True}
        return result


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


def _execute_cua_via_node_repl(tool: str, arguments: dict, timeout_ms: int) -> dict:
    """Drive a structured desktop-control call through the app-server node_repl.

    The standalone ``cua mcp`` child cannot service ``list_apps`` /
    ``get_app_state`` because CUAService blocks waiting for a codex app-server
    event-observer connection that a bare stdio client never establishes. The
    app-server-hosted node_repl path DOES hold that observer connection (it is
    the same session that drives Record & Replay), so route desktop control
    through ``globalThis.sky.<tool>(<arguments>)`` there instead.

    Returns an MCP-style result: {"content": [...], "isError": bool}.
    """
    # sky mutating calls return no useful payload; read calls return an object.
    # Serialize the result to JSON text so it survives the node_repl string pipe.
    payload = json.dumps(arguments or {}, ensure_ascii=False)
    code = (
        "if (typeof globalThis.sky === 'undefined' || !globalThis.sky) {\n"
        f"  const mod = await import(\"{CLIENT_MJS}\");\n"
        "  await mod.setupComputerUseRuntime({ globals: globalThis });\n"
        "}\n"
        f"const __args = {payload};\n"
        f"const __r = await globalThis.sky[{json.dumps(tool)}](__args);\n"
        "nodeRepl.write(JSON.stringify(__r === undefined ? {ok: true} : __r));"
    )
    result = _session.call_js(code, timeout_ms=timeout_ms)
    text = _content_text(result)
    if result.get("isError"):
        return {"content": [{"type": "text", "text": text or "sky call failed"}],
                "isError": True}
    return {"content": [{"type": "text", "text": text}], "isError": False}


def execute_cua_tool(tool: str, arguments: dict, timeout_ms: int = 30000) -> dict:
    """Route a structured desktop-control call to the desktop backend.

    Two transports:
      - node_repl (default): drive ``sky.<tool>`` inside the app-server-hosted
        node_repl, which holds the CUAService event-observer connection.
      - mcp: drive the signed ``cua mcp`` stdio child directly. NOTE: this path
        cannot service list_apps/get_app_state in the current runtime because
        CUAService blocks on a missing app-server event-observer connection.

    Returns an MCP-style result: {"content": [...], "isError": bool}.
    """
    if tool not in CUA_MCP_TOOLS:
        return {
            "content": [{"type": "text",
                         "text": f"unknown cua tool: {tool}; valid: {', '.join(CUA_MCP_TOOLS)}"}],
            "isError": True,
        }
    if SKY_TRANSPORT == "mcp":
        return mcp_client().call_tool(tool, arguments or {}, timeout_ms=timeout_ms)
    return _execute_cua_via_node_repl(tool, arguments or {}, timeout_ms=timeout_ms)


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
    if "exited before returning a response" in low or "-10005" in low:
        return "cua_service_rpc_failed"
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

    # MCP transport: desktop control runs in-process via the signed cua mcp
    # child. Readiness == the child can service list_apps (proves the native
    # pipe + CUAService + TCC automation approval are all in place).
    if SKY_TRANSPORT == "mcp":
        try:
            r = mcp_client().list_apps(timeout_ms=12000)
        except Exception as exc:  # noqa: BLE001 - surfaced as reason
            res["reason"] = f"mcp_error: {exc}"
            return res
        text = _content_text(r)
        if r.get("isError"):
            res["reason"] = _classify_probe_error(text)
            return res
        res["live"] = True
        res["sky"] = True
        res["ready"] = True
        res["socket"] = True
        res["reason"] = "ok"
        return res

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

    # MCP transport does not use the codex app-server / node_repl at all;
    # liveness == the signed cua mcp child is (or can be) spawned. Avoid
    # touching the app-server here so a stale launchd app-server token cannot
    # make /health report router_error (401) for a router that is actually fine.
    if SKY_TRANSPORT == "mcp":
        try:
            mcp_client().ensure()
        except Exception as exc:  # noqa: BLE001 - surfaced as reason
            res["reason"] = f"mcp_error: {exc}"
            return res
        res["ready"] = True
        res["live"] = True
        res["reason"] = "cua_mcp_live"
        return res

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

def shutdown_router(server, session):
    """Release resources owned by the router after its serve loop stops."""
    session.close()
    if _mcp_client is not None:
        with contextlib.suppress(Exception):
            _mcp_client.close()
    server.server_close()


class RouterHandler(BaseHTTPRequestHandler):
    # Port the server listens on; set by main() so Host allowlist can match it.
    listen_port: int = 18901

    def log_message(self, fmt, *args):
        print(f"[http] {fmt % args}", flush=True)

    def _write_json(self, obj: dict, status: int = 200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _reject(self, status: int, message: str):
        """Send a small JSON error for a rejected protected request."""
        self._write_json({"isError": True, "error": message,
                          "content": [{"type": "text", "text": message}]}, status)

    def _authorize_protected(self) -> bool:
        """Guard endpoints that execute code / drive the desktop.

        Requires (1) a loopback Host header and (2) a matching capability
        token via X-CUA-Token or Authorization: Bearer. Returns True when the
        request may proceed; otherwise writes the error response and returns
        False. Liveness probes must NOT call this.
        """
        if not _host_is_localhost(self.headers.get("Host", ""), self.listen_port):
            self._reject(403, "forbidden: non-local Host header rejected")
            return False
        expected = _read_router_token()
        if not expected:
            self._reject(
                503,
                "router token unavailable; run: bash scripts/daemon.sh restart",
            )
            return False
        provided = _extract_request_token(self.headers)
        if not provided or not hmac.compare_digest(provided, expected):
            self._reject(
                401,
                "unauthorized: missing or invalid capability token "
                "(set X-CUA-Token or Authorization: Bearer; "
                "run 'bash scripts/daemon.sh restart' if it was rotated)",
            )
            return False
        return True

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
            # Liveness probe: status only, stays open (no token / Host guard).
            self._handle_ready(deep=bool(req_body.get("deep", True)))
            return

        if self.path.split("?", 1)[0] == "/record":
            # Protected: drives Record & Replay on the desktop.
            if not self._authorize_protected():
                return
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

        if self.path.split("?", 1)[0] == "/cua":
            # Protected: structured desktop-control call routed to the signed
            # cua mcp child (MCP transport). body:
            #   {"tool": "get_app_state", "arguments": {...}, "timeout_ms": N}
            if not self._authorize_protected():
                return
            tool = str(req_body.get("tool", "")).strip()
            arguments = req_body.get("arguments") or {}
            timeout_ms = int(req_body.get("timeout_ms", 30000))
            if not isinstance(arguments, dict):
                resp_bytes = json.dumps({
                    "isError": True,
                    "content": [{"type": "text", "text": "arguments must be an object"}],
                }).encode()
            else:
                try:
                    result = execute_cua_tool(tool, arguments, timeout_ms=timeout_ms)
                    resp_bytes = json.dumps(result, ensure_ascii=False).encode()
                except Exception as e:  # noqa: BLE001
                    print(f"[cua] error: {e}", flush=True)
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
            # Protected: executes arbitrary JS in node_repl (full RCE surface).
            if not self._authorize_protected():
                return
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

        # Protected: mcp_loop can execute node_repl tool_calls on the desktop.
        if not self._authorize_protected():
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
    print(f"[cua-router] sky transport: {SKY_TRANSPORT}", flush=True)
    if SKY_TRANSPORT == "mcp":
        # MCP transport does not need node_repl; warm the signed cua mcp child
        # so the first /cua call is fast. Failure here is non-fatal (the child
        # respawns lazily on demand).
        print(f"[cua-router] warming up cua mcp child...", flush=True)
        try:
            mcp_client().ensure()
        except Exception as exc:  # noqa: BLE001
            print(f"[cua-router] warning: cua mcp warmup failed: {exc}", flush=True)
    else:
        print(f"[cua-router] warming up bundled app-server...", flush=True)
        _session.ensure()

    print(f"[cua-router] listening on http://localhost:{args.port}", flush=True)
    # Bind the listen port so the Host allowlist matches the actual port.
    RouterHandler.listen_port = args.port
    server = RouterHTTPServer(("127.0.0.1", args.port), RouterHandler)
    stopping = threading.Event()

    def request_shutdown(signum, _frame):
        if stopping.is_set():
            return
        stopping.set()
        print(f"[cua-router] received signal {signum}, shutting down...", flush=True)
        # BaseServer.shutdown() must run outside the serve_forever() thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    try:
        server.serve_forever()
    finally:
        shutdown_router(server, _session)
        print("[cua-router] stopped", flush=True)
