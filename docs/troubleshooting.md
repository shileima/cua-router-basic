# 排查指南

按症状定位。每条给出**判定命令**和**修复动作**。

## 全局速查表

| 症状 | 定位到 | 常见根因 |
|---|---|---|
| `ax is not defined` / `ax.get is not a function` | 客户端 bootstrap | daemon 没重启、bootstrap 失败 |
| `ax.get(app)` 一直返回同一份 | 缓存陈旧 | 外部触发未 refresh、wrapper 白名单不全 |
| `Computer Use app approval requires app to be a plain data property` | sky 参数校验 | 漏 `app` 字段 / `app` 是 getter |
| `-10005: timeoutReached` | Chrome preflight | Playwright 抢占 Chrome / Chrome 无可见窗口 |
| `Native pipe startup failed` / `Native pipe is unavailable` | sky ↔ CUAService | 桌面服务未启、macOS 权限拒绝 |
| `Sky RPC deadline exceeded` | sky 层 | vendor 与 CUAService 版本不匹配 |
| `element_index` 点错 / 点空 | AX 树错位 | 交互后没重新取树、拿到陈旧树 |
| `already declared: sky` / `Identifier ... has already been declared` | node_repl 作用域污染 | wrap_js_for_repl 逻辑异常（应自动包 `{}`） |
| `[cua-router] not running` 后紧接 start 失败 | HTTP 端口占用 | 18901 端口冲突 |
| `daemon.sh start` 卡住 | node_repl 未 ready | vendor 缺失、codex 版本错 |
| Automan/Cursor 沙箱报 `/tmp` 锁文件写入失败 | 默认 pid/log/lock 在 `/tmp` | 已改为 `$SKILL_ROOT/runtime/`；或执行 `/sandbox` 放开限制 |

## 1. `ax is undefined` 或功能缺失

### 判定

```bash
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ax=" + typeof ax + ";keys=" + (typeof ax === "object" ? Object.keys(ax).join(",") : "n/a"))'
```

期望输出：
```
ax=object;keys=get,invalidate,findIdx,findAllIdx,findFocusedIdx,linesMatching,summarize,_stats,_resetStats
```

### 修复

- 若 `ax=undefined`：说明 bootstrap 没跑或跑了旧版 mjs。
  1. 确认 `$SKILL_ROOT/scripts/computer-use-client.mjs` 内容包含 `createAxHelpers`
  2. `bash $SKILL_ROOT/scripts/daemon.sh restart`
  3. 再验证。若仍失败，`tail -50 /tmp/cua-router.log` 看 `sky bootstrapped, keys:` 后的输出
- 若 `keys` 少：mjs 是老版本，同步一份新的。
- 若 `ax=object` 但缺 `_stats`：是 0.4.9-beta.1 版本，升级到 beta.2。

## 2. `ax.get(app)` 拿到陈旧树

### 判定

```js
{
  const s1 = await ax.get(app);
  const s2 = await ax.get(app, { refresh: true });
  nodeRepl.write(JSON.stringify({
    sameRef: s1 === s2,
    len1: s1.text.length,
    len2: s2.text.length,
    stats: ax._stats(),
  }));
}
```

- `sameRef === true` 且 `len1 === len2` → 缓存和实际 UI 一致
- `sameRef === false` 或 `len1 !== len2` → **有陈旧问题**

### 修复

1. **一次性绕过**：调用改为 `ax.get(app, { refresh: true })` 或 `ax.get(app, { maxAgeMs: 300 })`
2. **根因排查**：
   - 该场景之前是不是有外部触发（swift / AppleScript / 页面异步）？→ 属 R1.1，改用 refresh/maxAgeMs
   - 是不是 sky 新方法没进白名单？看 [`sky-and-vendor-sync.md`](./sky-and-vendor-sync.md)
   - 是不是多 agent 并发共享 globalThis？属 R3.1

## 3. `Computer Use app approval requires app to be a plain data property`

### 原因

sky 严格要求 `input.app` 是**可枚举的普通字段**（不能是 getter / setter / Proxy）。以下情况会触发：

```js
sky.click({ x: 100, y: 200 })                       // ❌ 漏 app
sky.get_app_state({ disableDiff: true })            // ❌ 漏 app
sky.click({ ...{ get app() { return "..."; } } })   // ❌ getter，罕见
```

### 修复

```js
sky.click({ app: "com.google.Chrome", x: 100, y: 200 })  // ✓
ax.get("com.google.Chrome")  // ✓（内部自动传 app + disableDiff）
```

**推荐**：任何取 AX 都用 `ax.get(app)`，从结构上避免这类错误。

## 4. `-10005: timeoutReached`（Chrome AX 超时）

### 原因

`sky.get_app_state({app: "com.google.Chrome"})` 需要 Chrome 有可见窗口且未被 Playwright 独占。

常见触发：
- Playwright MCP / cursor-ide-browser 用 `--no-startup-window` 启了个 headless Chrome
- Chrome 只有一个后台 Chrome Helper，没主窗口
- Chrome 卡在启动/更新态

