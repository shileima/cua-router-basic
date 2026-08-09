#!/usr/bin/env bash
# Deprecated no-op: do not mutate Codex Computer Use.app.
#
# This app is notarized by OpenAI. Editing Info.plist/resources and ad-hoc
# re-signing it makes Gatekeeper reject the bundle on first launch, which
# prevents CUAService from creating its native pipe socket.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/vendor/computer-use/Codex Computer Use.app}"

if [ ! -d "$APP_PATH" ]; then
  echo "error: 未找到 Computer Use app：$APP_PATH" >&2
  exit 1
fi

echo "skip Computer Use branding patch to preserve notarized signature: $APP_PATH"
