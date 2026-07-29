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

# Expand leading ~ to $HOME (bash does not expand ~ in all assignment contexts).
expand_home_path() {
  local path="$1"
  case "$path" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${path#~/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

# Ensure parent directories exist; remove broken symlinks blocking mkdir -p.
ensure_install_parent() {
  local target parent
  target="$(expand_home_path "$1")"
  parent="$(dirname "$target")"

  if [ -z "$parent" ] || [ "$parent" = "." ] || [ "$parent" = "$target" ]; then
    return 0
  fi

  if [ -e "$parent" ] && [ ! -d "$parent" ]; then
    die "cannot create install dir; path exists but is not a directory: $parent"
  fi

  if [ -L "$parent" ] && [ ! -e "$parent" ]; then
    warn "removing broken symlink: $parent"
    rm "$parent"
  fi

  mkdir -p "$parent"
}

# Create install directory (and all parents). Prints the normalized absolute path.
ensure_install_dir() {
  local target
  target="$(expand_home_path "$1")"

  if [ -L "$target" ] && [ ! -e "$target" ]; then
    warn "removing broken install symlink: $target"
    rm "$target"
  fi

  ensure_install_parent "$target"
  mkdir -p "$target"
  cd "$target" && pwd
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

default_slim_url() {
  local version="$1"
  printf '%s/%s' "$(default_release_base "$version")" "$(slim_archive_name "$version")"
}

default_git_url() {
  printf 'https://github.com/%s.git' "$(github_repo)"
}

automan_skills_dir() {
  printf '%s' "${CUA_ROUTER_AUTOMAN_SKILLS_DIR:-$HOME/.automan/skills}"
}

automan_skill_dir() {
  printf '%s/cua-router-basic' "$(automan_skills_dir)"
}

claude_code_agents_main_skills_dir() {
  printf '%s' "${CUA_ROUTER_CLAUDE_CODE_AGENTS_SKILLS_DIR:-$HOME/.automan/claude-code-agents/main/skills}"
}

automan_skills_available() {
  [ -d "$(automan_skills_dir)" ]
}

default_install_dir() {
  if [ -n "${CUA_ROUTER_INSTALL_DIR:-}" ]; then
    printf '%s' "$CUA_ROUTER_INSTALL_DIR"
    return 0
  fi
  if automan_skills_available; then
    automan_skill_dir
    return 0
  fi
  printf '%s' "$HOME/.cursor/skills/cua-router-basic"
}

# Create or refresh a symlink at link_dir/link_name -> skill_root (absolute target).
install_symlink_to_skill() {
  local skill_root="$1"
  local link_dir="$2"
  local link_name="${3:-cua-router-basic}"
  local link_path="$link_dir/$link_name"
  local current resolved_current

  skill_root="$(cd "$skill_root" && pwd)"
  link_dir="$(expand_home_path "$link_dir")"
  link_path="$link_dir/$link_name"
  ensure_install_parent "$link_path"

  if [ -e "$link_path" ] && [ ! -L "$link_path" ] && [ "$(cd "$link_path" && pwd)" = "$skill_root" ]; then
    info "skill already at link path: $link_path"
    return 0
  fi

  if [ -L "$link_path" ]; then
    current="$(readlink "$link_path")"
    if [ "$current" = "$skill_root" ]; then
      info "symlink already correct: $link_path -> $skill_root"
      return 0
    fi
    resolved_current="$(cd "$(dirname "$link_path")" && cd "$current" 2>/dev/null && pwd || true)"
    if [ "$resolved_current" = "$skill_root" ]; then
      info "symlink already correct: $link_path -> $current"
      return 0
    fi
    rm "$link_path"
  elif [ -e "$link_path" ]; then
    warn "backing up existing $link_path"
    mv "$link_path" "${link_path}.bak.$(date +%s)"
  fi

  ln -s "$skill_root" "$link_path"
  info "linked $link_path -> $skill_root"
}

# When ~/.automan/skills exists, register Claude Code agents skill symlink.
sync_automan_claude_code_symlink() {
  local skill_root="${1:-$(automan_skill_dir)}"
  local agents_dir link_path automan_skills resolved_skill

  automan_skills_available || return 0

  agents_dir="$(claude_code_agents_main_skills_dir)"
  if [ ! -d "$(dirname "$agents_dir")" ]; then
    info "claude-code-agents main dir not found; skipping agents skill symlink"
    return 0
  fi

  resolved_skill="$(cd "$skill_root" && pwd)"
  automan_skills="$(cd "$(automan_skills_dir)" && pwd)"
  link_path="$agents_dir/cua-router-basic"
  ensure_install_parent "$link_path"

  if [[ "$resolved_skill" == "$automan_skills/"* ]]; then
    if [ -L "$link_path" ] && [ "$(readlink "$link_path")" = "../../../skills/cua-router-basic" ]; then
      info "claude-code-agents symlink already correct: $link_path"
      return 0
    fi
    if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
      warn "backing up existing $link_path"
      mv "$link_path" "${link_path}.bak.$(date +%s)"
    elif [ -L "$link_path" ]; then
      rm "$link_path"
    fi
    ln -s "../../../skills/cua-router-basic" "$link_path"
    info "linked $link_path -> ../../../skills/cua-router-basic"
    return 0
  fi

  install_symlink_to_skill "$resolved_skill" "$agents_dir" "cua-router-basic"
}

# Register skill in automan ecosystem: Claude Code agents symlink (+ optional copy).
sync_automan_install() {
  local skill_root="$1"
  local automan_target resolved_skill resolved_automan

  automan_skills_available || return 0

  automan_target="$(automan_skill_dir)"
  resolved_skill="$(cd "$skill_root" && pwd)"
  resolved_automan="$(cd "$automan_target" 2>/dev/null && pwd || true)"

  if [ "$resolved_skill" != "$resolved_automan" ]; then
    if vendor_ready "$automan_target"; then
      info "automan skill already present at $automan_target"
    else
      info "also installing skill copy to $automan_target"
      ensure_install_parent "$automan_target"
      rsync -a --delete \
        --exclude '.DS_Store' \
        "$resolved_skill/" "$automan_target/"
    fi
    sync_automan_claude_code_symlink "$automan_target"
    return 0
  fi

  sync_automan_claude_code_symlink "$resolved_skill"
}

fetch_remote_version() {
  local repo meta_url
  repo="$(github_repo)"
  meta_url="https://raw.githubusercontent.com/${repo}/main/.meta.json"
  curl -fsSL "$meta_url" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'
}

ensure_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

verify_sha256_sidecar() {
  local file="$1"
  local sidecar="$2"
  local expected actual
  expected="$(awk '{print $1; exit}' "$sidecar")"
  [ -n "$expected" ] || die "empty checksum sidecar: $sidecar"
  ensure_command shasum
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    die "checksum mismatch for $(basename "$file") (expected $expected, got $actual)"
  fi
}
