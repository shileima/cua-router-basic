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

## 架构：MCP 优先，shell fallback 可用

录制（event-stream）**不能**靠普通 shell 裸 spawn `SkyComputerUseClient event-stream mcp` 驱动。录制服务 `SkyComputerUseService` 是个 GUI 服务，它在等 **codex app-server 的事件观察者连接**来接收录制事件流；没有这条连接，`start` 会连上服务但永远收不到 XPC 回复而挂起（与权限、宿主前台与否无关）。

对齐 Codex 官方 `record-and-replay` 插件，优先使用宿主已托管的 MCP server：

- server：`user-record-desk-event-stream`（显示名通常为 `record-desk-event-stream`）
- tools：`event_stream_start` / `event_stream_status` / `event_stream_stop`

调用前必须先用 MCP discovery 检查该 server 是否可用；可用时直接调用对应工具。若 MCP 不可发现、调用报错或超时，可以走 `scripts/event-stream.sh start|status|stop` 作为 shell fallback。fallback 不是另一套录制实现：脚本只会转调 `cua-router /record`，仍由同一个 codex app-server 托管 `event_stream` MCP，禁止裸 spawn `SkyComputerUseClient event-stream mcp`。

`scripts/event-stream.sh mcp` 供插件宿主以 stdio MCP server 方式挂载并暴露 `event_stream_*` 工具；`start|status|stop` 供 Agent 在宿主 MCP 不可用时兜底调用。

> 完整根因排查、进程栈证据、被证伪的方向与解法见 `references/recording-architecture.md`。

## 权限前置（首次一次性）

录制会捕获鼠标、键盘输入与窗口内容，依赖 macOS 授权：

- 首次需给 cua-router-basic 的 vendor app（`vendor/computer-use/Codex Computer Use.app`）授予 **屏幕录制** 与 **辅助功能（Accessibility）**。授权一次后长期有效。
- `start` 后屏幕上会出现**录制指示器**（无阻塞确认框）。本技能只用 cua-router-basic 的 vendor，不依赖本地 ChatGPT app / `~/.codex`。

## 录制工作流（对齐 Codex record-and-replay 官方语义）

**不要**要求用户先把目标 App 切到前台、也不要让用户回复「好了」才起录——这与 Codex 官方 `record-and-replay` 不一致。正确做法是：**用户说开始录制 → 立即 `event_stream_start` → 结束本轮让用户去操作**。

SkyComputerUseService 在录制期间会监听 App 激活/切换（Dock 点击、Cmd+Tab、直接点窗口），并为新激活的窗口自动发出 `window.changed`，附带完整或 diff 形式的 AX tree。也就是说，**AX 同步发生在用户激活 App 时，由录制服务自动完成，不需要 Agent 在起录前手动 `activate` 或 `ax.get` 预热**。

优先入口：宿主 MCP 工具 `event_stream_start` / `event_stream_status` / `event_stream_stop`。MCP discovery 不可用或调用失败时，允许 fallback 到 `scripts/event-stream.sh start|status|stop`；fallback 必须继续经 `cua-router /record`，不能直接调用底层 Sky client。

规则（与 Codex 官方 `record-and-replay` SKILL 一致）：

