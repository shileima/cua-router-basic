#!/usr/bin/env bash
# Bump .meta.json version (semver x.y.z).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
common_init

NEW_VERSION="${1:-}"
[ -n "$NEW_VERSION" ] || die "usage: $0 <version>  (e.g. 0.4.0)"

python3 - "$COMMON_SKILL_ROOT/.meta.json" "$NEW_VERSION" <<'PY'
import json, re, sys

path, version = sys.argv[1], sys.argv[2]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit(f"invalid semver: {version}")

data = json.load(open(path, encoding="utf-8"))
data["version"] = version
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(version)
PY

info "version -> $NEW_VERSION"
