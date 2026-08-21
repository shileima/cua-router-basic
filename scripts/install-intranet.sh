#!/usr/bin/env bash
# Intranet one-shot install: fetch slim + vendor from Sankuai S3plus instead of
# GitHub. Designed for machines without GitHub access.
#
# Usage:
#   curl -fsSL https://s3plus.sankuai.com/aiagent-bucket/cua-resources/install-intranet.sh | bash
#   bash scripts/install-intranet.sh --target ~/.cursor/skills/cua-router-basic
#   CUA_ROUTER_VERSION=0.4.18 bash scripts/install-intranet.sh
#
# Everything is downloaded from the intranet base (override with
# CUA_ROUTER_INTRANET_BASE), so no GitHub connectivity is required.
set -euo pipefail

# Intranet base is needed before common.sh is sourced (curl | bash bootstrap).
CUA_ROUTER_INTRANET_BASE="${CUA_ROUTER_INTRANET_BASE:-https://s3plus.sankuai.com/aiagent-bucket/cua-resources}"
CUA_ROUTER_INTRANET_BASE="${CUA_ROUTER_INTRANET_BASE%/}"
export CUA_ROUTER_INTRANET_BASE

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"
  common_init
else
  # curl | bash: bootstrap common helpers from the intranet base.
  COMMON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cua-intranet.XXXXXX")"
  cleanup_tmp() { rm -rf "$COMMON_TMP"; }
  trap cleanup_tmp EXIT
  curl -fsSL "${CUA_ROUTER_INTRANET_BASE}/lib/common.sh" -o "$COMMON_TMP/common.sh"
  # shellcheck source=/dev/null
  source "$COMMON_TMP/common.sh"
  common_init() { :; }
fi

TARGET=""
VERSION=""
VENDOR_MODE="auto"
INSTALL_CURSOR=1
FORCE=0

usage() {
  cat <<EOF
Usage: $0 [options]

Install cua-router-basic from the intranet (Sankuai S3plus). No GitHub needed.

Defaults:
  --target   ~/.automan/claude-code-agents/cua-agent/skills/cua-router-basic
             if the cua-agent profile exists,
             else ~/.cursor/skills/cua-router-basic (or CUA_ROUTER_INSTALL_DIR)
  --version  latest from <intranet-base>/.meta.json (or CUA_ROUTER_VERSION)

Options:
  --target PATH       Install destination
  --version VER       Pin release version for slim/vendor tarballs
  --vendor-mode MODE  auto | chatgpt | download (default: auto)
  --no-cursor         Skip install-cursor.sh
  --force             Replace existing install directory
  -h, --help          Show help

Environment:
  CUA_ROUTER_INTRANET_BASE  Public resource base URL
                            (default: https://s3plus.sankuai.com/aiagent-bucket/cua-resources)
  CUA_ROUTER_VERSION        Pin a specific version
  CUA_ROUTER_INSTALL_DIR    Override default install directory

Examples:
  curl -fsSL ${CUA_ROUTER_INTRANET_BASE}/install-intranet.sh | bash
  CUA_ROUTER_VERSION=0.4.18 bash scripts/install-intranet.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?missing path}"; shift 2 ;;
    --version) VERSION="${2:?missing version}"; shift 2 ;;
    --vendor-mode) VENDOR_MODE="${2:?missing mode}"; shift 2 ;;
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
  VERSION="$(fetch_intranet_version)" || die "could not fetch version from ${CUA_ROUTER_INTRANET_BASE}/.meta.json; pass --version"
fi
[ -n "$VERSION" ] || die "could not determine version; pass --version or set CUA_ROUTER_VERSION"

# Point every downstream download (slim url, download-vendor.sh) at the
# intranet version directory instead of GitHub Releases.
CUA_ROUTER_RELEASE_BASE="$(intranet_version_base "$VERSION")"
export CUA_ROUTER_RELEASE_BASE

skill_present() {
  [ -f "$TARGET/SKILL.md" ] && [ -x "$TARGET/scripts/daemon.sh" ]
}

install_slim_from_tarball() {
  ensure_command curl
  ensure_command tar
  local url tmpdir archive
  url="${CUA_ROUTER_SLIM_URL:-$(intranet_slim_url "$VERSION")}"
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

ensure_slim_package() {
  if skill_present && [ "$FORCE" -ne 1 ]; then
    info "skill package already present at $TARGET"
    return 0
  fi
  if [ -e "$TARGET" ] && [ "$FORCE" -eq 1 ]; then
    info "removing existing target: $TARGET"
    rm -rf "$TARGET"
  fi
  install_slim_from_tarball
  skill_present || die "slim install failed: $TARGET"
}

bootstrap_vendor_and_cursor() {
  local full_args=(--skill-root "$TARGET" --vendor-mode "$VENDOR_MODE")
  [ "$INSTALL_CURSOR" -eq 0 ] && full_args+=(--no-cursor)
  # Suppress install-full.sh's own authorization prompt; the intranet flow runs
  # maybe_prompt_authorize once at the end of main() to avoid a double prompt.
  CUA_ROUTER_AUTHORIZE_ON_INSTALL=off \
    bash "$TARGET/scripts/install-full.sh" "${full_args[@]}"
}

main() {
  info "cua-router-basic intranet install (version=$VERSION, target=$TARGET)"
  info "intranet base: $CUA_ROUTER_INTRANET_BASE"
  ensure_slim_package
  # Remember this is an intranet install so daemon.sh / update-intranet.sh keep
  # vendor bootstrap and updates on the intranet (no GitHub fallback).
  write_intranet_marker "$TARGET" "$CUA_ROUTER_INTRANET_BASE"

  # Distribute the bundled record-desk-basic companion skill BEFORE vendor
  # bootstrap. vendor download is the slowest / most fragile step (~700MB, may
  # time out or die on authorization prompts); if it fails, the top-level
  # sync_automan_install call below is skipped and record-desk-basic never
  # lands in <automan-profile>/skills/. Since the companion skill only needs
  # the already-unpacked slim files (no vendor deps), publish it now so the
  # cua-agent can start event-stream recording even when vendor is still WIP.
  if automan_available; then
    sync_record_desk_basic_install "$TARGET" || \
      warn "record-desk-basic companion skill sync failed (will retry after vendor bootstrap)"
  fi

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
  # Foreground-prompt Computer Use permissions at install time (once).
  maybe_prompt_authorize "$TARGET"
  info "install complete"
  info "SKILL_ROOT=$TARGET"
  info "verify: bash \"$TARGET/scripts/daemon.sh\" status"
  printf 'SKILL_ROOT=%s\n' "$TARGET"
}

main "$@"
