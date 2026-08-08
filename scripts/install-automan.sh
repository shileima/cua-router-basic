#!/usr/bin/env bash
# Register cua-router-basic and bundled companion skills in ~/.automan.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SKILL_ROOT="${SKILL_ROOT:-$COMMON_SKILL_ROOT}"

usage() {
  cat <<EOF
Usage: $0 [options]

Install cua-router-basic (+ bundled record-desk-basic) into the automan
cua-agent profile:
  ~/.automan/claude-code-agents/cua-agent/skills/cua-router-basic
  ~/.automan/claude-code-agents/cua-agent/skills/record-desk-basic

Also cleans up any legacy install at ~/.automan/skills/{cua-router-basic,record-desk-basic}
and stale symlinks in other agent profiles.

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
automan_available || die "automan profile not found: $(automan_profile_dir)"

sync_automan_install "$SKILL_ROOT"
info "automan sync complete for $SKILL_ROOT"
