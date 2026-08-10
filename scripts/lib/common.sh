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

# ---------------------------------------------------------------------------
# Intranet (Sankuai S3plus) distribution helpers
#
# Public read URL layout (forcePathStyle):
#   https://s3plus.sankuai.com/<bucket>/cua-resources/
#     ├── install-intranet.sh                    # stable bootstrap entry
#     ├── lib/common.sh                           # stable shared helpers
#     ├── .meta.json                              # latest version pointer
#     └── versions/<version>/
#         ├── cua-router-basic-slim-<version>.tar.gz(.sha256)
#         ├── cua-router-basic-vendor-darwin-arm64-<version>.tar.gz(.sha256)
#         ├── SHA256SUMS
#         ├── release-manifest.json
#         ├── install-intranet.sh
#         └── lib/common.sh
#
# The upload/publish side lives in scripts/intranet/ (git-ignored, touches the
# intranet credential proxy). The download/install side (install-intranet.sh)
# only needs these public read URLs and is safe to commit.
# ---------------------------------------------------------------------------

# Base public URL for cua-router-basic intranet resources (no trailing slash).
intranet_base() {
  local base="${CUA_ROUTER_INTRANET_BASE:-https://s3plus.sankuai.com/aiagent-bucket/cua-resources}"
  printf '%s' "${base%/}"
}

# Per-version directory URL under the intranet base.
intranet_version_base() {
  local version="$1"
  printf '%s/versions/%s' "$(intranet_base)" "$version"
}

# URL of the shared common.sh used to bootstrap a curl | bash intranet install.
intranet_common_url() {
  printf '%s/lib/common.sh' "$(intranet_base)"
}

# Slim / vendor tarball URLs served from a version directory on the intranet.
intranet_slim_url() {
  local version="$1"
  printf '%s/%s' "$(intranet_version_base "$version")" "$(slim_archive_name "$version")"
}

intranet_vendor_url() {
  local version="$1"
  local platform="$2"
  printf '%s/%s' "$(intranet_version_base "$version")" "$(vendor_archive_name "$version" "$platform")"
}

# Resolve the latest published version from the intranet .meta.json pointer.
fetch_intranet_version() {
  local meta_url
  meta_url="$(intranet_base)/.meta.json"
  curl -fsSL "$meta_url" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'
}

automan_root_dir() {
  printf '%s' "${CUA_ROUTER_AUTOMAN_ROOT:-$HOME/.automan}"
}

automan_agents_root_dir() {
  printf '%s/claude-code-agents' "$(automan_root_dir)"
}

automan_target_profile() {
  printf '%s' "${CUA_ROUTER_AUTOMAN_PROFILE:-cua-agent}"
}

automan_profile_dir() {
  if [ -n "${CUA_ROUTER_AUTOMAN_PROFILE_DIR:-}" ]; then
    printf '%s' "$CUA_ROUTER_AUTOMAN_PROFILE_DIR"
    return 0
  fi
  printf '%s/%s' "$(automan_agents_root_dir)" "$(automan_target_profile)"
}

automan_profile_skills_dir() {
  printf '%s/skills' "$(automan_profile_dir)"
}

automan_skill_dir() {
  printf '%s/cua-router-basic' "$(automan_profile_skills_dir)"
}

record_desk_automan_skill_dir() {
  printf '%s/record-desk-basic' "$(automan_profile_skills_dir)"
}

legacy_automan_skills_dir() {
  printf '%s' "${CUA_ROUTER_LEGACY_AUTOMAN_SKILLS_DIR:-$(automan_root_dir)/skills}"
}

# The target automan profile must exist before we consider automan integration.
# We only require the profile *directory*; skills/ subdir will be created on demand.
automan_available() {
  [ -d "$(automan_profile_dir)" ]
}

# Back-compat alias: older callers may still ask "is automan available?".
automan_skills_available() {
  automan_available
}

