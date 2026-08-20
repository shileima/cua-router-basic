"""Sandbox-free desktop-control transport for cua-router.

Background
----------
codex 0.148+ runs the ``node_repl`` tool inside a kernel-level seatbelt
sandbox that (a) no longer injects ``nodeRepl.nativePipe`` and (b) returns
``EPERM`` for every ``connect()``/``write()`` syscall. As a result ``@oai/sky``
can no longer reach the CUAService unix socket from inside node_repl, so all
desktop-control calls hang.

The CUAService socket lives in the App Group container
``2DC432GLL2.com.openai.sky.CUAService`` and only accepts peers signed with the
matching OpenAI team / app-group entitlement. A raw Python socket connection is
therefore rejected right after the ``ping`` handshake.

The bundled, OpenAI-signed ``SkyComputerUseClient`` binary ships a ``cua mcp``
subcommand that exposes the full desktop-control surface as a standard MCP
stdio server. Spawning it as a child process lets cua-router drive the desktop
*outside* the node_repl sandbox while the signed ``cua`` process is the one that
actually talks to the socket. This module implements a minimal, thread-safe MCP
stdio client around that child process.
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import time
from typing import Any, Dict, List, Optional

from vendor_paths import (
    computer_use_app,
    ensure_event_stream_home,
    sky_client_bin,
)


# MCP tools exposed by `cua mcp` (verified via tools/list).
CUA_MCP_TOOLS = (
    "list_apps",
    "get_app_state",
    "click",
    "perform_secondary_action",
    "set_value",
    "select_text",
    "scroll",
    "drag",
    "press_key",
    "type_text",
)

_MCP_PROTOCOL_VERSION = "2024-11-05"


class CuaMcpError(RuntimeError):
    """Raised when the cua mcp child cannot service a request."""


class CuaMcpClient:
    """Thread-safe MCP stdio client for the signed ``cua mcp`` child process.

    A single long-lived child is reused across calls. The child is (re)started
    lazily on first use and automatically respawned if it dies. All JSON-RPC
    traffic is newline-delimited (one JSON object per line), matching the
    server's framing.
    """

    def __init__(self, startup_timeout: float = 20.0):
        self._bin = str(sky_client_bin())
        self._startup_timeout = startup_timeout
        self._proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()          # serializes request/response
        self._start_lock = threading.Lock()    # serializes (re)start
        self._id = 0
        self._stderr_tail: List[str] = []
        # stdout is drained by a dedicated reader thread into this queue so a
        # hung child can never block a request past its timeout (a blocking
        # readline() cannot be interrupted otherwise).
        self._stdout_q: "queue.Queue[Optional[str]]" = queue.Queue()

    # ── lifecycle ──────────────────────────────────────────────

    def _alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def _spawn(self) -> None:
        env = os.environ.copy()
        # `cua mcp` resolves its runtime app from ``$CODEX_HOME/computer-use/
        # Codex Computer Use.app`` (it ignores SKY_CUA_SERVICE_PATH). Point
        # CODEX_HOME at this skill's runtime dir, which holds a
        # ``computer-use -> vendor/computer-use`` symlink, so the desktop
        # controller always uses the bundled, in-repo Computer Use app instead
        # of a stray ``~/.codex/computer-use`` copy.
        codex_home = ensure_event_stream_home()
        env["CODEX_HOME"] = str(codex_home)
        # Belt-and-suspenders: also expose the concrete app path.
        env.setdefault("SKY_CUA_SERVICE_PATH", str(computer_use_app()))
        proc = subprocess.Popen(
            [self._bin, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=env,
        )
        self._proc = proc
        self._stderr_tail = []
        self._stdout_q = queue.Queue()
        threading.Thread(target=self._drain_stdout, args=(proc,), daemon=True).start()
        threading.Thread(target=self._drain_stderr, args=(proc,), daemon=True).start()

        # MCP handshake: initialize → notifications/initialized.
        init = self._rpc_locked(
            "initialize",
            {
                "protocolVersion": _MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "cua-router", "version": "1.0"},
            },
            timeout=self._startup_timeout,
        )
        if not init or "result" not in init:
            self._kill()
            raise CuaMcpError(
                "cua mcp initialize failed"
                + (f": {self._stderr_snapshot()}" if self._stderr_tail else "")
            )
        self._notify_locked("notifications/initialized", {})

    def ensure(self) -> None:
        if self._alive():
            return
        with self._start_lock:
            if self._alive():
                return
            self._spawn()

    def _kill(self) -> None:
        proc, self._proc = self._proc, None
        if proc is None:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
        except Exception:
            pass

    def close(self) -> None:
        with self._start_lock:
            self._kill()

    def _drain_stdout(self, proc: subprocess.Popen) -> None:
        try:
            assert proc.stdout is not None
            for raw in proc.stdout:
                self._stdout_q.put(raw.decode("utf-8", "replace"))
        except Exception:
            pass
        finally:
            # Sentinel: signals EOF/child death to any waiting reader.
            self._stdout_q.put(None)

    def _drain_stderr(self, proc: subprocess.Popen) -> None:
        try:
            for raw in proc.stderr:
                line = raw.decode("utf-8", "replace").rstrip()
                if line:
                    self._stderr_tail.append(line)
                    if len(self._stderr_tail) > 50:
                        self._stderr_tail = self._stderr_tail[-50:]
                    print(f"[cua-mcp:stderr] {line}", flush=True)
        except Exception:
            pass

    def _stderr_snapshot(self) -> str:
        return " | ".join(self._stderr_tail[-5:])

    # ── low-level JSON-RPC (must hold self._lock) ──────────────

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _write(self, obj: Dict[str, Any]) -> None:
        assert self._proc is not None and self._proc.stdin is not None
        self._proc.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
        self._proc.stdin.flush()

    def _notify_locked(self, method: str, params: Any) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def _rpc_locked(self, method: str, params: Any, timeout: float) -> Optional[Dict]:
        assert self._proc is not None
        req_id = self._next_id()
        self._write({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            try:
                line = self._stdout_q.get(timeout=remaining)
            except queue.Empty:
                return None
            if line is None:
                # child closed stdout / reader ended → dead
                raise CuaMcpError(
                    "cua mcp closed the connection"
                    + (f": {self._stderr_snapshot()}" if self._stderr_tail else "")
                )
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                # Non-JSON line (should not happen); skip.
                continue
            # Ignore server-initiated notifications/other ids.
            if isinstance(msg, dict) and msg.get("id") == req_id:
                return msg

    # ── public API ─────────────────────────────────────────────

    def call_tool(self, name: str, arguments: Optional[dict] = None,
                  timeout_ms: int = 30000) -> dict:
        """Invoke an MCP tool and return an MCP-style result dict.

        Return shape mirrors ``AppServerSession.call_js`` so callers can treat
        both transports uniformly::

            {"content": [{"type": "text", "text": ...}], "isError": bool}
        """
        timeout = max(1.0, timeout_ms / 1000.0)
        try:
            self.ensure()
        except Exception as exc:
            return self._error(f"cua mcp start failed: {exc}")

        with self._lock:
            try:
                resp = self._rpc_locked(
                    "tools/call",
                    {"name": name, "arguments": arguments or {}},
                    timeout=timeout + 5.0,
                )
            except CuaMcpError as exc:
                # Child died mid-call; drop it so the next call respawns.
                self._kill()
                return self._error(str(exc))
            if resp is None:
                # A timed-out call leaves the child mid-request: the in-flight
                # tools/call may still be blocked inside CUAService, so any
                # later call would deadlock behind it. Kill the child (still
                # under the lock) so the next call spawns a clean one.
                self._kill()

        if resp is None:
            return self._error(f"cua mcp tool '{name}' timed out")
        if "error" in resp:
            err = resp["error"] or {}
            return self._error(
                f"cua mcp error {err.get('code')}: {err.get('message')}"
            )
        result = resp.get("result", {})
        # MCP tools return {content:[...], isError:bool}; pass through, but
        # normalize missing fields.
        content = result.get("content")
        if content is None:
            content = [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}]
        return {"content": content, "isError": bool(result.get("isError", False))}

    def list_apps(self, timeout_ms: int = 15000) -> dict:
        return self.call_tool("list_apps", {}, timeout_ms=timeout_ms)

    def get_app_state(self, app: str, timeout_ms: int = 20000) -> dict:
        # cua mcp's get_app_state schema only accepts {app} (additionalProperties:false).
        return self.call_tool(
            "get_app_state",
            {"app": app},
            timeout_ms=timeout_ms,
        )

    @staticmethod
    def _error(message: str) -> dict:
        return {"content": [{"type": "text", "text": message}], "isError": True}
