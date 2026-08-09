#!/usr/bin/env bash
# 从 ChatGPT.app 与本机 computer-use 安装包提取 vendor 依赖，使技能可独立运行。
set -eu

SKILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$SKILL_ROOT/vendor"
CHATGPT_RESOURCES="${CHATGPT_RESOURCES:-/Applications/ChatGPT.app/Contents/Resources}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
COMPUTER_USE_SRC="$CODEX_HOME/computer-use/Codex Computer Use.app"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "$*"; }

[ -x "$CHATGPT_RESOURCES/codex" ] || die "未找到 ChatGPT codex：$CHATGPT_RESOURCES/codex"
[ -d "$CHATGPT_RESOURCES/cua_node" ] || die "未找到 cua_node：$CHATGPT_RESOURCES/cua_node"
[ -d "$COMPUTER_USE_SRC" ] || die "未找到 Computer Use 客户端：$COMPUTER_USE_SRC（需先在 ChatGPT/Codex 中安装 Computer Use 插件一次）"

info "[setup-vendor] SKILL_ROOT=$SKILL_ROOT"

mkdir -p "$VENDOR/codex/bin" "$VENDOR/computer-use"

info "[setup-vendor] copying codex binary..."
cp "$CHATGPT_RESOURCES/codex" "$VENDOR/codex/bin/codex"
chmod +x "$VENDOR/codex/bin/codex"

info "[setup-vendor] copying cua_node (node + node_repl + @oai/sky)..."
rm -rf "$VENDOR/cua_node"
cp -R "$CHATGPT_RESOURCES/cua_node" "$VENDOR/cua_node"

info "[setup-vendor] copying Codex Computer Use.app..."
rm -rf "$VENDOR/computer-use/Codex Computer Use.app"
cp -R "$COMPUTER_USE_SRC" "$VENDOR/computer-use/Codex Computer Use.app"
bash "$SKILL_ROOT/scripts/patch-computer-use-branding.sh" "$VENDOR/computer-use/Codex Computer Use.app"

SKY_CLIENT="$VENDOR/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
[ -x "$SKY_CLIENT" ] || die "SkyComputerUseClient 不可执行：$SKY_CLIENT"

SKY_SHA="$(shasum -a 256 "$SKY_CLIENT" | awk '{print $1}')"
CODEX_VERSION="$("$VENDOR/codex/bin/codex" --version 2>/dev/null || echo unknown)"

cat > "$VENDOR/manifest.json" <<EOF
{
  "extracted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_chatgpt_resources": "$CHATGPT_RESOURCES",
  "source_computer_use": "$COMPUTER_USE_SRC",
  "codex_version": "$CODEX_VERSION",
  "sky_client_sha256": "$SKY_SHA"
}
EOF

info "[setup-vendor] done."
info "  codex:         $VENDOR/codex/bin/codex"
info "  cua_node:      $VENDOR/cua_node"
info "  computer-use:  $VENDOR/computer-use/Codex Computer Use.app"
info "  sky sha256:    $SKY_SHA"
