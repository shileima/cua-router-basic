#!/usr/bin/env bash
# Install the slim skill package (SKILL.md + scripts) without vendor binaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SOURCE="$COMMON_SKILL_ROOT"
TARGET="${CUA_ROUTER_INSTALL_DIR:-$HOME/.automan/skills/cua-router-basic}"
GIT_URL=""
INSTALL_CURSOR=1
FORCE=0

usage() {
  cat <<EOF
Usage: $0 [options]

Copy or clone the slim cua-router-basic package (~50 KB) without vendor/.

Options:
  --source PATH       Local skill root to copy from (default: this repo)
  --target PATH       Install destination (default: ~/.automan/skills/cua-router-basic)
  --git-url URL       Clone from git instead of copying --source
  --no-cursor         Skip install-cursor.sh (no ~/.cursor/skills symlink / pin)
  --force             Replace existing target directory
  -h, --help          Show help

After install, populate vendor/ with one of:
  bash "\$TARGET/scripts/setup-vendor.sh"          # from ChatGPT.app
  bash "\$TARGET/scripts/download-vendor.sh"       # from release tarball
  bash "\$TARGET/scripts/install-full.sh"          # auto-detect best source
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$(cd "${2:?missing path}" && pwd)"; shift 2 ;;
    --target) TARGET="$(cd "${2:?/}" 2>/dev/null && pwd || echo "${2:?missing path}")"; shift 2 ;;
    --git-url) GIT_URL="${2:?missing url}"; shift 2 ;;
    --no-cursor) INSTALL_CURSOR=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

TARGET="$(expand_home_path "$TARGET")"

install_from_git() {
  ensure_command git
  if [ -d "$TARGET/.git" ] || [ -f "$TARGET/SKILL.md" ]; then
    if [ "$FORCE" -ne 1 ]; then
      die "target already exists: $TARGET (use --force)"
    fi
    rm -rf "$TARGET"
  fi
  ensure_install_parent "$TARGET"
  info "cloning $GIT_URL -> $TARGET"
  git clone --depth 1 "$GIT_URL" "$TARGET"
}

install_from_source() {
  [ -f "$SOURCE/SKILL.md" ] || die "invalid source (missing SKILL.md): $SOURCE"
  if [ -e "$TARGET" ]; then
    if [ "$FORCE" -ne 1 ]; then
      die "target already exists: $TARGET (use --force)"
    fi
    rm -rf "$TARGET"
  fi
  ensure_install_parent "$TARGET"
  info "copying slim package $SOURCE -> $TARGET"
  mkdir -p "$TARGET/scripts" "$TARGET/vendor"
  cp "$SOURCE/SKILL.md" "$TARGET/"
  [ -f "$SOURCE/.meta.json" ] && cp "$SOURCE/.meta.json" "$TARGET/"
  cp -R "$SOURCE/scripts/." "$TARGET/scripts/"
  if [ -f "$SOURCE/vendor/README.md" ]; then
    cp "$SOURCE/vendor/README.md" "$TARGET/vendor/"
  fi
  touch "$TARGET/vendor/.gitkeep"
}

if [ -n "$GIT_URL" ]; then
  install_from_git
else
  install_from_source
fi

if vendor_ready "$TARGET"; then
  warn "target already contains vendor/ — slim install keeps existing vendor"
else
  info "slim install complete (vendor/ not included)"
  info "next: bash \"$TARGET/scripts/install-full.sh\""
fi

if [ "$INSTALL_CURSOR" -eq 1 ]; then
  SKILL_ROOT="$TARGET" bash "$TARGET/scripts/install-cursor.sh"
fi

info "installed to $TARGET"
