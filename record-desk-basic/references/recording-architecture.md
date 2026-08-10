# 录制架构与根因：为什么录制必须由 codex app-server 托管

> 本文沉淀 record-desk-basic 开发中最关键的一个难题：`event_stream_start/status` 长时间**卡死不回**。经系统排查定位为**架构性根因**，并给出已验证的解法。读懂本文可避免在错误方向（权限、宿主前台、bundle-id、TCC）上反复消耗。

## 一、现象

把 ChatGPT Record & Replay 的录制能力内置进技能时，最初的实现是**裸 spawn** 官方同款客户端：

```bash
SkyComputerUseClient event-stream mcp        # 作为独立 stdio MCP server
```

然后用 MCP 客户端依次发 `initialize` → `event_stream_start`。结果：

- `initialize` 正常，`tools/list` 能看到 `event_stream_start/status/stop`。
- 一调 `event_stream_start`（甚至 `event_stream_status`）就**永久阻塞**，直到超时。
- 换宿主（无头 CLI / Cursor 前台）、换 client 副本、授予屏幕录制权限——**都无效**。
- 全程**没有**系统确认框弹出，`tccd` 也无屏幕录制相关决策日志。

## 二、排查过程与关键证据

### 1. client 侧：卡在等 XPC 回复

对阻塞中的 client 采样，主线程停在 `mach_msg` → 等待 XPC reply。即：client 已经连上服务、把请求发出去了，但**服务永远不回**。说明问题不在 client，而在服务端不产生响应。

### 2. service 侧：GUI 服务在等一条 codex app-server 连接

对录制服务进程 `SkyComputerUseService` 采样，得到决定性线索：

```
Thread_..  DispatchQueue: com.apple.main-thread  -> -[NSApplication nextEventMatchingMask:...]   # 一个 AppKit GUI 事件循环，空等
Thread_..  DispatchQueue_447: CodexAppServerThreadEventObserver.connection                        # 关键：在等 codex app-server 的“事件观察者”连接
```

- 服务是个 **AppKit GUI 应用**（由 launchd 拉起），主线程空转。
- 它带一条名为 `CodexAppServerThreadEventObserver.connection` 的线程——**在等待 codex app-server 建立事件观察者连接**，录制事件要通过这条连接串流出去。

### 3. 结论：录制事件“无处可流”，于是 start 挂起

Record & Replay 在 ChatGPT 里的真实拓扑是：

```
用户操作 → CUAService(GUI 服务) 捕获 → 经 CodexAppServer 观察者连接串流 → codex app-server(加载了 record-and-replay 插件) → event-stream mcp 工具
```

裸 spawn 的 `event-stream mcp` 客户端**不经过 codex app-server**，于是服务端那条观察者连接始终建立不起来。`event_stream_start` 让服务开始捕获，但捕获到的事件**没有观察者接收**，服务因此不完成本次调用 → client 端 XPC 回复永远不来 → 卡死。

> 这与 Computer Use 能正常工作恰好互为印证：Computer Use 走的是 cua-router 的 **codex app-server + sky 原生管道** 这条 sanctioned 通道；录制之所以不行，正是因为它没走这条被托管的通道。缺的不是权限，是 **codex app-server 驱动上下文**。

## 三、验证假设（隔离实验）

用一个只含 `event_stream` 的临时 config 启一个**自己的** codex app-server，通过 app-server 的 `mcpServer/tool/call` 调 `event_stream_status`：

- 之前裸 spawn：**超时卡死**。
- 经 app-server 托管：**0.2s 返回** `{"isRecording": false, ...}`。

再走完整 `start → status → stop`：全部 0.2~0.4s 返回，`events.jsonl` / `session.json` 正确落盘，事件流里能看到 `session.started / window.changed(含 AX 树) / mouse.click / keyboard.text_input / selection.changed / session.ended`。**无头、无系统确认框**。

假设成立：**录制必须由 codex app-server 托管**。

## 四、解法（已固化进代码）

让 cua-router-basic 的 codex app-server（那个已经为 Computer Use 连通 CUAService 的同一个 app-server）**同时托管 event-stream**，并由 cua-router 暴露一个 HTTP 端点驱动。record-desk-basic 退化为瘦客户端。

### 1. 在 app-server 的 config.toml 注册 event_stream mcp server

`scripts/vendor_paths.py`（`write_runtime_config`）追加：

```toml
[mcp_servers.event_stream]
command = "<vendor>/…/SkyComputerUseClient"
args = ["event-stream", "mcp"]
startup_timeout_sec = 120

[mcp_servers.event_stream.env]
CODEX_HOME = "<runtime>"                       # 必须与 app-server 共用 CODEX_HOME
SKY_CUA_SERVICE_PATH = "<vendor>/Codex Computer Use.app"
```

- event-stream 子进程从 `$CODEX_HOME/computer-use/Codex Computer Use.app` 解析 runtime app；因此在 app-server 共用的 `<runtime>` 目录里放置 `computer-use → vendor/computer-use` 符号链接（`ensure_event_stream_home()`）。
- 不能把 event-stream 放到独立 `CODEX_HOME`：实测 `event_stream_status/start` 会重新退化为长时间不返回，或在符号链接未生成时打开 `<runtime>/event-stream-home/computer-use/Codex Computer Use.app` 失败。

