#!/usr/bin/env bash
# Register cua-router-basic in ~/.automan (Claude Code agents skills symlink).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SKILL_ROOT="${SKILL_ROOT:-$COMMON_SKILL_ROOT}"

usage() {
  cat <<EOF
Usage: $0 [options]

When ~/.automan/skills exists, ensure:
  - ~/.automan/claude-code-agents/main/skills/cua-router-basic -> ../../../skills/cua-router-basic

Options:
  --skill-root PATH   Skill root (default: parent of scripts/)
  -h, --help          Show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skill-root) SKILL_ROOT="$(cd "${2:?missing path}" && pwd)"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -f "$SKILL_ROOT/SKILL.md" ] || die "invalid skill root (missing SKILL.md): $SKILL_ROOT"
automan_skills_available || die "~/.automan/skills not found; nothing to sync"

sync_automan_install "$SKILL_ROOT"
info "automan sync complete for $SKILL_ROOT"
