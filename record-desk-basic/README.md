# record-desk-basic

macOS 桌面「录制 → 回放 → 转技能」独立技能。把 ChatGPT app 里 **Record & Replay** 插件的全部能力内置进来，**复用** `cua-router-basic` 已 vendor 的 `SkyComputerUseClient` 二进制（不重复打包）。

## 它做什么

- `event_stream_start / status / stop`：录制用户在 Mac 上的一次演示（鼠标、键盘、窗口 AX 内容，最长 30 分钟）。优先以宿主托管 MCP 工具方式运行，对齐 Codex 官方 Record & Replay；不可用时可走 shell fallback。
- 录制产物 `events.jsonl` / `session.json` 落盘（默认隔离在 `runtime/`）。
- 读盘解读后，按 `cua-router-basic` 规范生成「用 Computer Use 高效回放」的可复用技能。

## 与 cua-router-basic 的关系

| 关注点 | 技能 |
|---|---|
| 录制捕获 / 录制生命周期 / 录制转技能 | **record-desk-basic**（本技能） |
| Computer Use 执行 / AX 缓存 / sky·ax 运行时 | **cua-router-basic**（回放技能依赖它执行） |

两者共用同一份 vendor 二进制和同一个由 `launchd` 托管的 codex app-server。录制必须复用该 app-server 的事件观察者上下文，因此服务链并非彼此隔离；`record-desk-basic` 只负责录制生命周期和产物消费。

## 快速开始

```bash
# 0) 依赖校验（定位 cua-router-basic + 拉起 cua-router 守护进程）
bash scripts/setup.sh

# 1) 手动 fallback：开始录制（秒回，返回 eventsPath；屏幕出现录制指示器）
bash scripts/event-stream.sh start
#    —— 结束本轮，等用户把演示做完 ——

# 2) 用户回来后
bash scripts/event-stream.sh status
bash scripts/event-stream.sh stop     # 返回 metadataPath / eventsPath
```

> 默认优先使用插件宿主托管的 `record-desk-event-stream` MCP server；`event-stream.sh mcp` 负责以 stdio MCP server 形态暴露官方 `event_stream_*` 工具。`event-stream.sh start/status/stop` 是手动 fallback，会经 cua-router-basic 的 codex app-server 托管驱动 `/record`。

## 目录

```
record-desk-basic/
├── SKILL.md                     # 技能入口：录制工作流 + 转技能规范 + 触发词
├── README.md
├── .meta.json / .mcp.json / .codex-plugin / .cursor-plugin / .claude-plugin
├── references/
│   ├── recording-architecture.md # 根因沉淀：录制为何必须由 codex app-server 托管（含证据/解法）
│   ├── event-stream.md          # 录制产物解读（events.jsonl / AX diff 语法 / 敏感信息）
│   └── replay-skill-template.md # 生成「依赖 cua-router-basic」的可回放技能模板
└── scripts/
    ├── event-stream.sh          # start/status/stop 入口（转调 cua-router /record）
    ├── setup.sh                 # 依赖校验 + 拉起 cua-router 守护进程
    └── lib/resolve-cua-root.sh  # 定位 cua-router-basic
```

## 权限与已知边界

本技能与 `cua-router-basic` 一样**完全自包含**：runtime app 与 client 二进制都取自 cua-router-basic 的 vendor，**不依赖本地 ChatGPT app 或 `~/.codex`**。

- fallback 由 **cua-router-basic 的签名 codex app-server** 托管驱动。普通 shell 裸 spawn `SkyComputerUseClient event-stream mcp` 会因缺少事件观察者上下文而挂起；普通 Python 再 spawn codex 还会因不可信祖先链报 `-1743`。当前 `daemon.sh` 通过 `launchd` 直接启动技能内签名 codex，router 仅走 token 化 loopback WebSocket，完整 RCA 见 `references/recording-architecture.md`。
- 首次需给 vendor app（`vendor/computer-use/Codex Computer Use.app`）授予 macOS **屏幕录制** 与 **辅助功能** 权限；授权一次后长期有效。`start` 后屏幕出现**录制指示器**，无阻塞确认框。
- 起录前不要执行 `/ready` 深探针或 `sky.list_apps()`；它们可能抢占唯一事件观察者连接并导致约 35 秒录制超时。`daemon.sh` 已默认关闭启动时 deep readiness。
- 空闲时 `status` 可能回 `-10005 Record & Replay is not enabled for this user`（账号 feature-flag 探测），不影响本地 `start` 真正录制。
