#!/usr/bin/env bash
# Apply local-only Computer Use branding after copying the vendor app.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/vendor/computer-use/Codex Computer Use.app}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
ICON_SOURCE="$ROOT/assets/computer-use-desktop.icns"
ICON_TARGET="$RESOURCES_DIR/CUAAppIcon.icns"
ICON_BACKUP="$RESOURCES_DIR/CUAAppIcon.original.icns"
DISPLAY_NAME="${CUA_COMPUTER_USE_DISPLAY_NAME:-Computer Use}"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -d "$APP_PATH" ] || die "未找到 Computer Use app：$APP_PATH"
[ -f "$INFO_PLIST" ] || die "未找到 Info.plist：$INFO_PLIST"
[ -f "$ICON_SOURCE" ] || die "未找到桌面操作图标：$ICON_SOURCE"
[ -d "$RESOURCES_DIR" ] || die "未找到 Resources 目录：$RESOURCES_DIR"

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$INFO_PLIST"

if [ ! -f "$ICON_BACKUP" ]; then
  cp "$ICON_TARGET" "$ICON_BACKUP"
fi

cp "$ICON_SOURCE" "$ICON_TARGET"

# The outer bundle was modified, so reseal it for local execution. The nested
# SkyComputerUseClient app is left untouched to keep its identity stable.
codesign --force --sign - --preserve-metadata=entitlements "$APP_PATH"

echo "patched Computer Use branding: $APP_PATH"
