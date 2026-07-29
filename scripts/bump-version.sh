#!/usr/bin/env bash
# Bump version in .meta.json and Plugin manifests (semver x.y.z).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

NEW_VERSION="${1:-}"
[ -n "$NEW_VERSION" ] || die "usage: $0 <version>  (e.g. 0.4.0)"

python3 - "$COMMON_SKILL_ROOT" "$NEW_VERSION" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
version = sys.argv[2]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit(f"invalid semver: {version}")

PLUGIN_NAME = "cua-router-basic"


def write_json(path: Path, data: dict) -> None:
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


updated: list[str] = []

meta_path = root / ".meta.json"
meta = json.loads(meta_path.read_text(encoding="utf-8"))
meta["version"] = version
write_json(meta_path, meta)
updated.append(str(meta_path.relative_to(root)))

cursor_plugin = root / ".cursor-plugin" / "plugin.json"
if cursor_plugin.is_file():
    data = json.loads(cursor_plugin.read_text(encoding="utf-8"))
    data["version"] = version
    write_json(cursor_plugin, data)
    updated.append(str(cursor_plugin.relative_to(root)))

claude_plugin = root / ".claude-plugin" / "plugin.json"
if claude_plugin.is_file():
    data = json.loads(claude_plugin.read_text(encoding="utf-8"))
    data["version"] = version
    write_json(claude_plugin, data)
    updated.append(str(claude_plugin.relative_to(root)))

marketplace = root / ".claude-plugin" / "marketplace.json"
if marketplace.is_file():
    data = json.loads(marketplace.read_text(encoding="utf-8"))
    plugins = data.get("plugins")
    if not isinstance(plugins, list):
        raise SystemExit(f"invalid marketplace.json: missing plugins array")
    matched = False
    for plugin in plugins:
        if isinstance(plugin, dict) and plugin.get("name") == PLUGIN_NAME:
            plugin["version"] = version
            matched = True
    if not matched:
        raise SystemExit(f"plugin {PLUGIN_NAME!r} not found in marketplace.json")
    write_json(marketplace, data)
    updated.append(str(marketplace.relative_to(root)))

print(version)
for rel in updated:
    print(f"  updated {rel}")
PY

info "version -> $NEW_VERSION"