### 判定与修复

```bash
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" status   # 只诊断
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" fix      # 手动修复：停 Playwright + 打开窗口
```

`exec.sh` 默认 `CUA_ROUTER_CHROME_PREFLIGHT=auto`，触发 Chrome 场景时会自动 fix。若关闭了自动 preflight：

```bash
export CUA_ROUTER_CHROME_PREFLIGHT=auto  # 恢复默认
```

## 5. `Native pipe startup failed` / CUAService 相关

### 原因

sky 客户端连不上 macOS 的 `com.openai.sky.CUAService` 桌面服务。

### 判定

```bash
# 1. socket 存在吗
ls -la "$HOME/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock"

# 2. Codex Computer Use.app 已被 macOS 授权吗
# 系统设置 → 隐私与安全 → 辅助功能 / 屏幕录制 里应看到 "Codex Computer Use" 并勾选

# 3. cua-router /ready 深度探针
curl -s -X POST http://127.0.0.1:18901/ready -H 'Content-Type: application/json' -d '{"deep":true}'
```

期望：
```json
{"ready": true, "live": true, "sky": true, "socket": true, "reason": "ok"}
```

### 修复

- socket 不存在 / 服务未启：打开 `Codex Computer Use.app` 手动运行一次，让它注册 CUAService；或系统重启
- 权限不足：优先 `bash "$SKILL_ROOT/scripts/daemon.sh" authorize` 唤起 **Enable ChatGPT Computer Use** 弹窗；或到系统设置里勾选辅助功能 + 屏幕录制
- vendor sha256 不匹配：`bash scripts/setup-vendor.sh` 重新提取

## 6. `element_index` 点错 / 点空

### 排查步骤

```js
{
  const app = "com.google.Chrome";
  ax.invalidate();  // 全清缓存排除缓存陈旧
  const s = await ax.get(app);
  const target = ax.findAllIdx(s.text, "关键词").slice(0, 5);
  const focused = ax.findFocusedIdx(s.text);
  nodeRepl.write(JSON.stringify({ target, focused, textLen: s.text.length }));
}
```

判定：
- `target` 空 → 关键词错，或元素在 Portal/Modal 高 idx 位置未被 findIdx 找到
- `target` 有但点了没反应 → element_index 可能是 container 而非交互控件，需要看上下文选精确子元素
- 之前能点，突然点错 → 可能是缓存陈旧（回 R1.1）或页面结构改了

### 定位技巧

```js
// 查目标附近上下文（±5 行）
const lines = s.text.split("\n");
const hitLine = lines.findIndex(l => /关键词/.test(l));
nodeRepl.write(lines.slice(Math.max(0, hitLine - 5), hitLine + 5).join("\n"));
```

## 7. node_repl 报 `already declared` 等作用域污染

### 原因

`cua-router.py` 里 `wrap_js_for_repl` 会自动把每段 JS 包进 `{ ... }` 块级作用域。若报 `already declared`：
- 用户代码本身在同一段里重复声明
- 或者 wrap_js_for_repl 逻辑出了 bug（可跑 `python3 -m unittest tests.test_cua_router` 排查）

### 修复

```bash
python3 -m unittest tests.test_cua_router -v
# 若 wraps_code_in_block_scope / wrap_keeps_repeated_const_declarations 挂 → 说明 wrap 逻辑变了
```

## 8. HTTP 端口冲突

### 判定

```bash
lsof -i :18901
```

若有别的进程占：
- 换端口：`CUA_ROUTER_PORT=18902 bash scripts/daemon.sh start`
- 或 kill 占端口的进程

## 9. daemon.sh start 卡住 / 超时

### 排查

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-$HOME/.automan/claude-code-agents/cua-agent/skills/cua-router-basic}"
tail -100 "$SKILL_ROOT/runtime/cua-router.log"
tail -100 "$SKILL_ROOT/runtime/cua-router-app-server-18901.log"
launchctl print "gui/$(id -u)/com.meituan.cua-router.app-server.18901"
curl -sf http://127.0.0.1:18902/readyz
```

关注：
- launchd job 是否为 `state = running`。
- `[app-server] connecting to bundled launchd app-server: ws://127.0.0.1:18902` → router 正在连接签名 app-server。
- `[app-server] ready, threadId=...` → JSON-RPC 初始化完成。
- `[app-server] node_repl ready` → MCP server bootstrap 完成。

若卡在 WebSocket 握手：
- 检查 `<runtime>/app-server.token` 是否存在且权限为 `0600`。
- 检查 app-server 与 router 的 `CUA_ROUTER_APP_SERVER_PORT` 是否一致。
- `403 Forbidden` 且日志出现 `rejecting ... Origin header` 时，客户端必须不发送 `Origin`；内置 `WebSocketTransport` 已按此约束实现。
- `Sec-WebSocket-Accept` 校验必须大小写无关地比较 header，不能把服务端合法大小写当成失败。

