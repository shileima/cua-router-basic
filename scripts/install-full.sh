#!/usr/bin/env bash
# Install cua-router-basic with vendor/ (ChatGPT extract or release download).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SKILL_ROOT="$COMMON_SKILL_ROOT"
TARGET=""
VENDOR_MODE="auto"
VENDOR_URL=""
INSTALL_CURSOR=1
FORCE_VENDOR=0
RUN_SLIM=0
SLIM_SOURCE="$COMMON_SKILL_ROOT"

usage() {
  cat <<EOF
Usage: $0 [options]

Ensure vendor/ is present, optionally run slim install first, then register in Cursor/Automan.
When Automan is available, the bundled record-desk-basic companion skill is installed too.

Vendor sources (--vendor-mode):
  auto          Prefer ChatGPT.app extract; fall back to release download (default)
  chatgpt       bash setup-vendor.sh (requires ChatGPT + Computer Use plugin)
  download      bash download-vendor.sh (requires URL or CUA_ROUTER_RELEASE_BASE)
  skip          Do not modify vendor/ (fail if missing)

Options:
  --target PATH       Install destination for slim step (with --run-slim)
  --skill-root PATH   Skill root for vendor step (default: parent of scripts/)
  --vendor-mode MODE  auto | chatgpt | download | skip
  --vendor-url URL    Pass through to download-vendor.sh
  --run-slim          Run install-slim.sh before vendor setup
  --source PATH       Source for --run-slim (default: this repo)
  --no-cursor         Skip install-cursor.sh
  --force-vendor      Replace existing vendor/ when downloading
  -h, --help          Show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?missing path}"; shift 2 ;;
    --skill-root) SKILL_ROOT="$(cd "${2:?missing path}" && pwd)"; shift 2 ;;
    --vendor-mode) VENDOR_MODE="${2:?missing mode}"; shift 2 ;;
    --vendor-url) VENDOR_URL="${2:?missing url}"; shift 2 ;;
    --run-slim) RUN_SLIM=1; shift ;;
    --source) SLIM_SOURCE="$(cd "${2:?missing path}" && pwd)"; shift 2 ;;
    --no-cursor) INSTALL_CURSOR=0; shift ;;
    --force-vendor) FORCE_VENDOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$VENDOR_MODE" in
  auto|chatgpt|download|skip) ;;
  *) die "invalid --vendor-mode: $VENDOR_MODE" ;;
esac

if [ "$RUN_SLIM" -eq 1 ]; then
  slim_args=(--source "$SLIM_SOURCE" --no-cursor)
  if [ -n "$TARGET" ]; then
    slim_args+=(--target "$TARGET")
    SKILL_ROOT="$TARGET"
  fi
  bash "$SCRIPT_DIR/install-slim.sh" "${slim_args[@]}"
fi

ensure_vendor_chatgpt() {
  info "extracting vendor from ChatGPT.app"
  bash "$SKILL_ROOT/scripts/setup-vendor.sh"
}

ensure_vendor_download() {
  dl_args=(--skill-root "$SKILL_ROOT")
  [ -n "$VENDOR_URL" ] && dl_args+=(--url "$VENDOR_URL")
  [ "$FORCE_VENDOR" -eq 1 ] && dl_args+=(--force)
  bash "$SKILL_ROOT/scripts/download-vendor.sh" "${dl_args[@]}"
}

ensure_vendor_auto() {
  if vendor_ready "$SKILL_ROOT"; then
    info "vendor already present"
    return 0
  fi
  if chatgpt_vendor_available; then
    ensure_vendor_chatgpt
    return 0
  fi
  info "ChatGPT.app vendor source unavailable; trying release download"
  ensure_vendor_download
}

case "$VENDOR_MODE" in
  skip)
    vendor_ready "$SKILL_ROOT" || die "vendor missing; run setup-vendor.sh or download-vendor.sh"
    ;;
  chatgpt)
    ensure_vendor_chatgpt
    ;;
  download)
    ensure_vendor_download
    ;;
  auto)
    ensure_vendor_auto
    ;;
esac

vendor_ready "$SKILL_ROOT" || die "vendor setup failed"

if [ "$INSTALL_CURSOR" -eq 1 ]; then
  SKILL_ROOT="$SKILL_ROOT" bash "$SKILL_ROOT/scripts/install-cursor.sh"
fi

sync_automan_install "$SKILL_ROOT"

# Vendor + registration are done; prompt for Computer Use permissions now so the
# "Enable ChatGPT Computer Use" window shows up at install time (foreground),
# not on the first silent desktop-control run.
maybe_prompt_authorize "$SKILL_ROOT"

info "full install complete: $SKILL_ROOT"
info "verify: bash \"$SKILL_ROOT/scripts/daemon.sh\" status"
