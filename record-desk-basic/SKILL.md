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
- 本技能脚本按以下顺序自动定位 cua-router-basic 根目录：`CUA_ROUTER_INSTALL_DIR` → **同级 `cua-router-basic/`（推荐，automan cua-agent profile 布局）** → 本技能父目录（同仓库开发态）→ `~/.automan/claude-code-agents/cua-agent/skills/cua-router-basic` → `~/.automan/skills/cua-router-basic`（旧布局，向后兼容）→ `~/.cursor/skills/cua-router-basic`。

## 架构：优先使用宿主托管的 event-stream MCP

录制（event-stream）**不能**靠普通 shell 裸 spawn `SkyComputerUseClient event-stream mcp` 驱动。录制服务 `SkyComputerUseService` 是个 GUI 服务，它在等 **codex app-server 的事件观察者连接**来接收录制事件流；没有这条连接，`start` 会连上服务但永远收不到 XPC 回复而挂起（与权限、宿主前台与否无关）。

对齐 Codex 官方 `record-and-replay` 插件时，首选方式是使用宿主已托管的 MCP server：

- server：`user-record-desk-event-stream`（显示名通常为 `record-desk-event-stream`）
- tools：`event_stream_start` / `event_stream_status` / `event_stream_stop`

调用前必须先用 MCP discovery 检查该 server 是否可用；如果可用，直接调用这些工具。这条路径最接近 Codex app 的官方录制能力，能让录制事件从宿主 app-server 的观察者连接流出。

如果宿主 MCP 不可用，再使用本技能的 shell fallback：本技能把 event-stream 注册成 **cua-router-basic 的 codex app-server** 的一个 mcp server（`[mcp_servers.event_stream]`），并由 `cua-router` 暴露 `/record` 端点驱动。该路径能稳定 start/status/stop，但在部分非标准 AX 应用里，捕获到的窗口内部语义可能弱于 Codex 官方宿主路径。

`scripts/event-stream.sh` 有两种入口：

- `scripts/event-stream.sh mcp`：供插件宿主以 stdio MCP server 方式挂载，直接暴露 `event_stream_*` 工具。
- `scripts/event-stream.sh <start|status|stop>`：瘦客户端 fallback，确保 `cua-router` 守护进程在跑，再把动作转成对 `/record` 的 HTTP 调用。

> 完整根因排查、进程栈证据、被证伪的方向与解法见 `references/recording-architecture.md`。

## 权限前置（首次一次性）

录制会捕获鼠标、键盘输入与窗口内容，依赖 macOS 授权：

- 首次需给 cua-router-basic 的 vendor app（`vendor/computer-use/Codex Computer Use.app`）授予 **屏幕录制** 与 **辅助功能（Accessibility）**。授权一次后长期有效。
- `start` 后屏幕上会出现**录制指示器**（无阻塞确认框）。本技能只用 cua-router-basic 的 vendor，不依赖本地 ChatGPT app / `~/.codex`。

## 录制前置：起录时前台必须是目标 App（强制，每次录制都要做）

**这是最容易漏、但决定成败的一步**。SkyComputerUseService 在 `start` 那一刻会对当前前台 App 做一次完整 AX 树 walk 作为基线；如果起录时前台是 Agent 宿主（AutoMan 对话窗、Cursor 自己），之后切到目标 App 触发的 `window.changed` 会退化成 BARE（无 `app` / `ax` 字段），后续所有点击都被锁定成 `AXGroup <app名>` 的窗口壳层——**用户点多少次内部按钮都拿不到语义 target，事后无法生成可回放技能**。

对照实测证据：

- ❌ 在 Agent 宿主前台起录 → 目标 App 的 AX 退化到 shell tree（几百字符、无内部子节点），每次点击都是 `AXGroup <app名>`
- ✅ 起录前先激活目标 App 并校验前台，再 `start` → 后续 tab 切换、按钮点击全部命中 `AXStaticText` / `AXButton` 等语义 target，AX diff 覆盖每次界面变化

**每次录制启动前必须按顺序执行：**

### Path A：用户已在消息里指明目标 App（首选）

例如"录制 Chrome 里的操作"、"录制我在 XXX App 里的操作"。

1. **激活目标 App 到前台**（三选一，按优先级）：
   - `osascript -e 'tell application "<AppName>" to activate'`（首选）
   - 通过 cua-router-basic 的 Computer Use（`sky.focus_app` / `sky.activate_app`）
   - 让用户手动 `Cmd+Tab` 或点 Dock 图标，回复"已切换"
2. `sleep 1` 让 focus 稳定。
3. **校验前台**（必做）：
   ```bash
   osascript -e 'tell application "System Events" to name of first process whose frontmost is true'
   ```
   若返回不是目标 App，回到步骤 1 重试。
