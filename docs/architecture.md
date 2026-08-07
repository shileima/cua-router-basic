# 架构与关键文件

## 分层图

```
┌──────────────────────────────────────────────────────────────────────┐
│  ①  用户 / Agent（Cursor / Claude / automan / newapi upstream）        │
└──────────────────────┬───────────────────────────────────────────────┘
                       │ POST /exec 或 POST /responses
┌──────────────────────▼───────────────────────────────────────────────┐
│  ②  cua-router.py（127.0.0.1:18901）                                  │
│     - /exec   → 直通 node_repl                                        │
│     - /responses → newapi 反代 + mcp_loop tool_call 回填                │
│     - /ready /health → 分层就绪探针                                    │
└──────────────────────┬───────────────────────────────────────────────┘
                       │ stdio JSON-RPC
┌──────────────────────▼───────────────────────────────────────────────┐
│  ③  codex app-server（vendor/codex/bin/codex app-server --listen stdio://）│
│     - 单例进程，持久 threadId                                          │
│     - 首次 /exec 自动 bootstrap sky（挂到 globalThis）                  │
└──────────────────────┬───────────────────────────────────────────────┘
                       │ mcpServer/tool/call "node_repl.js"
┌──────────────────────▼───────────────────────────────────────────────┐
│  ④  node_repl（vendor/cua_node/bin/node_repl）                        │
│     - stateful REPL，globalThis 跨 /exec 保留                          │
│     - 每段代码自动包 { ... } 块级作用域                                  │
│     - globalThis.sky / globalThis.ax 挂载于此                          │
└──────────────────────┬───────────────────────────────────────────────┘
                       │ import @oai/sky/dist/.../mac/create_client.js
┌──────────────────────▼───────────────────────────────────────────────┐
│  ⑤  sky Computer Use Client                                           │
│     vendor/computer-use/.../SkyComputerUseClient                       │
│     ← native pipe                                                     │
│     com.openai.sky.CUAService（macOS Group Container 服务）             │
└──────────────────────────────────────────────────────────────────────┘
```

## 关键文件

| 文件 | 层 | 职责 | 改动影响 |
|---|---|---|---|
| `scripts/cua-router.py` | ② | HTTP 服务 + mcp_loop + `AppServerSession` 单例 | 改 /exec 语义、readiness 探针 |
| `scripts/computer-use-client.mjs` | ④ ↔ ⑤ | 挂 `sky` 与 `ax` 到 globalThis、wrap sky mutation、管理 AX 缓存 | **本次 AX 缓存策略的核心** |
| `scripts/vendor_paths.py` | ③④⑤ | 解析 vendor 目录结构、写 `runtime/config.toml` | 加/删 vendor 依赖 |
| `scripts/daemon.sh` | 外围 | nohup 启动 cua-router + 就绪等待 + preflight | 启动 / 停止 / 重启 |
| `scripts/exec.sh` | 外围 | 客户端脚本：POST /exec + 解析 nodeRepl 输出 | 用户直接调用 |
| `scripts/lib/preflight-chrome.sh` | 外围 | Playwright / Chrome 无窗口检测与修复 | 影响 Chrome 场景可用性 |
| `references/*.md` | 文档 | 用户/agent 可读的操作规范 | 用户看到的示例 |
| `docs/*.md` | 文档 | 维护者视角 | 内部规范 |
| `SKILL.md` | 文档 | 顶层入口 + 索引 | 用户第一眼看到 |
| `.meta.json` + `.cursor-plugin/plugin.json` + `.claude-plugin/*.json` | 元 | 4 处版本号必须同步 | 见 [release-workflow.md](./release-workflow.md) |
| `vendor/manifest.json` | 元 | vendor 提取时的校验（sky_client_sha256 等） | vendor 更新时会重写 |
| `runtime/config.toml` | 元 | codex app-server 运行时配置，由 `write_runtime_config` 生成 | 无需手改 |

## `globalThis` 上的两组 API

由 `scripts/computer-use-client.mjs` 的 `setupComputerUseRuntime` 挂载。**任何 /exec 代码块都可直接使用，不需要 import**：

- `globalThis.sky.*`：wrap 过的 sky client。每个 mutation 方法（`click / set_value / press_key ...`）执行后会自动 `invalidateAxCache(input.app)`；`press_key` 额外做键名归一化。
- `globalThis.ax.*`：AX Tree helpers（`get / invalidate / findIdx / findAllIdx / findFocusedIdx / linesMatching / summarize / _stats / _resetStats`）。

详见 [`ax-cache-design.md`](./ax-cache-design.md)。

## 生命周期

1. `daemon.sh start`：
   - 检查 `runtime/config.toml` / `vendor/` 完整性
   - `nohup python3 cua-router.py` 拉起 HTTP 服务
   - 首次请求触发 `AppServerSession._start` → `codex app-server` → node_repl ready
   - 首次 `/exec` 触发 `SKY_BOOTSTRAP` → 执行 `setupComputerUseRuntime` → 挂 `sky` + `ax`
   - `_sky_bootstrapped=true` 后不再重跑 bootstrap（**改 mjs 后必须 restart**）

2. `/exec` 处理：
   - `wrap_js_for_repl(code)` 把用户代码包进 `{ ... }` 隔离作用域
   - `mcpServer/tool/call node_repl.js` 执行
   - 结果通过 `nodeRepl.write(...)` 回传，包装成 MCP `content` 数组

3. AX 缓存生命周期（跨 /exec）：
   - `globalThis[Symbol.for("openai.computer-use.ax-cache")]` 持有 `Map<app, { state, fetchedAt }>`
   - 直到 daemon 重启或手动 `ax.invalidate()` 才失效
   - 见 [`ax-cache-design.md`](./ax-cache-design.md)

## 从"用户改了业务代码"到"跑起来"的最短路径

场景 A：只改 `references/*.md`（文档） → **不需要任何重启**，agent 下次读取即可。

场景 B：改 `scripts/computer-use-client.mjs`（挂载 / wrapper / helpers） → **必须 `daemon.sh restart`**，因为已 bootstrap 的 node_repl 不会重新执行 `setupComputerUseRuntime`。

场景 C：改 `scripts/cua-router.py`（HTTP / mcp_loop） → **必须 `daemon.sh restart`**。

场景 D：改 vendor（升级 codex / sky） → 见 [`sky-and-vendor-sync.md`](./sky-and-vendor-sync.md)。

场景 E：改版本号 → `bump-version.sh <x.y.z>`（不接受 beta 后缀）或手动改 4 处 JSON，见 [`release-workflow.md`](./release-workflow.md)。