default_install_dir() {
  if [ -n "${CUA_ROUTER_INSTALL_DIR:-}" ]; then
    printf '%s' "$CUA_ROUTER_INSTALL_DIR"
    return 0
  fi
  if automan_available; then
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

record_desk_source_dir() {
  local skill_root="$1"
  local source="$skill_root/record-desk-basic"
  [ -f "$source/SKILL.md" ] || return 1
  printf '%s' "$source"
}

# Install (rsync) skill source into target, preserving existing vendor/ when
# already ready (avoid nuking 700+ MB on version bumps).
_install_skill_to_target() {
  local source="$1"
  local target="$2"
  local label="$3"
  local resolved_source resolved_target
  resolved_source="$(cd "$source" && pwd)"
  resolved_target="$(cd "$target" 2>/dev/null && pwd || true)"

  if [ "$resolved_source" = "$resolved_target" ]; then
    info "$label already at target: $target"
    return 0
  fi

  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ] && [ ! -d "$target" ]; then
    warn "backing up existing $target"
    mv "$target" "${target}.bak.$(date +%s)"
  fi

  ensure_install_parent "$target"
  local -a rsync_args=(-a --exclude '.DS_Store')
  if vendor_ready "$target"; then
    info "installing $label -> $target (preserving existing vendor/)"
    rsync_args+=(--exclude 'vendor/**')
  else
    info "installing $label -> $target"
    rsync_args+=(--delete)
  fi
  rsync "${rsync_args[@]}" "$resolved_source/" "$target/"
}

sync_record_desk_basic_install() {
  local skill_root="$1"
  local source target

  automan_available || return 0
  if ! source="$(record_desk_source_dir "$skill_root")"; then
    warn "record-desk-basic not bundled under $skill_root; skipping companion skill install"
    return 0
  fi

  target="$(record_desk_automan_skill_dir)"
  _install_skill_to_target "$source" "$target" "companion skill record-desk-basic"
}

# Remove pre-0.5 install layout so agents don't resolve two copies of the skill.
# We only touch names we own: cua-router-basic and record-desk-basic. Any other
# skill in ~/.automan/skills or in other profiles is left untouched.
cleanup_legacy_automan_layout() {
  local legacy_skills entry name legacy_agents_root profile skill_link target
  legacy_skills="$(legacy_automan_skills_dir)"
  target="$(automan_profile_dir)"

  for name in cua-router-basic record-desk-basic; do
    entry="$legacy_skills/$name"
    if [ -L "$entry" ]; then
      info "cleanup: removing legacy symlink $entry"
      rm "$entry"
    elif [ -d "$entry" ]; then
      info "cleanup: removing legacy install dir $entry"
      rm -rf "$entry"
    fi
  done

  legacy_agents_root="$(automan_agents_root_dir)"
  [ -d "$legacy_agents_root" ] || return 0
  for profile in "$legacy_agents_root"/*; do
    [ -d "$profile" ] || continue
    [ "$profile" = "$target" ] && continue
    for name in cua-router-basic record-desk-basic; do
      skill_link="$profile/skills/$name"
      [ -e "$skill_link" ] || [ -L "$skill_link" ] || continue
      if [ -L "$skill_link" ]; then
        info "cleanup: removing legacy profile symlink $skill_link"
        rm "$skill_link"
      else
        warn "cleanup: legacy real dir at $skill_link — backing up (not deleting)"
        mv "$skill_link" "${skill_link}.bak.$(date +%s)"
      fi
    done
  done
}

# Register skill in automan ecosystem: install into the target profile's
# skills/ directory (no cross-profile symlinks), then clean up legacy layout.
sync_automan_install() {
  local skill_root="$1"
  local target

  automan_available || return 0

  target="$(automan_skill_dir)"
  _install_skill_to_target "$skill_root" "$target" "cua-router-basic"

  local resolved_skill
  resolved_skill="$(cd "$skill_root" && pwd)"
  sync_record_desk_basic_install "$resolved_skill"

  cleanup_legacy_automan_layout
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
