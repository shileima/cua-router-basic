# 安装与依赖

## SKILL_ROOT 解析

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/claude-code-agents/cua-agent/skills/cua-router-basic}"
[ -f "$SKILL_ROOT/SKILL.md" ] || SKILL_ROOT="${HOME}/.automan/skills/cua-router-basic"
[ -f "$SKILL_ROOT/SKILL.md" ] || SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"
```

## 首次安装

### automan 宿主（内网，推荐）

automan 宿主机默认走**公司内网 S3plus**，无需 GitHub 访问：

```bash
curl -fsSL https://s3plus.sankuai.com/aiagent-bucket/cua-resources/install-intranet.sh | bash
```

- 自动拉内网 `.meta.json` 指向的最新版本；锁定版本用 `CUA_ROUTER_VERSION=<ver>`。
- 安装后会在技能目录写入 `.cua-intranet` 标记，之后 `daemon.sh` 自举 vendor、`update-intranet.sh` 更新都自动走内网，不回落 GitHub。
- 覆盖资源基址用 `CUA_ROUTER_INTRANET_BASE`。

### 外网 / 开源环境（GitHub）

```bash
curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
```

技能目录已存在但缺 vendor：

```bash
# 内网安装过（存在 .cua-intranet）→ daemon.sh start 会自动走内网自举
bash "$SKILL_ROOT/scripts/install-full.sh" --vendor-mode auto
```

## 更新

### automan 宿主（内网）

```bash
# 检查是否有新版本（machine-readable 输出）
curl -fsSL https://s3plus.sankuai.com/aiagent-bucket/cua-resources/update-intranet.sh | bash -s -- --check
# 有更新则应用
curl -fsSL https://s3plus.sankuai.com/aiagent-bucket/cua-resources/update-intranet.sh | bash
# 或本地已安装
bash "$SKILL_ROOT/scripts/update-intranet.sh"
```

### 外网（GitHub）

```bash
bash "$SKILL_ROOT/scripts/update-remote.sh"
```

## 安装后验证

```bash
bash "$SKILL_ROOT/scripts/daemon.sh" start
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
```

输出 `ok` 表示技能与 cua-router 均已就绪。

## 依赖说明

- 技能包内已自带运行时依赖，不依赖 `~/.codex` 或 `/Applications/ChatGPT.app`。
- vendor 会在 `install-remote.sh` / `install-intranet.sh`、`install-full.sh`、`daemon.sh start` 时自动 bootstrap。
- vendor 来源：优先 ChatGPT.app 提取；否则下载——内网安装（存在 `.cua-intranet` 标记）从 S3plus 下载，其余从 GitHub Release 下载。

## 关键文件

| 文件路径 | 用途 |
|---|---|
| `scripts/cua-router.py` | cua-router 主程序 |
| `scripts/daemon.sh` | 守护进程管理 |
| `scripts/exec.sh` | `/exec` 封装 |
| `scripts/computer-use-client.mjs` | sky runtime 入口 |
| `vendor/codex/bin/codex` | 内置 app-server |
| `vendor/cua_node/` | 内置 node + node_repl + `@oai/sky` |
| `runtime/config.toml` | 启动时生成的配置 |

## 系统依赖

- macOS + Chrome（bundle id: `com.google.Chrome`）
- Python 3
