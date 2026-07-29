#!/usr/bin/env bash
# Shared helpers for cua-router-basic install / release scripts.

common_init() {
  COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  COMMON_SCRIPT_DIR="$(cd "$COMMON_LIB_DIR/.." && pwd)"
  COMMON_SKILL_ROOT="$(cd "$COMMON_SCRIPT_DIR/.." && pwd)"
}

die() {
  echo "[cua-router-basic] error: $*" >&2
  exit 1
}

info() {
  echo "[cua-router-basic] $*"
}

warn() {
  echo "[cua-router-basic] warning: $*" >&2
}

github_repo() {
  echo "${CUA_ROUTER_GITHUB_REPO:-shileima/cua-router-basic}"
}

read_version() {
  local skill_root="${1:-$COMMON_SKILL_ROOT}"
  local meta="$skill_root/.meta.json"
  [ -f "$meta" ] || die "missing .meta.json in $skill_root"
  python3 - "$meta" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os-$arch" in
    darwin-arm64) echo "darwin-arm64" ;;
    darwin-x86_64) echo "darwin-x86_64" ;;
    linux-x86_64) echo "linux-x86_64" ;;
    linux-aarch64) echo "linux-arm64" ;;
    *) die "unsupported platform: $os-$arch (cua-router-basic currently targets darwin-arm64)" ;;
  esac
}

vendor_ready() {
  local skill_root="${1:-$COMMON_SKILL_ROOT}"
  [ -x "$skill_root/vendor/codex/bin/codex" ] \
    && [ -x "$skill_root/vendor/cua_node/bin/node_repl" ] \
    && [ -d "$skill_root/vendor/cua_node/lib/node_modules/@oai/sky" ] \
    && [ -d "$skill_root/vendor/computer-use/Codex Computer Use.app" ]
}

chatgpt_vendor_available() {
  local chatgpt="${CHATGPT_RESOURCES:-/Applications/ChatGPT.app/Contents/Resources}"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  [ -x "$chatgpt/codex" ] \
    && [ -d "$chatgpt/cua_node" ] \
    && [ -d "$codex_home/computer-use/Codex Computer Use.app" ]
}

default_release_base() {
  local version="$1"
  if [ -n "${CUA_ROUTER_RELEASE_BASE:-}" ]; then
    printf '%s' "${CUA_ROUTER_RELEASE_BASE%/}"
    return 0
  fi
  printf 'https://github.com/%s/releases/download/v%s' "$(github_repo)" "$version"
}

default_vendor_url() {
  local version="$1"
  local platform="$2"
  printf '%s/cua-router-basic-vendor-%s-%s.tar.gz' \
    "$(default_release_base "$version")" "$platform" "$version"
}

vendor_archive_name() {
  local version="$1"
  local platform="$2"
  printf 'cua-router-basic-vendor-%s-%s.tar.gz' "$platform" "$version"
}

slim_archive_name() {
  local version="$1"
  printf 'cua-router-basic-slim-%s.tar.gz' "$version"
}

ensure_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}