- 仅在用户准备好开始录制时调用宿主 MCP `event_stream_start`。**起录前不要求**目标 App 在前台，**不要**让用户先切窗口再回复「好了」。
- `event_stream_start/status/stop` 任一调用失败或超时后先原样报告；若用户仍要继续录制，或宿主 MCP 根本不可发现，可调用 `event-stream.sh start|status|stop` 作为 fallback。
- `start` 秒回后**不要** sleep、poll 或循环等待；**不要**用 Computer Use 替用户操作。结束本轮，提示最长 30 分钟，让用户去演示，录完回来告知。
- 用户演示时正常切换 App 即可（Dock / Cmd+Tab / 点窗口）；录制服务会在激活时自动捕获 `window.changed` 和 AX tree。
- **同一时刻只允许一个录制**。若 `start` 报告已有活跃录制，不要重启，询问用户是用当前录制还是等它结束。
- 只有用户主动询问状态或录完回来时才 `status`；不要用它来 poll。
- 用户说录完 → `stop`，然后读取返回里的 `metadataPath` / `eventsPath`（即 `events.jsonl` / `session.json`）并**用普通文件工具读盘**、检查事件后再回应。
- 用户说取消了 → 不要再 `stop`，可读 `session.json` 确认 `endReason` 为 `recording_controls_cancelled`，致谢并不生成技能。
- 事件内容不经端点返回，只在磁盘上（`sessionDirectoryPath` 下）。
- **stop 后校验产物质量**：读 `events.jsonl`，若目标 App 的 `window.changed` 是 BARE（缺 `app`/`ax` 字段）、或该 App 下所有 `mouse.click` 的 target 都是 `role=AXGroup` 窗口壳层，说明这次激活时 AX 未完整同步。告知用户重录，并建议：**确保目标 App 已打开且主界面可见后再做第一次点击，每步操作后稍停半秒**。不要基于坏产物生成技能。

> 已知量：空闲（无活跃会话）时 `status` 可能返回 `-10005 Record & Replay is not enabled for this user`——这是服务端对账号 feature-flag 的探测，不影响本地 `start` 真正开始录制。以 `start` 返回的 `isRecording: true` 与产物落盘为准。

产物落盘在系统临时目录 `…/sky/event_stream/<sessionID>/`（路径以 `start`/`stop` 返回为准）。解读见 `references/event-stream.md`。

## 回放执行纪律（强制）

无论是**直接回放录制**（「回放刚才的操作」）还是**执行/生成回放技能**，都必须把录制里的每一个正常 action 当作一等公民，**不得跳过、合并、忽略或「聪明地省略」任何一步**。回放不是意图摘要，而是逐步复刻用户演示。

**每个 action 的标准循环**（一步都不能省）：

1. **操作前 — 审视 AX Tree**：`ax.get(app)`（必要时 `{ refresh: true }`），观察当前窗口/UI 状态是否与录制该步前的上下文一致；在 AX Tree 中**明确记录**本步要操作的元素节点（role、可见文案、`element_index` 或稳定语义定位），确认节点存在且可交互后再动手。
2. **执行 — 只做本步 action**：严格对应录制里的这一个动作（点击 / 输入 / 按键 / hover / 滚动…），不夹带下一步，不凭记忆盲点。
3. **操作后 — 再次审视 AX Tree**：立刻 `ax.get(app)`（shell / AppleScript / swift 等外部动作后必须 `{ refresh: true }`），对照录制里该步之后的 UI 变化，**验证上一步是否生效**（焦点是否转移、文本是否写入、页面是否跳转、按钮状态是否变化）。
4. **规划下一步**：基于最新 AX Tree 记录下一个待操作节点；若验证失败或 UI 与录制分叉，**停止跳步**，先排查/降级/重定位，不得带着错误状态继续后续 action。

禁止：用「已经在目标页了」「这步不重要」「效果一样」等理由跳过录制中的正常 action；禁止批量连点多个录制步骤而不逐步校验；禁止复用过期的 `element_index` 而不重取树。

### 动作等价约束（强制）

回放和生成技能必须复刻**用户实际做过的动作类型**，不能把中间 UI 操作折叠成最终状态：