### 2. cua-router 暴露 /record 端点转发

`scripts/cua-router.py`：

- `AppServerSession.call_event_stream(action)`：对 app-server 发 `mcpServer/tool/call`，`server="event_stream"`，`tool="event_stream_<action>"`。
- HTTP `POST /record  {"action":"start|status|stop"}` → 返回 MCP tool 结果。

因为 event_stream 由这个 app-server 托管，那条 `CodexAppServerThreadEventObserver.connection` 就此建立，录制事件有观察者接收，调用**秒回不再挂起**。

### 3. record-desk-basic 变为瘦客户端

`record-desk-basic/scripts/event-stream.sh`：确保 cua-router 守护进程在跑（`daemon.sh start`，其 app-server 已托管 event_stream 并连通 CUAService），再把 `start/status/stop` 转成对 `/record` 的 `curl`。**不再**自己 spawn `event-stream mcp`。

## 五、被证伪的方向（不要再走）

| 方向 | 为什么无效 |
|---|---|
| 授予“屏幕录制 / 辅助功能” | 授权后 status 仍卡死；权限不是根因（服务端根本没走到 TCC 授权阶段）。 |
| 换前台 GUI 宿主（Automan/Cursor）挂 MCP | 只要还是裸 spawn `event-stream mcp`、不经 app-server，就同样卡死。 |
| 直接 `open` vendor app / 处理 `-609 connectionInvalid` | 那是另一个 bundle-id 冲突话题；即使服务在跑，缺 app-server 观察者连接照样卡。 |
| 给 event-stream 客户端加超时/重试 | 只是让卡死更快失败，不解决“事件无处可流”。 |

## 六、已知量

- **空闲时 `status` 可能返回 `-10005 Record & Replay is not enabled for this user`**：这是服务端对账号 feature-flag 的探测，出现在“从未有过会话”的空闲态；不影响本地 `start` 真正开始录制。以 `start` 返回的 `isRecording: true` 与产物落盘为准。
- **守护进程会被自动化沙盒回收**：在受限 Shell 里用 `daemon.sh start` 起的 cua-router，可能在该次工具调用结束时被连同进程组杀掉。开发自测时改用**常驻后台作业**方式运行 `python3 scripts/cua-router.py --port <port>`，再从别处 `curl`。生产环境由 Automan/Cursor 侧长期托管，不受影响。
- **宿主托管 MCP 与 fallback 在录制路径上是等价的**：无论走 Codex 官方 `record-and-replay` 插件还是 `record-desk-basic` 的 `/record` fallback，都由 codex app-server 托管 `event-stream mcp`，事件观察者连接同样建立、AX 捕获能力也一样（曾以为 fallback 在某些非标准 AX 应用只能看窗口壳、宿主 MCP 能拿更完整 AX diff，这个判断已被下一条推翻——真正的分水岭是起录时前台是不是目标 App）。
- **不要让 MCP 配置指向不存在的入口**：如果宿主配置为 `event-stream.sh mcp`，脚本必须支持 `mcp` 模式并 `exec SkyComputerUseClient event-stream mcp`；否则 live discovery 会失败，Agent 只能退回 shell fallback，录制能力会弱于 Codex 官方路径。
- **起录时前台 App 决定后续 AX 捕获质量（最关键）**：SkyComputerUseService 在 `start` 那一刻会对当前前台 App 做一次完整 AX 树 walk 作为基线。若起录时前台是 A（Agent 宿主：AutoMan/Cursor 对话窗）而目标是 B（任意业务 App），后续切到 B 触发的 `window.changed` 会退化为 BARE 事件（无 `app`/`ax` 字段），此后所有对 B 的点击都会被锁到 `AXGroup <B名>` 窗口壳层，无法拿到语义 target。这个现象**曾被误诊为「某类应用的 AX 只暴露 shell」或「fallback 路径弱于宿主 MCP」**，均已被证伪。对照实测：起录前先激活目标 App → 后续 tab 切换、按钮点击全部命中 `AXStaticText` / `AXButton` 等语义 target，AX diff 覆盖每次界面变化；在 Agent 宿主前台起录 → 目标 App 只剩 shell tree、点击目标锁在 `AXGroup <app名>`。因此 SKILL.md 强制要求：**起录前必须先把目标 App 切到前台并校验**（Path A：用户报了 App 名 → osascript activate；Path B：用户没报名 → 让用户手动切前台后再 start）。此外，起录前对目标 bundle 做一次 `ax.get(bundle, { refresh: true })` 预热，可以进一步兜住"UI 未完全 render"的 race。

## 七、一句话结论

> 录制的本质是 **codex app-server 驱动的事件串流**，不是一个可以独立 shell spawn 的 MCP。对齐 Codex 的首选路径是让宿主直接托管 `event-stream mcp`；fallback 才把 event-stream 注册进 cua-router 的 app-server、经 `/record` 驱动。
