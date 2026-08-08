---
name: record-desk-basic
description: >
  macOS 桌面「录制 → 回放 → 转技能」技能。内置 ChatGPT app 的 Record & Replay 能力
  （event-stream MCP：event_stream_start / event_stream_status / event_stream_stop），
  复用 cua-router-basic 已 vendor 的 SkyComputerUseClient 二进制，不重复打包。

  当用户提到以下情况时激活：
  「开始录制」「录制我的操作」「录制工作流」「watch me do this / record my workflow」
  「把刚才的操作变成技能」「根据录制生成技能」「record and replay」「录屏转技能」
  「停止录制」「录制状态」「event stream start / stop / status」
  「录制后自动执行」「回放刚才的操作」「turn my recording into a skill」

  录制产物落盘为 events.jsonl / session.json；Agent 读盘解读后，按 cua-router-basic 规范
  生成「用 sky Computer Use 高效回放」的可复用技能。
---

# record-desk-basic — 桌面录制转技能

把用户在 macOS 上的一次演示（鼠标、键盘、窗口 AX 内容）录下来，转成一个**可复用、可高效回放**的技能。录制能力来自 `SkyComputerUseClient` 的 `event-stream mcp` 子命令——与 Computer Use 是**同一个二进制**，本技能直接复用 `cua-router-basic` 已内置的那份，不重复 vendor。

## 依赖

- **cua-router-basic**（必需）：提供 `vendor/computer-use/…/SkyComputerUseClient` 与后台 `CUAService` 预热逻辑。安装/定位见 `cua-router-basic` 的 `references/install.md`。
- 本技能脚本按以下顺序自动定位 cua-router-basic 根目录：`CUA_ROUTER_INSTALL_DIR` → `~/.automan/skills/cua-router-basic` → `~/.cursor/skills/cua-router-basic` → 本技能父目录（同仓库开发态）。

## 架构：录制必须由 cua-router-basic 的 app-server 托管

录制（event-stream）**不能**靠裸 spawn `SkyComputerUseClient event-stream mcp` 驱动。录制服务 `SkyComputerUseService` 是个 GUI 服务，它在等 **codex app-server 的事件观察者连接**来接收录制事件流；没有这条连接，`start` 会连上服务但永远收不到 XPC 回复而挂起（与权限、宿主前台与否无关）。

因此本技能把 event-stream 注册成 **cua-router-basic 的 codex app-server** 的一个 mcp server（`[mcp_servers.event_stream]`），并由 `cua-router` 暴露 `/record` 端点驱动。这条链正是 Computer Use 能用的那条 sanctioned 通道，录制事件有观察者接收，`start/status/stop` 都能**秒回、无头、无需系统确认框**。

`scripts/event-stream.sh` 只做瘦客户端：确保 `cua-router` 守护进程在跑，再把动作转成对 `/record` 的 HTTP 调用。

> 完整根因排查、进程栈证据、被证伪的方向与解法见 `references/recording-architecture.md`。

## 权限前置（首次一次性）

录制会捕获鼠标、键盘输入与窗口内容，依赖 macOS 授权：

- 首次需给 cua-router-basic 的 vendor app（`vendor/computer-use/Codex Computer Use.app`）授予 **屏幕录制** 与 **辅助功能（Accessibility）**。授权一次后长期有效。
- `start` 后屏幕上会出现**录制指示器**（无阻塞确认框）。本技能只用 cua-router-basic 的 vendor，不依赖本地 ChatGPT app / `~/.codex`。

## 录制工作流

统一入口：`scripts/event-stream.sh <start|status|stop>`（内部经 cua-router `/record` 驱动）。

```bash
SKILL_ROOT="$(cd "$(dirname "$0")" && pwd)"   # 或本技能安装目录
# 1) 开始录制（秒回，返回 eventsPath / sessionDirectoryPath；屏幕出现录制指示器）
bash "$SKILL_ROOT/scripts/event-stream.sh" start
# —— 到此结束本轮，等用户把要录的演示做完 ——

# 2) 用户回来后查状态 / 停止
bash "$SKILL_ROOT/scripts/event-stream.sh" status
bash "$SKILL_ROOT/scripts/event-stream.sh" stop
```

规则（对齐 Record & Replay 官方 SKILL 语义）：

- 录制是要捕获**用户的演示**：`start` 秒回后**不要**轮询等待，也不要用 Computer Use 去替用户操作；结束本轮、提示时限（最长 30 分钟），让用户录完再回来。
- **同一时刻只允许一个录制**。若 `start` 报告已有活跃录制，不要重启，询问用户是用当前录制还是等它结束。
- 只有用户主动询问状态或录完回来时才 `status`；不要用它来 poll。
- 用户说录完 → `stop`，然后读取返回里的 `metadataPath` / `eventsPath`（即 `events.jsonl` / `session.json`）并**用普通文件工具读盘**、检查事件后再回应。
- 用户说取消了 → 不要再 `stop`，可读 `session.json` 确认 `endReason` 为 `recording_controls_cancelled`，致谢并不生成技能。
- 事件内容不经端点返回，只在磁盘上（`sessionDirectoryPath` 下）。

> 已知量：空闲（无活跃会话）时 `status` 可能返回 `-10005 Record & Replay is not enabled for this user`——这是服务端对账号 feature-flag 的探测，不影响本地 `start` 真正开始录制。以 `start` 返回的 `isRecording: true` 与产物落盘为准。

产物落盘在系统临时目录 `…/sky/event_stream/<sessionID>/`（路径以 `start`/`stop` 返回为准）。解读见 `references/event-stream.md`。

## 从录制生成技能（核心价值）

录制是「用户意图的证据」，不是「逐像素复刻」的要求。生成技能时：

1. 先读 `references/event-stream.md` 学会解读 `events.jsonl`（应用/窗口归属、选中/焦点、AX diff 语法、敏感信息处理）。
2. 判断可复用工作流、目标产出、以及哪些演示值应成为**技能输入参数**而非写死。若有影响技能的歧义，先问清再动手。
3. 优先用稳定语义接口（连接器/专用工具）完成稳定操作；UI 交互、依赖视觉的校验、或“操作界面本身就是任务”时用 **Computer Use**。
4. 生成的回放技能应**依赖 cua-router-basic**、用 `sky.*` + `ax.*` 执行，跑在已内置的快执行链上——这是比坐标回放更准、更快、更抗漂移的方式。模板见 `references/replay-skill-template.md`。
5. 按 `skill-creator` 规范创建**可发现的真实技能**并完成结构校验，而不只是一份 Markdown runbook。
6. 完成后给用户一段简明的步骤/输入/假设总结，便于复核纠正。

> 生成的技能引用 cua-router-basic 的方式，遵循其主文件「其他技能如何引用」一节：只写公共引用，不复制大段依赖说明。

## 与 cua-router-basic 的分工

| 关注点 | 技能 |
|---|---|
| 录制捕获、录制生命周期、录制转技能 | **record-desk-basic**（本技能，可被模型直接调用） |
| Computer Use 执行、AX 缓存、sky/ax 运行时与操作规范 | **cua-router-basic**（纯基础规范，回放技能依赖它执行） |

两者共用同一份 vendor 二进制但**服务链、生命周期、失败域相互隔离**：录制的长会话/授权弹窗异常不会波及 Computer Use 的请求-响应热路径。
