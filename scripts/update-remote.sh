#!/usr/bin/env bash
# Check for cua-router-basic updates and optionally apply them.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/update-remote.sh | bash
#   curl -fsSL .../update-remote.sh | bash -s -- --check
#   bash scripts/update-remote.sh --check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"
  common_init
else
  COMMON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cua-update.XXXXXX")"
  cleanup_tmp() { rm -rf "$COMMON_TMP"; }
  trap cleanup_tmp EXIT
  REPO="${CUA_ROUTER_GITHUB_REPO:-shileima/cua-router-basic}"
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/lib/common.sh" -o "$COMMON_TMP/common.sh"
  # shellcheck source=/dev/null
  source "$COMMON_TMP/common.sh"
  common_init() { :; }
fi

CHECK_ONLY=0
FORCE=0
TARGET=""

usage() {
  cat <<EOF
Usage: $0 [options]

Compare local cua-router-basic version with GitHub main/.meta.json.
When versions differ (or --force), re-run install-remote.sh --force.

Options:
  --check, --check-only   Report status only; exit 0 if up to date,
                          exit 1 if not installed, exit 2 if update available
  --force                 Reinstall even when versions match
  --target PATH           Skill install directory (default: automan or cursor path)
  -h, --help              Show help

Output (machine-readable):
  status=up-to-date | update-available | not-installed
  version / local_version / remote_version when applicable

Examples:
  curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/update-remote.sh | bash -s -- --check
  curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/update-remote.sh | bash
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check|--check-only) CHECK_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --target) TARGET="${2:?missing path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$TARGET" ] || TARGET="$(default_install_dir)"
TARGET="$(expand_home_path "$TARGET")"

skill_installed() {
  [ -f "$TARGET/SKILL.md" ] && [ -x "$TARGET/scripts/daemon.sh" ]
}

read_local_version() {
  local meta="$TARGET/.meta.json"
  [ -f "$meta" ] || return 1
  read_version "$TARGET"
}

run_install_remote() {
  local install_args=(--target "$TARGET" --force)
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-remote.sh" ]; then
    bash "$SCRIPT_DIR/install-remote.sh" "${install_args[@]}"
    return 0
  fi
  ensure_command curl
  local repo url
  repo="$(github_repo)"
  url="https://raw.githubusercontent.com/${repo}/main/scripts/install-remote.sh"
  curl -fsSL "$url" | bash -s -- "${install_args[@]}"
}

main() {
  local local_version remote_version

  if ! skill_installed; then
    info "not installed at $TARGET"
    printf 'status=not-installed\n'
    if [ "$CHECK_ONLY" -eq 1 ]; then
      exit 1
    fi
    info "running fresh install"
    run_install_remote
    printf 'status=installed\n'
    return 0
  fi

  ensure_command curl
  local_version="$(read_local_version || echo unknown)"
  remote_version="$(fetch_remote_version)"

  if [ "$local_version" = "$remote_version" ] && [ "$FORCE" -ne 1 ]; then
    info "up to date ($local_version)"
    printf 'status=up-to-date\nversion=%s\n' "$local_version"
    exit 0
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    info "update available: $local_version -> $remote_version"
    printf 'status=update-available\nlocal_version=%s\nremote_version=%s\n' \
      "$local_version" "$remote_version"
    exit 2
  fi

  info "updating $local_version -> $remote_version"
  run_install_remote
  skill_installed || die "update failed: $TARGET"
  local_version="$(read_local_version || echo unknown)"
  info "update complete ($local_version)"
  printf 'status=updated\nversion=%s\n' "$local_version"
}

main "$@"
