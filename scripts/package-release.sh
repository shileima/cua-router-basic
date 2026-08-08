#!/usr/bin/env bash
# Build slim + vendor release tarballs with sha256 sidecars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SKILL_ROOT="$COMMON_SKILL_ROOT"
OUT_DIR="$SKILL_ROOT/dist"
VERSION=""
PLATFORM=""
SKIP_VENDOR=0

usage() {
  cat <<EOF
Usage: $0 [options]

Create release artifacts under dist/:
  cua-router-basic-slim-<version>.tar.gz
  cua-router-basic-vendor-<platform>-<version>.tar.gz
  SHA256SUMS

Options:
  --out-dir PATH      Output directory (default: ./dist)
  --version VER       Override version (default: .meta.json)
  --platform ID       Platform tag (default: darwin-arm64 if vendor present)
  --skip-vendor       Only build slim tarball
  -h, --help          Show help

Requires a populated vendor/ unless --skip-vendor is set.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$(cd "${2:?missing path}" && pwd)"; shift 2 ;;
    --version) VERSION="${2:?missing version}"; shift 2 ;;
    --platform) PLATFORM="${2:?missing platform}"; shift 2 ;;
    --skip-vendor) SKIP_VENDOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$VERSION" ] || VERSION="$(read_version "$SKILL_ROOT")"
[ -n "$PLATFORM" ] || PLATFORM="$(detect_platform)"

ensure_command tar
ensure_command shasum

mkdir -p "$OUT_DIR"

slim_name="$(slim_archive_name "$VERSION")"
slim_path="$OUT_DIR/$slim_name"

info "packaging slim -> $slim_path"
tar -czf "$slim_path" \
  -C "$SKILL_ROOT" \
  SKILL.md \
  .meta.json \
  scripts \
  record-desk-basic \
  vendor/README.md \
  vendor/.gitkeep

(
  cd "$OUT_DIR"
  shasum -a 256 "$(basename "$slim_path")"
) > "$slim_path.sha256"

if [ "$SKIP_VENDOR" -eq 1 ]; then
  info "skip-vendor set; slim only"
  cat "$slim_path.sha256" > "$OUT_DIR/SHA256SUMS"
  info "done: $OUT_DIR"
  exit 0
fi

vendor_ready "$SKILL_ROOT" || die "vendor/ incomplete — run setup-vendor.sh first or use --skip-vendor"

vendor_name="$(vendor_archive_name "$VERSION" "$PLATFORM")"
vendor_path="$OUT_DIR/$vendor_name"

info "packaging vendor ($PLATFORM) -> $vendor_path"
tar -czf "$vendor_path" -C "$SKILL_ROOT" vendor

(
  cd "$OUT_DIR"
  shasum -a 256 "$(basename "$vendor_path")"
) > "$vendor_path.sha256"

{
  cat "$slim_path.sha256"
  cat "$vendor_path.sha256"
} > "$OUT_DIR/SHA256SUMS"

python3 - "$SKILL_ROOT/vendor/manifest.json" "$VERSION" "$PLATFORM" <<'PY' > "$OUT_DIR/release-manifest.json"
import json, sys
from datetime import datetime, timezone

vendor_manifest = json.load(open(sys.argv[1], encoding="utf-8"))
payload = {
    "name": "cua-router-basic",
    "version": sys.argv[2],
    "platform": sys.argv[3],
    "packaged_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "vendor": vendor_manifest,
    "artifacts": {
        "slim": f"cua-router-basic-slim-{sys.argv[2]}.tar.gz",
        "vendor": f"cua-router-basic-vendor-{sys.argv[3]}-{sys.argv[2]}.tar.gz",
    },
}
print(json.dumps(payload, indent=2, ensure_ascii=False))
print()
PY

info "release artifacts:"
info "  $slim_path ($(du -h "$slim_path" | awk '{print $1}'))"
info "  $vendor_path ($(du -h "$vendor_path" | awk '{print $1}'))"
info "  $OUT_DIR/SHA256SUMS"
info "  $OUT_DIR/release-manifest.json"
info ""
info "publish vendor URL example:"
info "  bash scripts/download-vendor.sh   # uses GitHub Releases by default"
info "  # or: CUA_ROUTER_RELEASE_BASE=https://github.com/shileima/cua-router-basic/releases/download/v${VERSION} bash scripts/download-vendor.sh"
