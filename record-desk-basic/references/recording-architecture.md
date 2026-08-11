# 录制架构与根因：观察者连接、进程信任链与 `-1743`

> 本文沉淀 `record-desk-basic` 录制链路的最终 RCA。录制故障包含两个相互独立的问题：一是 `node_repl` 预热抢占唯一事件观察者连接，造成约 35 秒超时；二是普通 shell 启动的未签名 Python 成为祖先进程，导致 Sky IPC 以 `-1743` 拒绝 Apple Event bootstrap。最终解法必须同时满足“由同一个 app-server 托管事件流”和“签名进程具有可信祖先链”，且不得依赖本地 ChatGPT/Codex Desktop。

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

## 二、最终故障模型

### 故障 A：事件观察者连接被预热抢占

`SkyComputerUseService` 的 `CodexAppServerThreadEventObserver.connection` 是录制链路依赖的唯一观察者连接。旧版 `daemon.sh` 在启动后自动执行深度 readiness：

```text
node_repl → sky.list_apps() → 建立并占用事件观察者连接
```

随后 `event_stream_start` 再尝试建立录制观察者时无法获得连接，表现为约 35 秒超时。它不是“服务启动慢”，重试也不会释放已被占用的观察者。

修复原则：

- `CUA_ROUTER_START_READINESS` 默认值必须为 `off`。
- 启动录制前不得执行 `/ready?deep=true`、`sky.list_apps()` 等会预热 Sky 原生管道的探针。
- `/health` 只做 app-server liveness，不能替代录制端到端验证。

### 故障 B：未签名祖先导致 `-1743`

绕过预热后，普通 shell 链路会稳定返回：

```text
Computer Use server error -1743: Unknown error
```

`-1743` 对应 macOS `errAEEventNotPermitted`。关键不只是直接发送者是否签名，而是 Sky IPC 会审计完整进程祖先：

```text
python cua-router（未签名）
└── vendor codex（OpenAI 签名）
    └── SkyComputerUseClient（OpenAI 签名）
```

vendor 内部可观测到的授权失败分类包括 `MISSING_PARENT`、`UNTRUSTED_PARENT`、`RELAY_WITHOUT_TRUSTED_ANCESTOR`。即使 `codex` 和 `SkyComputerUseClient` 本身签名有效，只要由未签名 Python 间接拉起，仍可能被判定为不可信 relay。

已验证的可信拓扑是：

```text
launchd
└── vendor/codex/bin/codex app-server（OpenAI 签名）
    └── SkyComputerUseClient event-stream mcp（OpenAI 签名）

python cua-router
└── 仅通过 127.0.0.1 WebSocket 连接 app-server，不再是其祖先
```

### 版本对照结论

对 `v0.4.17`、`v0.4.18`、`v0.4.19` 的 vendor 做哈希和实际链路对照后，核心二进制一致，三版均会复现上述架构问题。因此这不是版本回退能解决的问题，最终运行态选择 `v0.4.19` 并修复启动拓扑。

## 三、排查过程与关键证据

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

## 四、验证假设（隔离实验）

用一个只含 `event_stream` 的临时 config 启动项目 vendor 中的 codex app-server，通过 app-server 的 `mcpServer/tool/call` 调 `event_stream_status`：

- 之前裸 spawn：**超时卡死**。
- 经 app-server 托管：**0.2s 返回** `{"isRecording": false, ...}`。

再走完整 `start → status → stop`：全部 0.2~0.4s 返回，`events.jsonl` / `session.json` 正确落盘，事件流里能看到 `session.started / window.changed(含 AX 树) / mouse.click / keyboard.text_input / selection.changed / session.ended`。**无头、无系统确认框**。

假设成立：**录制必须由 codex app-server 托管**。

## 五、解法（已固化进代码）

让项目内 vendor 的签名 `codex app-server` 由 `launchd` 直接托管，再由该 app-server 同时托管 `node_repl` 和 `event_stream`。`cua-router.py` 只通过本机 WebSocket 连接 app-server，并暴露 HTTP 端点驱动录制；`record-desk-basic` 退化为瘦客户端。

### 1. `launchd` 托管签名 app-server

`scripts/daemon.sh` 在 runtime 目录生成 LaunchAgent plist 和随机 capability token，然后启动：

```text
<vendor>/codex/bin/codex app-server
  --listen ws://127.0.0.1:<router-port+1>
  --ws-auth capability-token
  --ws-token-file <runtime>/app-server.token
```

安全和独立性约束：

- listener 只绑定 `127.0.0.1`。
- token 每次启动重新生成，权限为 `0600`；runtime 目录权限为 `0700`。
- app-server、Sky client、Computer Use app 全部来自技能内 `vendor/`。
- 不探测、不连接 `/Applications/ChatGPT.app`、Desktop IPC 或 `~/.codex/ipc`。
- router 停止时同步 `launchctl bootout` 对应 app-server。

### 2. cua-router 使用 WebSocket JSON-RPC

`scripts/cua-router.py` 内置最小 RFC 6455 客户端，不引入第三方依赖。连接时携带 capability token，并显式声明：

```json
{
  "capabilities": {
    "experimentalApi": true,
    "mcpServerOpenaiFormElicitation": true
  }
}
```

后者向新版 app-server 声明客户端支持表单确认协议；如果服务实际发出 `mcpServer/elicitation/request`，router 还必须按 JSON-RPC 反向请求语义返回用户的接受或拒绝结果，不能把它当普通通知丢弃。WebSocket 握手校验 `Sec-WebSocket-Accept` 时必须大小写无关地比较 header 名和值，避免合法握手被错误拒绝。

### 3. 在 app-server 的 config.toml 注册 event_stream mcp server

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

### 4. cua-router 暴露 /record 端点转发

