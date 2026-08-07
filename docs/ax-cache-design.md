# AX 缓存策略设计

本文档描述 `scripts/computer-use-client.mjs` 中 `globalThis.ax` + sky wrapper 的设计原理、语义边界、修改 checklist。

## 为什么要有缓存

`sky.get_app_state({ app, disableDiff: true })` 对 Chrome / 复杂应用返回**完整 AX Tree**（数百 KB 文本 + 数千行），一次调用耗时 100–300ms。

在 skill 的核心操作规范里，"每次交互后重新取树验证"和"在完整 text 上 findIdx"是**正确性红线**——退回 diff 模式会让 `findIdx` 漏找、`element_index` 错位。所以只能保留完整快照，但可以减少**物理调用次数**：

- 同一 UI 状态下多次 `findIdx` 复用同一份 `s.text`
- 相邻 `/exec` 命令若未做交互，缓存命中

## 核心不变量

必须始终成立，任何改动前先自查：

1. **完整快照语义**：`ax.get(app)` 内部总是传 `disableDiff:true`。禁止让调用方能"降级为 diff"以求性能。
2. **交互后必失效**：任何 `sky.*` mutation 方法执行完成后（无论成功失败），对应 app 缓存立即失效。这条比"少发调用"优先级更高。
3. **`app` 是主 key**：缓存粒度是"每个应用一份最新完整快照"，不做多版本 / 多快照。
4. **`globalThis` 存活周期**：缓存生命周期 = node_repl 进程生命周期。daemon 重启即清空。
5. **无隐式过期**：不加默认 TTL；调用方明确知道自己是"轮询异步"场景时才传 `maxAgeMs`。

## 数据结构

```js
globalThis[Symbol.for("openai.computer-use.ax-cache")]
// = Map<string /* app bundle id */, { state: SkyState, fetchedAt: number }>

globalThis[Symbol.for("openai.computer-use.ax-stats")]
// = { hits, misses, staleMisses, refreshes, invalidations }

globalThis[Symbol.for("openai.computer-use.ax-helpers")]
// = Object.freeze({ get, invalidate, findIdx, findAllIdx,
//                   findFocusedIdx, linesMatching, summarize,
//                   _stats, _resetStats })
```

`Symbol.for()` 保证跨模块导入拿到同一份缓存。

## `ax.get(app, opts)` 决策路径

```
输入: app, { refresh?, maxAgeMs? }
        │
        ▼
参数校验 (typeof app === "string" && app !== "")
        │
        ▼
读取 cache.get(app) → entry
        │
   ┌────┴────┐
   │refresh? │─── true ───→ stats.refreshes++, 真调用
   └────┬────┘
        │ false
        ▼
   entry == null ? ─── true ───→ stats.misses++, 真调用
        │
        │ false
        ▼
   maxAgeMs 给了 && age >= maxAgeMs ? ─── true ─→ stats.staleMisses++, 真调用
        │
        │ false
        ▼
   stats.hits++, 返回 entry.state
```

关键规则：
- `age >= maxAgeMs` 判定为陈旧（**大等号**）。因此 `maxAgeMs: 0` 语义 = "永远陈旧" = 强制刷新，等价于 `refresh: true`。这对齐 HTTP `Cache-Control: max-age=0` 语义。
- 真调用后写入 `{ state, fetchedAt: Date.now() }`，**不修改 stats**（stats 已在决策路径上更新）。

## `wrapSkyClient(sky)` 白名单

必须两类同步维护：

### 1. mutation 白名单（自动失效缓存）

```js
const AX_MUTATING_METHODS = Object.freeze([
  "click", "double_click", "right_click", "drag", "scroll",
  "set_value", "type_text", "key_down", "key_up",
  "hover", "mouse_move",
]);
```

+ `press_key`：单独处理（附带 `normalizePressKey`）。
+ `get_app_state`：单独处理（`disableDiff:true` 时回填缓存）。

wrap 方式：`Promise.resolve(bound(input, ...rest)).finally(() => invalidateAxCache(input?.app ?? null))`。

- **成功/失败都失效**：即便 sky 抛错，UI 也可能已部分变化，宁可白发一次 RPC 也不能拿到陈旧树。
- **`input?.app ?? null`**：坐标点击若无 app 传 null → `invalidateAxCache(null)` 全清全部缓存。**当前实际情况**：sky 原生要求 `sky.click` 必传 `app`（"app must be a plain data property"），所以"无 app 全清"是防御性代码，很少触发。

### 2. `sky.get_app_state` wrapper 回填

```js
async get_app_state(input, ...rest) {
  const state = await originalGetAppState(input, ...rest);
  if (input && typeof input.app === "string" && input.disableDiff === true) {
    writeCacheEntry(input.app, state);
  }
  return state;
}
```

- 只有严格 `disableDiff === true` 才回填 —— diff 结果不能作为完整快照，否则会污染缓存。
- 让**用户手写 `sky.get_app_state({app, disableDiff:true})` 与 `ax.get(app)` 共用同一份缓存**，两种写法可自由混用不重复调用。

## 三种取树策略（对使用方）

