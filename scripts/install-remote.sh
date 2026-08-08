#!/usr/bin/env bash
# Agent-friendly one-shot install: slim skill package + vendor bootstrap + Cursor registration.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
#   bash scripts/install-remote.sh --target ~/.cursor/skills/cua-router-basic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"
  common_init
else
  # curl | bash: bootstrap common helpers inline
  COMMON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cua-remote.XXXXXX")"
  cleanup_tmp() { rm -rf "$COMMON_TMP"; }
  trap cleanup_tmp EXIT
  REPO="${CUA_ROUTER_GITHUB_REPO:-shileima/cua-router-basic}"
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/lib/common.sh" -o "$COMMON_TMP/common.sh"
  # shellcheck source=/dev/null
  source "$COMMON_TMP/common.sh"
  common_init() { :; }
fi

TARGET=""
VERSION=""
VENDOR_MODE="auto"
INSTALL_CURSOR=1
FORCE=0
USE_GIT=0
GIT_URL=""

usage() {
  cat <<EOF
Usage: $0 [options]

Install cua-router-basic for Agent use without requiring a prior git clone.

Defaults:
  --target   ~/.automan/claude-code-agents/cua-agent/skills/cua-router-basic
             if the cua-agent profile exists,
             else ~/.cursor/skills/cua-router-basic (or CUA_ROUTER_INSTALL_DIR)
  --version  latest from GitHub main/.meta.json (or CUA_ROUTER_VERSION)

When the automan cua-agent profile exists, also:
  - installs bundled companion skill record-desk-basic alongside, at
    ~/.automan/claude-code-agents/cua-agent/skills/record-desk-basic
  - removes legacy install at ~/.automan/skills/{cua-router-basic,record-desk-basic}
    and stale symlinks in other agent profiles
  - registers ~/.cursor/skills/cua-router-basic -> skill root (via install-cursor.sh)

Options:
  --target PATH       Install destination
  --version VER       Pin release version for slim/vendor tarballs
  --vendor-mode MODE  auto | chatgpt | download (default: auto)
  --git-clone         Clone repo instead of downloading slim tarball
  --git-url URL       Git remote (default: https://github.com/<repo>.git)
  --no-cursor         Skip install-cursor.sh
  --force             Replace existing install directory
  -h, --help          Show help

Examples:
  curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
  CUA_ROUTER_VERSION=0.3.1 bash scripts/install-remote.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?missing path}"; shift 2 ;;
    --version) VERSION="${2:?missing version}"; shift 2 ;;
    --vendor-mode) VENDOR_MODE="${2:?missing mode}"; shift 2 ;;
    --git-clone) USE_GIT=1; shift ;;
    --git-url) GIT_URL="${2:?missing url}"; USE_GIT=1; shift 2 ;;
    --no-cursor) INSTALL_CURSOR=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$TARGET" ] || TARGET="$(default_install_dir)"
TARGET="$(expand_home_path "$TARGET")"
case "$VENDOR_MODE" in
  auto|chatgpt|download) ;;
  *) die "invalid --vendor-mode: $VENDOR_MODE" ;;
esac

if [ -z "$VERSION" ]; then
  VERSION="${CUA_ROUTER_VERSION:-}"
fi
if [ -z "$VERSION" ]; then
  ensure_command curl
  VERSION="$(fetch_remote_version)"
fi
[ -n "$VERSION" ] || die "could not determine version; pass --version or set CUA_ROUTER_VERSION"

skill_present() {
  [ -f "$TARGET/SKILL.md" ] && [ -x "$TARGET/scripts/daemon.sh" ]
}

install_slim_from_tarball() {
  ensure_command curl
  ensure_command tar
  local url tmpdir archive
  url="${CUA_ROUTER_SLIM_URL:-$(default_slim_url "$VERSION")}"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cua-slim.XXXXXX")"
  archive="$tmpdir/slim.tar.gz"
  info "downloading slim package from $url"
  curl -fsSL "$url" -o "$archive"
  if curl -fsSL "${url}.sha256" -o "$tmpdir/slim.tar.gz.sha256" 2>/dev/null; then
    verify_sha256_sidecar "$archive" "$tmpdir/slim.tar.gz.sha256"
  else
    warn "no slim checksum sidecar at ${url}.sha256; skipping verify"
  fi
  if [ -L "$TARGET" ] && [ ! -e "$TARGET" ]; then
    warn "removing broken install symlink: $TARGET"
    rm "$TARGET"
  fi
  ensure_install_parent "$TARGET"
  mkdir -p "$TARGET"
  tar -xzf "$archive" -C "$TARGET"
  rm -rf "$tmpdir"
}

install_slim_from_git() {
  ensure_command git
  [ -n "$GIT_URL" ] || GIT_URL="$(default_git_url)"
  if [ -e "$TARGET" ]; then
    [ "$FORCE" -eq 1 ] || die "target already exists: $TARGET (use --force)"
    rm -rf "$TARGET"
  fi
  ensure_install_parent "$TARGET"
  info "cloning $GIT_URL -> $TARGET"
  git clone --depth 1 --branch "v${VERSION}" "$GIT_URL" "$TARGET" 2>/dev/null \
    || git clone --depth 1 "$GIT_URL" "$TARGET"
}

ensure_slim_package() {
  if skill_present && [ "$FORCE" -ne 1 ]; then
    info "skill package already present at $TARGET"
    return 0
  fi
  if [ -e "$TARGET" ] && [ "$FORCE" -eq 1 ]; then
    info "removing existing target: $TARGET"
    rm -rf "$TARGET"
  fi
  if [ "$USE_GIT" -eq 1 ]; then
    install_slim_from_git
  else
    install_slim_from_tarball
  fi
  skill_present || die "slim install failed: $TARGET"
}

bootstrap_vendor_and_cursor() {
  local full_args=(--skill-root "$TARGET" --vendor-mode "$VENDOR_MODE")
  [ "$INSTALL_CURSOR" -eq 0 ] && full_args+=(--no-cursor)
  bash "$TARGET/scripts/install-full.sh" "${full_args[@]}"
}

main() {
  info "cua-router-basic remote install (version=$VERSION, target=$TARGET)"
  ensure_slim_package
  if vendor_ready "$TARGET"; then
    info "vendor already present"
    if [ "$INSTALL_CURSOR" -eq 1 ]; then
      SKILL_ROOT="$TARGET" bash "$TARGET/scripts/install-cursor.sh"
    fi
  else
    bootstrap_vendor_and_cursor
  fi
  vendor_ready "$TARGET" || die "vendor bootstrap failed"
  sync_automan_install "$TARGET"
  info "install complete"
  info "SKILL_ROOT=$TARGET"
  info "verify: bash \"$TARGET/scripts/daemon.sh\" status"
  printf 'SKILL_ROOT=%s\n' "$TARGET"
}

main "$@"
