#!/usr/bin/env bash
# 安装 cua-router-basic 到 Cursor 个人技能目录，并置顶 / 菜单排序。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

SKILL_ROOT="${SKILL_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILL_NAME="cua-router-basic"
CURSOR_SKILLS_DIR="${CURSOR_SKILLS_DIR:-$HOME/.cursor/skills}"
TARGET_LINK="$CURSOR_SKILLS_DIR/$SKILL_NAME"
STATE_DB="${CURSOR_STATE_DB:-$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb}"
PINNED_KEY="cursor/glass.pinnedItems.v1"
RECENT_KEY="cursor.skills.recentlyUsed"
SLASH_SKILL_ID="skill-${SKILL_NAME}"

usage() {
  cat <<EOF
Usage: $0 [--unpin]

Install cua-router-basic into ~/.cursor/skills and pin it for / menu priority.

Options:
  --unpin   Remove pin entry only (keep symlink)
  -h        Show help
EOF
}

ensure_sqlite3() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[install-cursor] sqlite3 is required to pin the skill" >&2
    exit 1
  fi
}

install_symlink() {
  CURSOR_SKILLS_DIR="$(expand_home_path "$CURSOR_SKILLS_DIR")"
  TARGET_LINK="$CURSOR_SKILLS_DIR/$SKILL_NAME"
  ensure_install_parent "$TARGET_LINK"
  mkdir -p "$CURSOR_SKILLS_DIR"
  local skill_root resolved_link
  skill_root="$(cd "$SKILL_ROOT" && pwd)"
  if [ -e "$TARGET_LINK" ] && [ ! -L "$TARGET_LINK" ]; then
    resolved_link="$(cd "$TARGET_LINK" && pwd)"
    if [ "$resolved_link" = "$skill_root" ]; then
      echo "[install-cursor] SKILL_ROOT is already the Cursor skills path: $skill_root"
      return 0
    fi
  fi
  if [ -L "$TARGET_LINK" ]; then
    current="$(readlink "$TARGET_LINK")"
    if [ "$current" = "$SKILL_ROOT" ]; then
      echo "[install-cursor] symlink already points to $SKILL_ROOT"
      return 0
    fi
    rm "$TARGET_LINK"
  elif [ -e "$TARGET_LINK" ]; then
    echo "[install-cursor] backing up existing $TARGET_LINK"
    mv "$TARGET_LINK" "${TARGET_LINK}.bak.$(date +%s)"
  fi
  ln -s "$SKILL_ROOT" "$TARGET_LINK"
  echo "[install-cursor] linked $TARGET_LINK -> $SKILL_ROOT"
}

pin_skill() {
  ensure_sqlite3
  if [ ! -f "$STATE_DB" ]; then
    echo "[install-cursor] Cursor state db not found: $STATE_DB" >&2
    echo "[install-cursor] Open Cursor once, then rerun this script." >&2
    exit 1
  fi

  python3 - "$STATE_DB" "$PINNED_KEY" "$RECENT_KEY" "$SLASH_SKILL_ID" "$SKILL_NAME" <<'PY'
import json
import sqlite3
import sys

db_path, pinned_key, recent_key, slash_id, skill_name = sys.argv[1:6]
recent_entry = f"{skill_name}/SKILL.md"
pin_entry = {"kind": "skill", "id": slash_id}

conn = sqlite3.connect(db_path)
cur = conn.cursor()

def get_json(key, default):
    cur.execute("SELECT value FROM ItemTable WHERE key = ?", (key,))
    row = cur.fetchone()
    if not row:
        return default
    try:
        return json.loads(row[0])
    except json.JSONDecodeError:
        return default

# Pin: put cua-router-basic first, keep other pins after it.
existing_pins = get_json(pinned_key, [])
if not isinstance(existing_pins, list):
    existing_pins = []

def pin_id(item):
    if isinstance(item, dict):
        return item.get("id")
    return None

filtered = [
    item for item in existing_pins
    if not (isinstance(item, dict) and item.get("kind") == "skill" and pin_id(item) in {slash_id, skill_name})
]
new_pins = [pin_entry, *filtered]
cur.execute(
    "INSERT INTO ItemTable(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    (pinned_key, json.dumps(new_pins, ensure_ascii=False)),
)

# Recently used: boost MRU ranking in slash menu.
existing_recent = get_json(recent_key, [])
if not isinstance(existing_recent, list):
    existing_recent = []
recent_filtered = [x for x in existing_recent if x != recent_entry]
new_recent = [recent_entry, *recent_filtered][:20]
cur.execute(
    "INSERT INTO ItemTable(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    (recent_key, json.dumps(new_recent, ensure_ascii=False)),
)

conn.commit()
conn.close()
print(json.dumps({"pinned": new_pins[:5], "recentlyUsed": new_recent[:5]}, ensure_ascii=False))
PY
}

unpin_skill() {
  ensure_sqlite3
  [ -f "$STATE_DB" ] || return 0
  python3 - "$STATE_DB" "$PINNED_KEY" "$SLASH_SKILL_ID" "$SKILL_NAME" <<'PY'
import json
import sqlite3
import sys

db_path, pinned_key, slash_id, skill_name = sys.argv[1:5]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT value FROM ItemTable WHERE key = ?", (pinned_key,))
row = cur.fetchone()
if not row:
    conn.close()
    raise SystemExit(0)
try:
    pins = json.loads(row[0])
except json.JSONDecodeError:
    conn.close()
    raise SystemExit(0)
if not isinstance(pins, list):
    conn.close()
    raise SystemExit(0)
new_pins = [
    item for item in pins
    if not (isinstance(item, dict) and item.get("kind") == "skill" and item.get("id") in {slash_id, skill_name})
]
cur.execute(
    "INSERT INTO ItemTable(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    (pinned_key, json.dumps(new_pins, ensure_ascii=False)),
)
conn.commit()
conn.close()
print("[install-cursor] unpinned")
PY
}

main() {
  local action=install
  while [ $# -gt 0 ]; do
    case "$1" in
      --unpin) action=unpin; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  if [ "$action" = "unpin" ]; then
    unpin_skill
    exit 0
  fi

  install_symlink
  echo "[install-cursor] pinning slash skill id: $SLASH_SKILL_ID"
  pin_skill
  echo "[install-cursor] done. Reload Cursor window (Cmd+Shift+P -> Developer: Reload Window) if / menu does not update immediately."
}

main "$@"