| 场景 | 写法 | 内部行为 |
|---|---|---|
| 主线（sky 交互 → 取树验证） | `ax.get(app)` | 无 maxAgeMs → 有缓存必命中 |
| 已知外部触发（swift/AppleScript/手动） | `ax.get(app, { refresh: true })` | 强制真调用 |
| 轮询异步 UI（工作流跑动/SSE/stream） | `ax.get(app, { maxAgeMs: 300 })` | age ≥ 300ms 真调用 |
| 完全不确定 | `ax.get(app, { maxAgeMs: 500 })` | 安全默认 |

**禁止**：把 `maxAgeMs` 变成 `ax.get` 的默认值。当前默认无 TTL 是主线场景的最优权衡；加默认 TTL 会掩盖 wrapper 自动失效的效果，反而增加错位风险。

## 调试接口

- `ax._stats()`：`{ hits, misses, staleMisses, refreshes, invalidations, hitRate, cacheSize, entries: [{app, ageMs, fetchedAt, textLen}] }`
- `ax._resetStats()`：归零计数（不清缓存）
- `ax.invalidate(app?)`：清缓存

排查"拿到陈旧树"的 SOP：
1. `ax.invalidate()` 全清 + 重试。**结果不同 → 确认是缓存陈旧问题**（回到"外部交互没 refresh"或"新 sky 方法没进白名单"）。
2. `ax._stats()` 观察 `hits` 是否异常高、`entries[].ageMs` 是否远大于 UI 变化间隔。
3. 精确到具体调用点：在业务代码里插 `console.log(ax._stats())` 或 `nodeRepl.write(JSON.stringify(ax._stats()))`。

## 修改 checklist

改动 `computer-use-client.mjs` 前必查：

### 增加一个 sky 交互方法（如 sky 新增 `swipe`）

- [ ] 加进 `AX_MUTATING_METHODS`（若无特殊参数处理）
- [ ] 或单独 wrap（若需要参数归一化，参考 `press_key`）
- [ ] 补 Node 测试：`wrapSkyClient: <name> 后 ax 缓存自动失效`
- [ ] 若该方法涉及新参数（比如 `pinch` 有 scale/center 字段），确认 `input?.app` 依然能读到

### 新增只读 sky 方法（如 `list_windows`）

- **不 wrap 即可**。原生方法通过 `{ ...sky, ...overrides }` 透传。
- 只读方法不改变 AX 树，不能失效缓存。

### 修改 `ax.get` 决策路径

- [ ] `age >= maxAgeMs` 的 `>=` 不能改成 `>`（否则 `maxAgeMs:0` 失去"强制刷新"语义）
- [ ] `refresh:true` 的分支必须在 `entry != null && !stale` 之前判断
- [ ] `getAxStats()` 的 4 类计数（hits / misses / staleMisses / refreshes）在每条决策路径上必须**恰好加一次**
- [ ] 补测试覆盖新分支

### 修改 `wrapSkyClient` 白名单

- [ ] 增加方法 → 补测试证明"调用后 ax 缓存失效"
- [ ] 删除方法 → 必须评估：这方法真的不 mutate 吗？还是只是暂时用不到？
- [ ] `Object.freeze` 后不能再改 wrapped 对象，测试要在 freeze 前完成 mock

### 修改 `Symbol.for` 键名

- ❌ **强烈不建议**。会造成缓存不共享（如果同时有旧版和新版代码在同一 node_repl 里跑）。若必须改，必须同时清所有旧 Symbol：`Reflect.set(globalThis, oldKey, undefined)`。

## 常见反模式

| 反模式 | 后果 | 正确做法 |
|---|---|---|
| 在 `/exec` 代码里手写 `findIdx / findAllIdx` 定义 | 每次代码块重复 20+ 行 | 直接用 `ax.findIdx` |
| 用普通 `ax.get(app)` 做轮询等待异步更新 | 命中缓存 → 卡在初始态 | `ax.get(app, {maxAgeMs:300})` |
| `sky.get_app_state({app})`（漏 `disableDiff`） | 返回 diff、不回填缓存、findIdx 漏找 | 一律用 `ax.get(app)` |
| `sky.get_app_state({disableDiff:true})`（漏 `app`） | sky 抛 `app must be a plain data property` | `ax.get(app)`（结构上不能漏） |
| 手动清缓存 `globalThis[Symbol.for("...")].clear()` | 绕过 stats 计数、易忘 | `ax.invalidate()` |
| 加默认 TTL 到 `ax.get` | 掩盖 wrapper 自动失效效果、增加错位风险 | 保持"显式传 maxAgeMs"约定 |
| 把 `sky.get_app_state` 强制成 `disableDiff:true` | 破坏调用方对 diff 语义的知情权 | 让调用方自选，只在 true 时回填 |

## 性能基线（0.4.9-beta.2 实测）

RPA 工作流页面 6 次 × 1200ms 轮询：

| 写法 | RPC 数 | textLen 观测 |
|---|---|---|
| `ax.get(app)` | 1 | 10424 × 6（陷入缓存陈旧） |
| `ax.get(app, { refresh: true })` | 6 | 每次最新 |
| `ax.get(app, { maxAgeMs: 300 })` | 6 | 每次最新 |

单元测试 23 用例见 `tests/test_computer_use_client.mjs`，覆盖：normalizePressKey、find* helpers、summarize、缓存命中 / 失效 / TTL / refresh 优先级 / mutation wrapper / 坐标点击 / 失败失效 / stats 计数 / entries 携带 ageMs。
