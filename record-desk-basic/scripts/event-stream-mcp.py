#!/usr/bin/env python3
"""Expose Record & Replay tools over stdio MCP while executing via cua-router."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import subprocess
from typing import Any

BASE = f"http://127.0.0.1:{os.environ.get('CUA_ROUTER_PORT', '18901')}"
PROTOCOL_VERSION = "2025-03-26"
TOOLS = [
    {
        "name": "event_stream_start",
        "description": "Start recording the user's actions for up to 30 minutes. If a recording is already active, return that active session instead of starting another one.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"destructiveHint": False, "idempotentHint": False, "openWorldHint": False, "readOnlyHint": False},
    },
    {
        "name": "event_stream_status",
        "description": "Get the current or most recent Record & Replay recording status including paths to metadata and events during the recording.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"destructiveHint": False, "idempotentHint": True, "openWorldHint": False, "readOnlyHint": True},
    },
    {
        "name": "event_stream_stop",
        "description": "Stop the active event stream recording if one is running and return status including paths to metadata and events during the recording.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"destructiveHint": False, "idempotentHint": True, "openWorldHint": False, "readOnlyHint": False},
    },
]


def send(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def call_router(action: str) -> dict[str, Any]:
    body = json.dumps({"action": action}).encode()
    request = urllib.request.Request(
        f"{BASE}/record",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            result = json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cua-router /record failed: {exc}") from exc
    if not isinstance(result, dict):
        raise RuntimeError("cua-router /record returned a non-object response")
    return result


def restore_router_without_event_stream() -> None:
    cua_root = os.environ.get("RDB_CUA_ROOT")
    if not cua_root:
        return
    env = os.environ.copy()
    env["CUA_ROUTER_ENABLE_EVENT_STREAM"] = "0"
    env["CUA_ROUTER_START_READINESS"] = "off"
    env["CUA_ROUTER_HEALTH_MODE"] = "app-server"
    subprocess.run(
        ["bash", os.path.join(cua_root, "scripts", "daemon.sh"), "restart"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def handle(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    if request_id is None:
        return None
    if method == "initialize":
        requested = (message.get("params") or {}).get("protocolVersion")
        protocol = requested if isinstance(requested, str) else PROTOCOL_VERSION
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": protocol,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "Record & Replay Router Proxy", "version": "1.0.0"},
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = (message.get("params") or {}).get("name", "")
        action = {
            "event_stream_start": "start",
            "event_stream_status": "status",
            "event_stream_stop": "stop",
        }.get(name)
        if action is None:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32602, "message": f"Unknown tool: {name}"},
            }
        try:
            result = call_router(action)
            if action == "stop":
                restore_router_without_event_stream()
        except Exception as exc:  # noqa: BLE001
            result = {"isError": True, "content": [{"type": "text", "text": str(exc)}]}
        return {"jsonrpc": "2.0", "id": request_id, "result": result}
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


def main() -> None:
    for raw in sys.stdin:
        try:
            message = json.loads(raw)
            if not isinstance(message, dict):
                raise ValueError("message must be an object")
            response = handle(message)
        except Exception as exc:  # noqa: BLE001
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": str(exc)},
            }
        if response is not None:
            send(response)


if __name__ == "__main__":
    main()
