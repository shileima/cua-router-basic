"""Resolve bundled vendor paths for cua-router-basic."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
VENDOR = SKILL_ROOT / "vendor"
RUNTIME = Path(os.environ.get("CUA_ROUTER_RUNTIME_DIR", SKILL_ROOT / "runtime")).expanduser()


def codex_bin() -> Path:
    override = os.environ.get("CODEX_BIN")
    if override:
        return Path(override)
    return VENDOR / "codex" / "bin" / "codex"


def cua_node_dir() -> Path:
    return VENDOR / "cua_node"


def node_repl_bin() -> Path:
    return cua_node_dir() / "bin" / "node_repl"


def node_bin() -> Path:
    return cua_node_dir() / "bin" / "node"


def node_modules_dir() -> Path:
    return cua_node_dir() / "lib" / "node_modules"


def sky_module_dir() -> Path:
    return node_modules_dir() / "@oai" / "sky"


def computer_use_dir() -> Path:
    return VENDOR / "computer-use"


def computer_use_app() -> Path:
    return computer_use_dir() / "Codex Computer Use.app"


def sky_client_bin() -> Path:
    return (
        computer_use_app()
        / "Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    )


def event_stream_home() -> Path:
    """CODEX_HOME for the event-stream mcp child.

    Record & Replay must share the app-server CODEX_HOME so its event observer
    chain is available. The client also resolves its runtime app from
    ``$CODEX_HOME/computer-use/Codex Computer Use.app``, so we place that
    symlink directly under the shared runtime directory.
    """
    return RUNTIME


def ensure_event_stream_home() -> Path:
    """Create the event-stream CODEX_HOME with a computer-use symlink."""
    home = event_stream_home()
    home.mkdir(parents=True, exist_ok=True)
    link = home / "computer-use"
    target = computer_use_dir()
    if link.is_symlink():
        if os.readlink(link) != str(target):
            link.unlink()
            link.symlink_to(target)
    elif not link.exists():
        link.symlink_to(target)
    return home


def client_mjs() -> Path:
    return SKILL_ROOT / "scripts" / "computer-use-client.mjs"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text_if_changed(path: Path, content: str) -> None:
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return
    path.write_text(content, encoding="utf-8")


def ensure_vendor() -> None:
    required = [
        codex_bin(),
        node_repl_bin(),
        node_bin(),
        sky_module_dir(),
        sky_client_bin(),
        client_mjs(),
    ]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise FileNotFoundError(
            "vendor 依赖不完整，请先运行："
            f' bash "{SKILL_ROOT / "scripts" / "setup-vendor.sh"}"\n'
            "缺失：\n  - " + "\n  - ".join(missing)
        )


def write_runtime_config() -> Path:
    ensure_vendor()
    RUNTIME.mkdir(parents=True, exist_ok=True)
    config_path = RUNTIME / "config.toml"

    skill_root = str(SKILL_ROOT)
    runtime_dir = str(RUNTIME)
    node_repl = str(node_repl_bin())
    node_path = str(node_bin())
    module_dirs = str(node_modules_dir())
    codex_path = str(codex_bin())
    computer_use_path = str(computer_use_app())
    sky_client_path = str(sky_client_bin())
    es_home = str(ensure_event_stream_home())
    sky_sha = sha256_file(sky_client_bin())

    # Keep known Chrome plugin hashes for compatibility; append bundled sky client hash.
    trusted_hashes = ",".join(
        [
            "6d25aa7656feac858f3a3bdaea5bcbab0dbfd426c9de8e6931ce90c399ee8e4f",
            "e13fd947e846d3d306e9249dd3c73d14931b6494803dbafb16cef85e6add9506",
            sky_sha,
        ]
    )

    config_content = f'''ask_for_approval = "never"
sandbox_mode = "danger-full-access"
web_search = "disabled"

[features]
js_repl = true

[mcp_servers.node_repl]
command = "{node_repl}"
startup_timeout_sec = 120

[mcp_servers.node_repl.env]
NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS = "1000"
NODE_REPL_NODE_MODULE_DIRS = "{module_dirs}"
NODE_REPL_NODE_PATH = "{node_path}"
NODE_REPL_TRUSTED_CODE_PATHS = "{skill_root}"
CODEX_HOME = "{runtime_dir}"
NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = "{trusted_hashes}"
NODE_REPL_INSTRUCTIONS_USE_CASE_COMPUTER_USE = "Control desktop apps on macOS through Computer Use."
SKY_CUA_SERVICE_PATH = "{computer_use_path}"
CODEX_CLI_PATH = "{codex_path}"

[mcp_servers.event_stream]
command = "{sky_client_path}"
args = ["event-stream", "mcp"]
startup_timeout_sec = 120

[mcp_servers.event_stream.env]
CODEX_HOME = "{es_home}"
SKY_CUA_SERVICE_PATH = "{computer_use_path}"
'''
    write_text_if_changed(config_path, config_content)

    manifest = {
        "skill_root": skill_root,
        "runtime_dir": runtime_dir,
        "codex_bin": codex_path,
        "cua_node": str(cua_node_dir()),
        "sky_module": str(sky_module_dir()),
        "computer_use_app": computer_use_path,
        "sky_client_sha256": sky_sha,
    }
    write_text_if_changed(RUNTIME / "vendor-paths.json", json.dumps(manifest, indent=2) + "\n")
    return config_path
