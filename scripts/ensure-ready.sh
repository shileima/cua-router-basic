#!/usr/bin/env bash
# automan / cua-agent 标准入口：启动 cua-router → 唤起 Computer Use 授权（如需）→ 验证在线。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

bash "$SCRIPT_DIR/daemon.sh" start
if ! bash "$SCRIPT_DIR/lib/request-permissions.sh" check >/dev/null 2>&1; then
  bash "$SCRIPT_DIR/daemon.sh" authorize
fi
bash "$SCRIPT_DIR/exec.sh" 'nodeRepl.write("ok")'
