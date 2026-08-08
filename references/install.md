# 安装与依赖

## SKILL_ROOT 解析

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/claude-code-agents/cua-agent/skills/cua-router-basic}"
[ -f "$SKILL_ROOT/SKILL.md" ] || SKILL_ROOT="${HOME}/.automan/skills/cua-router-basic"
[ -f "$SKILL_ROOT/SKILL.md" ] || SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"
```

## 首次安装

远程一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
```

技能目录已存在但缺 vendor：

```bash
bash "$SKILL_ROOT/scripts/install-full.sh" --vendor-mode auto
```

## 安装后验证

```bash
bash "$SKILL_ROOT/scripts/daemon.sh" start
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
```

输出 `ok` 表示技能与 cua-router 均已就绪。

## 依赖说明

- 技能包内已自带运行时依赖，不依赖 `~/.codex` 或 `/Applications/ChatGPT.app`。
- vendor 会在 `install-remote.sh`、`install-full.sh`、`daemon.sh start` 时自动 bootstrap。
- vendor 来源：优先 ChatGPT.app 提取，否则从 GitHub Release 下载。

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
