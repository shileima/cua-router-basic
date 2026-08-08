# record-desk-basic

macOS 桌面「录制 → 回放 → 转技能」独立技能。把 ChatGPT app 里 **Record & Replay** 插件的全部能力内置进来，**复用** `cua-router-basic` 已 vendor 的 `SkyComputerUseClient` 二进制（不重复打包）。

## 它做什么

- `event_stream_start / status / stop`：录制用户在 Mac 上的一次演示（鼠标、键盘、窗口 AX 内容，最长 30 分钟）。
- 录制产物 `events.jsonl` / `session.json` 落盘（默认隔离在 `runtime/`）。
- 读盘解读后，按 `cua-router-basic` 规范生成「用 Computer Use 高效回放」的可复用技能。

## 与 cua-router-basic 的关系

| 关注点 | 技能 |
|---|---|
| 录制捕获 / 录制生命周期 / 录制转技能 | **record-desk-basic**（本技能） |
| Computer Use 执行 / AX 缓存 / sky·ax 运行时 | **cua-router-basic**（回放技能依赖它执行） |

两者共用同一份 vendor 二进制，但服务链、生命周期、失败域相互隔离。

## 快速开始

```bash
# 0) 依赖校验（定位 cua-router-basic + 拉起 cua-router 守护进程）
bash scripts/setup.sh

# 1) 开始录制（秒回，返回 eventsPath；屏幕出现录制指示器）
bash scripts/event-stream.sh start
#    —— 结束本轮，等用户把演示做完 ——

# 2) 用户回来后
bash scripts/event-stream.sh status
bash scripts/event-stream.sh stop     # 返回 metadataPath / eventsPath
```

> 录制经 cua-router-basic 的 codex app-server 托管驱动（`event-stream.sh` 只是调用 cua-router 的 `/record` 端点的瘦客户端）。裸 spawn `event-stream mcp` 会挂起——详见 SKILL.md「架构」一节。

## 目录

```
record-desk-basic/
├── SKILL.md                     # 技能入口：录制工作流 + 转技能规范 + 触发词
├── README.md
├── .meta.json / .codex-plugin / .cursor-plugin / .claude-plugin
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

- 录制由 **cua-router-basic 的 codex app-server** 托管驱动。裸 spawn `SkyComputerUseClient event-stream mcp` 会连上服务但收不到 XPC 回复而挂起——录制事件需要 app-server 的事件观察者连接来承接。
- 首次需给 vendor app（`vendor/computer-use/Codex Computer Use.app`）授予 macOS **屏幕录制** 与 **辅助功能** 权限；授权一次后长期有效。`start` 后屏幕出现**录制指示器**，无阻塞确认框。
- 空闲时 `status` 可能回 `-10005 Record & Replay is not enabled for this user`（账号 feature-flag 探测），不影响本地 `start` 真正录制。
