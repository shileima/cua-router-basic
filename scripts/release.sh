#!/usr/bin/env bash
# Maintainer release: bump version, package artifacts, tag, publish GitHub Release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

VERSION=""
TAG=""
DRY_RUN=0
SKIP_GIT=0
SKIP_UPLOAD=0
NOTES_FILE=""

usage() {
  cat <<EOF
Usage: $0 [options] <version>

Publish cua-router-basic release to GitHub Releases.

Steps:
  1. bump .meta.json version
  2. package slim + vendor tarballs (requires local vendor/)
  3. commit version bump
  4. create git tag v<version>
  5. gh release create + upload dist/*

Options:
  --notes FILE        Release notes markdown file
  --dry-run           Package only; skip git tag and gh release
  --skip-git          Skip commit/tag (upload only)
  --skip-upload       Stop after packaging (no gh release)
  -h, --help          Show help

Examples:
  $0 0.3.0
  $0 --dry-run 0.4.0

Requires: gh auth login, local vendor/ populated (setup-vendor.sh)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES_FILE="${2:?missing file}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-git) SKIP_GIT=1; shift ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || { usage >&2; exit 1; }
TAG="v${VERSION}"

current="$(read_version)"
if [ "$current" != "$VERSION" ]; then
  bash "$SCRIPT_DIR/bump-version.sh" "$VERSION"
fi

vendor_ready "$COMMON_SKILL_ROOT" || die "vendor/ missing — run: bash scripts/setup-vendor.sh"

bash "$SCRIPT_DIR/package-release.sh" --version "$VERSION"

if [ "$DRY_RUN" -eq 1 ] || [ "$SKIP_UPLOAD" -eq 1 ]; then
  info "packaging done (--dry-run or --skip-upload)"
  exit 0
fi

ensure_command gh
ensure_command git

repo="$(github_repo)"
if [ "$SKIP_GIT" -eq 0 ]; then
  git -C "$COMMON_SKILL_ROOT" add \
    .meta.json \
    .cursor-plugin/plugin.json \
    .claude-plugin/plugin.json \
    .claude-plugin/marketplace.json
  if ! git -C "$COMMON_SKILL_ROOT" diff --cached --quiet; then
    git -C "$COMMON_SKILL_ROOT" commit -m "chore: release ${VERSION}"
  fi
  if git -C "$COMMON_SKILL_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    warn "tag $TAG already exists — skipping tag create"
  else
    git -C "$COMMON_SKILL_ROOT" tag -a "$TAG" -m "Release ${VERSION}"
  fi
fi

collect_release_assets() {
  RELEASE_ASSETS=()
  local f
  for f in \
    "$COMMON_SKILL_ROOT/dist/cua-router-basic-slim-${VERSION}.tar.gz" \
    "$COMMON_SKILL_ROOT/dist/cua-router-basic-vendor-darwin-arm64-${VERSION}.tar.gz" \
    "$COMMON_SKILL_ROOT/dist/cua-router-basic-slim-${VERSION}.tar.gz.sha256" \
    "$COMMON_SKILL_ROOT/dist/cua-router-basic-vendor-darwin-arm64-${VERSION}.tar.gz.sha256" \
    "$COMMON_SKILL_ROOT/dist/SHA256SUMS" \
    "$COMMON_SKILL_ROOT/dist/release-manifest.json"
  do
    [ -f "$f" ] || die "missing release asset: $f"
    RELEASE_ASSETS+=("$f")
  done
}

upload_release() {
  collect_release_assets
  if gh release view "$TAG" --repo "$repo" >/dev/null 2>&1; then
    warn "release $TAG exists — uploading assets only"
    gh release upload "$TAG" --repo "$repo" --clobber "${RELEASE_ASSETS[@]}"
  else
    if [ -n "$NOTES_FILE" ]; then
      gh release create "$TAG" --repo "$repo" --title "v${VERSION}" \
        --notes-file "$NOTES_FILE" "${RELEASE_ASSETS[@]}"
    else
      gh release create "$TAG" --repo "$repo" --title "v${VERSION}" \
        --generate-notes "${RELEASE_ASSETS[@]}"
    fi
  fi
}

upload_release

info "release published: https://github.com/${repo}/releases/tag/${TAG}"
info "push to remote:"
info "  git push origin main && git push origin ${TAG}"