`scripts/cua-router.py`：

- `AppServerSession.call_event_stream(action)`：对 app-server 发 `mcpServer/tool/call`，`server="event_stream"`，`tool="event_stream_<action>"`。
- HTTP `POST /record  {"action":"start|status|stop"}` → 返回 MCP tool 结果。

因为 event_stream 由这个 app-server 托管，那条 `CodexAppServerThreadEventObserver.connection` 就此建立，录制事件有观察者接收，调用**秒回不再挂起**。

### 5. record-desk-basic 变为瘦客户端

`record-desk-basic/scripts/event-stream.sh`：确保 cua-router 守护进程在跑（`daemon.sh start`，其 app-server 已托管 event_stream 并连通 CUAService），再把 `start/status/stop` 转成对 `/record` 的 `curl`。**不再**自己 spawn `event-stream mcp`。

## 六、被证伪的方向（不要再走）

| 方向 | 为什么无效 |
|---|---|
| 授予“屏幕录制 / 辅助功能” | 这些权限是实际捕获所必需，但不能修复观察者竞争或不可信祖先导致的 `-1743`。 |
| 换前台 GUI 宿主（Automan/Cursor）挂 MCP | 只要仍裸 spawn `event-stream mcp`，或进程祖先链不可信，就会继续超时或报 `-1743`。 |
| 复用本地 ChatGPT/Codex Desktop IPC | 会引入未声明的本机应用依赖、身份耦合和版本漂移，违反技能自包含边界。 |
| 使用 `codex app-server daemon bootstrap` | 该命令要求另一个 installer 管理的 standalone Codex 目录，不适合作为技能运行时依赖。 |
| 直接 `open` vendor app / 处理 `-609 connectionInvalid` | 即使服务在跑，缺 app-server 观察者连接或可信祖先链仍无法录制。 |
| 给 event-stream 客户端加超时/重试 | 只能更快暴露失败，不能释放观察者或修复进程授权。 |
| 回退 v0.4.17 / v0.4.18 | 三版核心 vendor 二进制一致，问题属于启动拓扑而非版本回归。 |

## 七、诊断顺序与验收标准

遇到录制超时或 `-1743` 时，按以下顺序检查，避免混淆故障：

1. 确认 `daemon.sh` 未自动执行 deep readiness；日志中不应在起录前出现 `sky.list_apps()` 预热。
2. 用 `ps -axo pid,ppid,command` 确认 app-server 的父进程是 `launchd`，而不是 Python、shell 或 IDE helper。
3. 用 `launchctl print gui/$(id -u)/com.meituan.cua-router.app-server.<port>` 检查 job 为 running。
4. 检查 `http://127.0.0.1:<port+1>/readyz`，再检查 router `/health`。
5. 最终必须走真实 `start → status → stop`；仅 `/health` 或 `/ready` 成功不能证明录制可用。
6. `stop` 后同时验证 `eventsPath` 和 `metadataPath` 存在且非空。

一次成功验收至少满足：

```text
start:  isRecording=true
status: isRecording=true，sessionID 与 start 一致
stop:   isRecording=false，endReason=tool_stopped
events.jsonl: 存在且非空
session.json: 存在且非空
```

## 八、已知量

- **空闲时 `status` 可能返回 `-10005 Record & Replay is not enabled for this user`**：这是服务端对账号 feature-flag 的探测，出现在“从未有过会话”的空闲态；不影响本地 `start` 真正开始录制。以 `start` 返回的 `isRecording: true` 与产物落盘为准。
- **不要直接运行 `python3 scripts/cua-router.py` 作为录制生产链路**：这会重新形成未签名 Python → signed codex 的祖先关系并触发 `-1743`。统一通过 `scripts/daemon.sh start`，由它先建立 launchd app-server。
- **宿主托管 MCP 与 fallback 在录制路径上是等价的**：无论走 Codex 官方 `record-and-replay` 插件还是 `record-desk-basic` 的 `/record` fallback，都由 codex app-server 托管 `event-stream mcp`，事件观察者连接同样建立、AX 捕获能力也一样。
- **不要让 MCP 配置指向不存在的入口**：如果宿主配置为 `event-stream.sh mcp`，脚本必须支持 `mcp` 模式并启动 `event-stream-mcp.py` 代理；该代理继续转调 `cua-router /record`，由 launchd 托管的 codex app-server 驱动真正的 `event_stream` MCP。否则 live discovery 会失败，Agent 只能退回 shell fallback。
- **AX 同步发生在录制期间的 App 激活时（对齐 Codex 官方流程）**：Codex 官方 `record-and-replay` SKILL **不要求**起录前把目标 App 切到前台。正确流程是：`event_stream_start` → 用户正常操作 → 当用户通过 Dock / Cmd+Tab / 点窗口激活某个 App 时，SkyComputerUseService 自动发出 `window.changed` 并附带完整或 diff 形式的 AX tree → 后续点击命中语义 target。Codex 成功录制即采用此流程（起录时宿主在前台，用户点 Dock 激活目标 App 后 `window.changed` 含完整 AX）。**不要**在 Agent 侧要求用户先切前台再回复「好了」。若 stop 后产物质量差（BARE `window.changed` 或点击全是 `AXGroup` 壳层），常见原因是目标 App 主界面尚未渲染完就做了第一次点击，建议重录时确保 App 已打开且主界面可见后再操作。

## 九、一句话结论

> 录制成功需要同时满足两件事：`event_stream` 由持有唯一观察者连接的 app-server 托管，并且该 app-server 由 `launchd` 直接启动以保持签名可信祖先链。技能只使用自身 vendor，通过 token 化 loopback WebSocket 控制，绝不依赖本地 ChatGPT/Codex Desktop。
