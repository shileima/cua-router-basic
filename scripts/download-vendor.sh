#!/usr/bin/env bash
# Download and extract a prebuilt vendor tarball into SKILL_ROOT/vendor/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SKILL_ROOT="$COMMON_SKILL_ROOT"
URL=""
FORCE=0
PLATFORM=""

usage() {
  cat <<EOF
Usage: $0 [options]

Download vendor/ from a release tarball and verify manifest + sky client checksum.

Options:
  --url URL           Vendor tarball URL (or set CUA_ROUTER_VENDOR_URL)
  --skill-root PATH   Skill root (default: parent of scripts/)
  --platform ID       Platform tag, e.g. darwin-arm64 (default: auto-detect)
  --force             Replace existing vendor/
  -h, --help          Show help

Environment:
  CUA_ROUTER_VENDOR_URL     Direct tarball URL
  CUA_ROUTER_RELEASE_BASE   Override release base URL
  CUA_ROUTER_GITHUB_REPO    Default repo: shileima/cua-router-basic
                            → https://github.com/<repo>/releases/download/v<version>/...
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:?missing url}"; shift 2 ;;
    --skill-root) SKILL_ROOT="$(cd "${2:?missing path}" && pwd)"; shift 2 ;;
    --platform) PLATFORM="${2:?missing platform}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$PLATFORM" ] || PLATFORM="$(detect_platform)"
if [ "$PLATFORM" != "darwin-arm64" ]; then
  die "prebuilt vendor is only available for darwin-arm64 (detected: $PLATFORM)"
fi

if vendor_ready "$SKILL_ROOT" && [ "$FORCE" -ne 1 ]; then
  info "vendor already present in $SKILL_ROOT (use --force to replace)"
  exit 0
fi

if [ -z "$URL" ]; then
  URL="${CUA_ROUTER_VENDOR_URL:-}"
fi
if [ -z "$URL" ]; then
  version="$(read_version "$SKILL_ROOT")"
  URL="$(default_vendor_url "$version" "$PLATFORM")"
fi
[ -n "$URL" ] || die "no vendor URL; pass --url or set CUA_ROUTER_VENDOR_URL"

ensure_command curl
ensure_command tar
ensure_command python3

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cua-vendor.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

archive="$tmpdir/vendor.tar.gz"
checksum_url="${URL}.sha256"

info "downloading vendor from $URL"
curl -fsSL "$URL" -o "$archive"

if curl -fsSL "$checksum_url" -o "$tmpdir/vendor.tar.gz.sha256" 2>/dev/null; then
  info "verifying sha256"
  verify_sha256_sidecar "$archive" "$tmpdir/vendor.tar.gz.sha256"
else
  warn "no checksum file at $checksum_url — skipping sha256 verify"
fi

info "extracting vendor into $SKILL_ROOT"
rm -rf "$SKILL_ROOT/vendor"
ensure_install_parent "$SKILL_ROOT/vendor"
mkdir -p "$SKILL_ROOT/vendor"
tar -xzf "$archive" -C "$SKILL_ROOT"

vendor_ready "$SKILL_ROOT" || die "vendor incomplete after extract"

manifest="$SKILL_ROOT/vendor/manifest.json"
[ -f "$manifest" ] || die "missing vendor/manifest.json after extract"

python3 - "$manifest" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
required = ["extracted_at", "codex_version", "sky_client_sha256"]
missing = [k for k in required if k not in data]
if missing:
    raise SystemExit(f"invalid manifest, missing keys: {', '.join(missing)}")
print(json.dumps({k: data[k] for k in required}, ensure_ascii=False))
PY

info "vendor ready"
info "  codex:        $SKILL_ROOT/vendor/codex/bin/codex"
info "  cua_node:     $SKILL_ROOT/vendor/cua_node"
info "  computer-use: $SKILL_ROOT/vendor/computer-use/Codex Computer Use.app"