4. **强制 AX 预热**（推荐，兜住 UI 未完全 render）：`ax.get(<frontmost bundle>, { refresh: true })`，确保目标 App 的 AX tree 已经完整建立（能看到内部业务节点，而不是只有 window 壳）。若返回仍是壳层，再 `sleep 1` 重试一次；仍不行就告诉用户"目标 App 界面似乎还没加载完，请等它显示出主界面后回复'好了'"。
5. 校验通过后才 `event_stream_start`。

### Path B：用户没明说目标 App（自动判断）

例如只说"开始录制"、"录制我的操作"。

1. **询问用户切换**：告诉用户「请把你要录的目标窗口切到前台（点 Dock 图标 / Cmd+Tab / 直接点击窗口都行），准备好回复'好了'」。
2. 用户回"好了"后，读前台：
   ```bash
   osascript -e 'tell application "System Events" to name of first process whose frontmost is true'
   ```
3. **拒绝录 Agent 宿主自己**：若前台是 AutoMan / Cursor / 类 IDE 电脑对话工具（识别标志：进程名含 automan / cursor / vscode / electron 且 URL 含 `fsd-electron` 之类，或用户明确表明是"对话窗"），退回步骤 1。
4. 前台是普通 App → 记住这个 bundle 作为"预期目标"，`sleep 1`。
5. **强制 AX 预热**：同 Path A 步骤 4。
6. 预热通过 → `event_stream_start`。

### 通用后续步骤（Path A / B 共用）

7. `start` 秒回后**结束本轮**，让用户去操作。不要用 Computer Use 替用户点击，不要 poll `status`。
8. 用户回来说"录完了" → 调 `event_stream_stop`。用户没主动说完，不要主动 stop。

**反例（禁止）**：用户在 Agent 对话里说"开始录制并操作 X"，agent 不做前台激活/校验就直接 `event_stream_start`。→ 100% 拿不到目标 App 内部 AX。

## 录制工作流

优先入口：宿主 MCP 工具 `event_stream_start` / `event_stream_status` / `event_stream_stop`。若 MCP discovery 显示 `user-record-desk-event-stream` 不可用，则使用 shell fallback：`scripts/event-stream.sh <start|status|stop>`（内部经 cua-router `/record` 驱动）。

**完整推荐脚本模板**（覆盖前置激活 + 校验 + 起录）：

```bash
SKILL_ROOT="$(cd "$(dirname "$0")" && pwd)"   # 或本技能安装目录
TARGET_APP_NAME="$1"        # Path A：调用方传入目标 App 名称
# Path B：不传参数时，假定用户已把目标切到前台，直接读取当前 frontmost 作为目标

# 0) 激活/确认目标 App 在前台
if [ -n "$TARGET_APP_NAME" ]; then
  osascript -e "tell application \"$TARGET_APP_NAME\" to activate"
  sleep 1
fi
FRONT=$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true')

# 0.1) 校验：Path A 校验前台=目标名；Path B 拒绝录 Agent 宿主
if [ -n "$TARGET_APP_NAME" ] && [ "$FRONT" != "$TARGET_APP_NAME" ]; then
  echo "前台是 $FRONT，不是目标 App $TARGET_APP_NAME，中止起录"
  exit 1
fi
case "$FRONT" in
  Electron|automan-desktop-dev|Cursor|Code|Terminal|iTerm2)
    echo "前台是 Agent 宿主 $FRONT，请先切到要录的目标窗口再重试"
    exit 1 ;;
esac

# 0.2) 强制 AX 预热（可选但推荐）
# 由调用方在起录前用 `ax.get(<frontmost bundle>, { refresh: true })` 触发一次完整 AX walk，
# 若返回仍是壳层就 sleep 1 后再取一次；仍不行提示用户等界面加载完再重试。

# 1) 起录（秒回；屏幕出现录制指示器）
bash "$SKILL_ROOT/scripts/event-stream.sh" start
# —— 到此结束本轮，等用户把要录的演示做完 ——

# 2) 用户回来后查状态 / 停止
bash "$SKILL_ROOT/scripts/event-stream.sh" status
bash "$SKILL_ROOT/scripts/event-stream.sh" stop
```

规则（对齐 Record & Replay 官方 SKILL 语义）：

- 录制前**必须先按上一节「录制前置」把目标 App 拉到前台并校验**（Path A 或 Path B），否则事件流拿不到内部 AX，等于白录。
- 录制是要捕获**用户的演示**：`start` 秒回后**不要**轮询等待，也不要用 Computer Use 去替用户操作；结束本轮、提示时限（最长 30 分钟），让用户录完再回来。
- **同一时刻只允许一个录制**。若 `start` 报告已有活跃录制，不要重启，询问用户是用当前录制还是等它结束。
- 只有用户主动询问状态或录完回来时才 `status`；不要用它来 poll。
- 用户说录完 → `stop`，然后读取返回里的 `metadataPath` / `eventsPath`（即 `events.jsonl` / `session.json`）并**用普通文件工具读盘**、检查事件后再回应。
- 用户说取消了 → 不要再 `stop`，可读 `session.json` 确认 `endReason` 为 `recording_controls_cancelled`，致谢并不生成技能。
- 事件内容不经端点返回，只在磁盘上（`sessionDirectoryPath` 下）。
- **stop 后立刻校验产物质量（强制）**：读 `events.jsonl`，对每个非宿主 App 的 bundle 分别检查：如果它出现的 `window.changed` 是 BARE（缺 `app` / `ax` 字段）、或该 App 下所有 `mouse.click` 的 target 都是 `role=AXGroup` 的窗口壳层（没有 `AXStaticText` / `AXButton` / `AXTextField` 等细粒度 role），说明前置激活没生效，需要告诉用户"这次录制没能捕获到内部动作，请把目标窗口切到前台并等界面完整加载后重录"，不要基于坏产物生成技能。