- 只有录制事件本身是在浏览器地址栏 / 原生 URL 输入框输入地址并提交时，才允许用「地址栏写 URL + Return」回放。
- 如果录制里用户是在页面内搜索框输入关键词、点击页面内按钮、选择筛选项、填写表单，即使这些动作最终导致 URL 变化，也必须回放为「定位页面内控件 → 输入/点击 → 校验结果」，禁止直接导航到变化后的最终 URL。
- `window.location`、AppleScript `set URL of front document`、直接打开搜索结果页等只允许作为录制中真实 URL 导航动作的实现方式；不得替代页面内搜索、筛选、翻页、提交等用户动作。
- 如果页面内控件 AX 定位不稳定，必须按 AX → hover → OCR → 坐标扫描降级继续定位该控件；仍不得用最终 URL 绕过该步骤。
- 每次回放总结必须按动作时间线说明实际执行了哪些动作；若采用任何等价替代，必须明确标注并说明原因，且不能违反以上规则。

生成回放技能时，必须把上述纪律写进技能步骤（模板见 `references/replay-skill-template.md`）。

## 从录制生成技能（核心价值）

**默认严格覆盖完整录制链路**：生成的回放技能必须包含录制里的**全部结构性动作**，从第一个动作（如打开/激活应用、地址栏导航）到最后一个动作（如保存并校验结果）逐步复刻，**不得以「意图归纳」为由删减、合并或跳过任何一步**。参考 codex 的转技能实现（`codex-record-skill`：严格回放「打开 Chrome → 进入 RPA 平台 → 打开工作流列表 → 进入配置页 → 新增指令 → 填值 → 保存」的完整主链路，且不假设「已经在目标页面」）。

生成技能时：

1. 先读 `references/event-stream.md` 学会解读 `events.jsonl`（应用/窗口归属、选中/焦点、AX diff 语法、敏感信息处理）。
2. **按时间顺序把每个结构性动作映射成一个回放步骤**，覆盖完整链路：把打开/激活应用、地址栏导航、进入列表、进入配置页等前置动作也纳入，不要跳到「有意义的那一步」。只有明确的误操作（误点后立刻撤销、无意义的来回滚动）才作为噪声剔除，其余一律保留。
3. 仅把**随场景变化的演示值**（网址、工作流名、收件人、金额、文件名…）抽成**技能输入参数**并给出录制默认值；动作本身与其顺序不做删减。若有影响技能的歧义，先问清再动手。
4. 文本输入必须按控件能力选择写法：原生输入框/地址栏可用 `sky.set_value`；但在 Chrome/Safari 中，普通文本输入必须先排除顶部导航地址栏，只有明确的 URL 打开/导航动作才允许写入地址栏；页面内搜索框、筛选框、表单字段必须先定位对应控件再输入并校验，不得直接打开最终结果页或改写 URL 来替代；如果录制目标软件不支持 AX 写值、`set_value` 写后校验失败、或 AX 显示为 `文本输入区` / 编辑器容器 / contenteditable / 桌面 IM 输入区，生成技能时必须降级为 shell 层 `/usr/bin/pbcopy` 设置剪贴板（用绝对路径，避免沙箱 PATH 收窄报 `pbcopy 在当前环境不可用`；不可用时按 `cua-router-basic` 的 `references/input-keyboard.md` 兜底章节处理）+ shell 层 `/usr/bin/osascript` 发送系统级 `Command+A` / `Command+V`。该类外部系统动作后立刻 `ax.get(app, { refresh: true })` 重新取树，避免旧 `element_index` 失效。
5. 消息发送类动作必须重新定位并点击「发送」按钮；不要把录制里的回车或用户键盘输入翻译成 `Return` 发送，除非录制目标明确是地址栏导航或表单提交且已校验。
6. 优先用稳定语义接口（连接器/专用工具）完成稳定操作；UI 交互、依赖视觉的校验、或“操作界面本身就是任务”时用 **Computer Use**。严格执行上方「回放执行纪律」：**每个 action 操作前审视 AX Tree 并记录目标节点 → 执行本步 → 操作后再次审视 AX Tree 验证上一步 → 再规划下一步**；凡是 shell / AppleScript / swift / 手动鼠标等外部动作后，用 `{ refresh: true }` 强制重取。
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