若卡在 `[app-server] initialize timeout`：
- codex 版本可能不兼容当前 `cua-router.py` 的 JSON-RPC 协议。
- vendor 可能缺失或不完整；重新下载/安装 vendor 后重试。

若卡在 `node_repl ready` 之前：
- `NODE_REPL_NODE_MODULE_DIRS` 环境未传对；检查 `vendor/cua_node` 结构。

## 10. 录制约 35 秒超时

### 典型原因

启动流程自动执行了 deep readiness，`node_repl` 通过 `sky.list_apps()` 抢占 `SkyComputerUseService` 的唯一事件观察者连接。随后 `event_stream_start` 无法获得录制观察者，最终超时。

### 判定与修复

```bash
# 起录前只做浅健康检查
curl -s http://127.0.0.1:18901/health | python3 -m json.tool

# 不要在起录前调用 /ready 深探针
CUA_ROUTER_START_READINESS=off bash scripts/daemon.sh restart
```

- `daemon.sh` 当前默认 `CUA_ROUTER_START_READINESS=off`。
- 不要在录制前手工调用 `/ready`、`sky.list_apps()` 或其他 Sky 深探针。
- 超时重试无效；必须释放旧观察者并按正确顺序重启。

## 11. 录制返回 `Computer Use server error -1743`

### 含义

`-1743` 是 macOS `errAEEventNotPermitted`。在该链路中通常表示 Sky IPC 认为请求来自不可信 relay，而不只是“辅助功能没勾选”。

错误拓扑：

```text
python cua-router（未签名） → vendor codex（已签名） → Sky client（已签名）
```

即使两个子进程签名有效，未签名 Python 祖先仍可能触发 `UNTRUSTED_PARENT` 或 `RELAY_WITHOUT_TRUSTED_ANCESTOR`。

### 修复

```bash
# 必须走 daemon.sh，让 launchd 直接托管签名 vendor codex
bash scripts/daemon.sh restart

# 验证 app-server 的 launchd job
launchctl print "gui/$(id -u)/com.meituan.cua-router.app-server.18901"

# 验证真实录制，不以 /health 代替
bash record-desk-basic/scripts/event-stream.sh start
bash record-desk-basic/scripts/event-stream.sh status
bash record-desk-basic/scripts/event-stream.sh stop
```

禁止以下规避方案：

- 直接运行 `python3 scripts/cua-router.py` 作为录制生产链路。
- 复用本地 ChatGPT/Codex Desktop app-server 或 `~/.codex/ipc`。
- 使用要求额外 standalone 安装的 `codex app-server daemon bootstrap`。
- 仅通过重复授权、超时重试或回退 v0.4.17/v0.4.18 处理。

详细 RCA 见 `record-desk-basic/references/recording-architecture.md`。

## 12. 缓存诊断三件套

任何"结果不对但不知道哪儿错"时先跑：

```js
{
  const s1 = ax._stats();
  ax.invalidate();
  const s2 = ax._stats();  // cacheSize=0, invalidations 增加
  const state = await ax.get("com.google.Chrome", { refresh: true });
  const s3 = ax._stats();
  nodeRepl.write(JSON.stringify({
    before: s1,
    afterInvalidate: s2,
    afterRefresh: s3,
    textLen: state.text.length,
  }));
}
```

组合结果分析：
- `before.hitRate` 异常高 + `entries[].ageMs` 很老 → 缓存陈旧
- refresh 后 `textLen` 与之前差异大 → 确认是陈旧
- refresh 后依然错 → 不是缓存问题，看 sky 层

## 13. 快速健康检查一条龙

新装环境或改动后跑一遍：

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-$HOME/.automan/claude-code-agents/cua-agent/skills/cua-router-basic}"

# 1. 服务在线
bash "$SKILL_ROOT/scripts/daemon.sh" status

# 2. 浅健康检查；准备录制时不要先跑 /ready 深探针
curl -s http://127.0.0.1:18901/health | python3 -m json.tool

# 3. ax API 完整（该调用会初始化 Sky；不要紧接着用同一运行态起录）
bash "$SKILL_ROOT/scripts/exec.sh" \
  'nodeRepl.write("ax=" + typeof ax + ";keys=" + Object.keys(ax).join(","))'

# 4. 单元测试
node --test "$SKILL_ROOT/tests/test_computer_use_client.mjs"

# 5. 端到端（需 Chrome 可见窗口）
bash "$SKILL_ROOT/scripts/exec.sh" -t 30000 '{
  const app = "com.google.Chrome";
  const s = await ax.get(app);
  await sky.press_key({ app, key: "Escape" });
  const s2 = await ax.get(app);
  nodeRepl.write(JSON.stringify({
    firstLen: s.text.length,
    afterEscapeLen: s2.text.length,
    invalidated: s !== s2,
  }));
}'
```

任何一步出错，参考本文档对应章节。
