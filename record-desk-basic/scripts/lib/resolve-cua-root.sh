#!/usr/bin/env bash
# 解析 cua-router-basic 技能根目录，并复用其内置的 SkyComputerUseClient 二进制。
# record-desk-basic 不重复 vendor：录制能力与 Computer Use 共用同一个二进制。

rdb_die() {
  echo "[record-desk-basic] error: $*" >&2
  exit 1
}

rdb_info() {
  echo "[record-desk-basic] $*"
}

# 依次尝试定位 cua-router-basic 的 SKILL_ROOT：
#   1. 环境变量 CUA_ROUTER_INSTALL_DIR（显式指定）
#   2. ~/.automan/skills/cua-router-basic（automan 安装）
#   3. ~/.cursor/skills/cua-router-basic（Cursor 安装）
#   4. record-desk-basic 的父目录（开发态：与 cua-router-basic 同仓库/同级）
# 命中条件：该目录存在 vendor/computer-use/.../SkyComputerUseClient。
resolve_cua_root() {
  local rdb_root="$1"
  local sky_rel="vendor/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
  local candidate

  local -a candidates=()
  [ -n "${CUA_ROUTER_INSTALL_DIR:-}" ] && candidates+=("$CUA_ROUTER_INSTALL_DIR")
  candidates+=("$HOME/.automan/skills/cua-router-basic")
  candidates+=("$HOME/.cursor/skills/cua-router-basic")
  # 开发态：record-desk-basic 作为 cua-router-basic 仓库的子目录时，父目录即根。
  candidates+=("$(cd "$rdb_root/.." && pwd)")

  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/$sky_rel" ]; then
      printf '%s' "$(cd "$candidate" && pwd)"
      return 0
    fi
  done

  rdb_die "找不到 cua-router-basic 的 SkyComputerUseClient 二进制。请先安装 cua-router-basic 并完成 vendor，或设置 CUA_ROUTER_INSTALL_DIR。"
}

sky_client_bin() {
  local cua_root="$1"
  printf '%s' "$cua_root/vendor/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
}

# 注：后台 CUAService 的预热与 event-stream 的托管，统一由 cua-router-basic 的
# `scripts/daemon.sh start`（codex app-server）负责，本技能不再单独 open 服务。