> 已知量：空闲（无活跃会话）时 `status` 可能返回 `-10005 Record & Replay is not enabled for this user`——这是服务端对账号 feature-flag 的探测，不影响本地 `start` 真正开始录制。以 `start` 返回的 `isRecording: true` 与产物落盘为准。

产物落盘在系统临时目录 `…/sky/event_stream/<sessionID>/`（路径以 `start`/`stop` 返回为准）。解读见 `references/event-stream.md`。

## 从录制生成技能（核心价值）

**默认严格覆盖完整录制链路**：生成的回放技能必须包含录制里的**全部结构性动作**，从第一个动作（如打开/激活应用、地址栏导航）到最后一个动作（如保存并校验结果）逐步复刻，**不得以「意图归纳」为由删减、合并或跳过任何一步**。参考 codex 的转技能实现（`codex-record-skill`：严格回放「打开 Chrome → 进入 RPA 平台 → 打开工作流列表 → 进入配置页 → 新增指令 → 填值 → 保存」的完整主链路，且不假设「已经在目标页面」）。

生成技能时：

1. 先读 `references/event-stream.md` 学会解读 `events.jsonl`（应用/窗口归属、选中/焦点、AX diff 语法、敏感信息处理）。
2. **按时间顺序把每个结构性动作映射成一个回放步骤**，覆盖完整链路：把打开/激活应用、地址栏导航、进入列表、进入配置页等前置动作也纳入，不要跳到「有意义的那一步」。只有明确的误操作（误点后立刻撤销、无意义的来回滚动）才作为噪声剔除，其余一律保留。
3. 仅把**随场景变化的演示值**（网址、工作流名、收件人、金额、文件名…）抽成**技能输入参数**并给出录制默认值；动作本身与其顺序不做删减。若有影响技能的歧义，先问清再动手。
4. 文本输入必须按控件能力选择写法：原生输入框/地址栏可用 `sky.set_value`；如果录制目标软件不支持 AX 写值、`set_value` 写后校验失败、或 AX 显示为 `文本输入区` / 编辑器容器 / contenteditable / 桌面 IM 输入区，生成技能时必须降级为 shell 层 `pbcopy` 设置剪贴板 + shell 层 `osascript` 发送系统级 `Command+A` / `Command+V`。该类外部系统动作后立刻 `ax.get(app, { refresh: true })` 重新取树，避免旧 `element_index` 失效。
5. 消息发送类动作必须重新定位并点击「发送」按钮；不要把录制里的回车或用户键盘输入翻译成 `Return` 发送，除非录制目标明确是地址栏导航或表单提交且已校验。
6. 优先用稳定语义接口（连接器/专用工具）完成稳定操作；UI 交互、依赖视觉的校验、或“操作界面本身就是任务”时用 **Computer Use**。每步「定位 → 交互 → 校验」，关键步骤后用 `ax.get` 确认结果；凡是 shell / AppleScript / swift / 手动鼠标等外部动作后，用 `{ refresh: true }` 强制重取。
7. 生成的回放技能应**依赖 cua-router-basic**、用 `sky.*` + `ax.*` 执行，跑在已内置的快执行链上——这是比坐标回放更准、更快、更抗漂移的方式。模板见 `references/replay-skill-template.md`。
8. 按 `skill-creator` 规范创建**可发现的真实技能**并完成结构校验，而不只是一份 Markdown runbook。
9. 完成后给用户一段简明总结：**逐条对应录制动作的完整步骤清单 + 输入参数 + 假设**，便于复核纠正。

> 生成的技能引用 cua-router-basic 的方式，遵循其主文件「其他技能如何引用」一节：只写公共引用，不复制大段依赖说明。

## 与 cua-router-basic 的分工

| 关注点 | 技能 |
|---|---|
| 录制捕获、录制生命周期、录制转技能 | **record-desk-basic**（本技能，可被模型直接调用） |
| Computer Use 执行、AX 缓存、sky/ax 运行时与操作规范 | **cua-router-basic**（纯基础规范，回放技能依赖它执行） |

两者共用同一份 vendor 二进制但**服务链、生命周期、失败域相互隔离**：录制的长会话/授权弹窗异常不会波及 Computer Use 的请求-响应热路径。
