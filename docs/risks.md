# 已知风险清单与复现方法

改动 `computer-use-client.mjs` / vendor / 发新版前，先自查本清单是否有影响。线上出问题时按此排查。

## 风险分类总表

| 编号 | 类型 | 严重度 | 是否已缓解 |
|---|---|---|---|
| R1.1 | 外部交互后忘 refresh（页面自身异步更新） | 🟡 中 | 部分（提供 `maxAgeMs`、`refresh:true` + 文档规范） |
| R1.2 | sky mutation 白名单不全 | 🟡 中 | 靠维护纪律；见 [checklist](./ax-cache-design.md#修改-checklist) |
| R1.3 | 同 app 并发 `ax.get` in-flight 未去重 | 🟢 低 | 未做，仅浪费一次 RPC |
| R1.4 | mutation 后 UI 动画未收敛就取树 | 🟢 低 | 沿用旧规则 `await sleep(400~1500)` |
| R2.1 | `sky.get_app_state` 结果类型严格相等 | 🟢 低 | 保守，是特性不是 bug |
| R2.2 | 调用失败也失效缓存 | 🟢 低 | 只影响性能，不影响正确性 |
| R2.3 | diff 模式结果不回填 | 🟢 低 | 特意保守，防污染 |
| R3.1 | node_repl 单实例，globalThis 共享 → 多 agent 并发不安全 | 🟠 中偏高（未来场景） | 未做，当前单 agent 用不触发 |
| R4.1 | 缓存无 TTL 无 LRU 上限 | 🟢 低 | 常见 1–2 个 app，可忽略 |
| R5.1 | 调试路径变长（多了缓存这层） | 🟢 低 | 提供 `ax._stats()` |
| R6.1 | 改 mjs 忘 daemon restart | 🟡 中 | 文档强调；未加 mtime 检测 |
| R6.2 | vendor 升级后 wrapper 白名单可能过时 | 🟡 中 | 见 [`sky-and-vendor-sync.md`](./sky-and-vendor-sync.md) |

## 详细：R1.1 外部交互后忘 refresh

**触发场景**：任何不经过 `sky.*` wrapper 的 UI 变化。

| 子场景 | 举例 | 频率 |
|---|---|---|
| 系统级鼠标/键盘 | `swift + CoreGraphics`、AppleScript、`cliclick` | 中（hover 模板会用） |
| 页面自身异步 | RPA 工作流跑动、AI 对话 stream、SSE、SPA 路由切换 | **高** |
| 其他应用抢焦点 | 系统通知、Spotlight、切工作区 | 低 |
| 用户人肉操作 | 开发时手动动鼠标 | 中 |
| macOS 动画收敛 | 弹窗 fade、菜单展开、Tooltip 消失 | 低 |

**后果**：AX 缓存陷入交互瞬间的旧树。`findIdx / findFocusedIdx` 用错位 idx，导致 `sky.click({element_index: N})` 打空或点错。

**已缓解**：
- 提供 `ax.get(app, { refresh: true })` 显式强制刷新
- 提供 `ax.get(app, { maxAgeMs: N })` 兜底 TTL
- 文档在 `SKILL.md` / `references/ax-locating.md` 强调"轮询/外部交互"必须显式刷新
- `references/hover-menu.md` 里模板保留 `{ refresh: true }` 双保险

**未缓解**：本质上是使用纪律，忘了还是踩坑。

### 复现方法

#### 场景 A：页面自身异步更新（工作流跑动）

前置：Chrome 打开一个 UI 会自己变的页面（RPA 工作流调试 / ChatGPT / SSE demo）并让它正在跑。

```js
{
  const app = "com.google.Chrome";
  ax._resetStats(); ax.invalidate();

  const A = [];
  for (let i = 0; i < 6; i++) {
    const s = await ax.get(app);   // ⚠️ 无交互 → 只有第 1 次真调用
    A.push({ i, textLen: s.text.length });
    await new Promise(r => setTimeout(r, 1200));
  }

  ax.invalidate();
  const B = [];
  for (let i = 0; i < 6; i++) {
    const s = await ax.get(app, { refresh: true });
    B.push({ i, textLen: s.text.length });
    await new Promise(r => setTimeout(r, 1200));
  }

  nodeRepl.write(JSON.stringify({ A_stale: A, B_fresh: B, stats: ax._stats() }, null, 2));
}
```

**判定**：A 组 6 次 textLen 完全一样 → 复现成功；B 组 textLen 变化 → 兜底方案有效。

#### 场景 B：swift 移鼠标后不 click 直接取树

```bash
# 先取一次建立缓存
bash exec.sh '(async () => { await ax.get("com.google.Chrome"); nodeRepl.write("cached"); })()'

# 外部触发 hover
swift -e 'import CoreGraphics; import Foundation; let p = CGPoint(x: 360, y: 210); if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) { e.post(tap: .cghidEventTap) }; Thread.sleep(forTimeInterval: 1.2)'

# 不 click，直接取树 —— 命中缓存看不到浮层
bash exec.sh '{
  const s1 = await ax.get("com.google.Chrome");
  const cached = ax.linesMatching(s1.text, /启用中|创建副本/, {limit:5}).length;
  const s2 = await ax.get("com.google.Chrome", { refresh: true });
  const fresh = ax.linesMatching(s2.text, /启用中|创建副本/, {limit:5}).length;
  nodeRepl.write(JSON.stringify({ cached, fresh }));
}'
```

**判定**：`cached === 0 && fresh > 0` → 复现成功。

## R1.2 sky mutation 白名单不全

**触发**：sky 版本升级后新增了一个改变 UI 的方法（比如假设的 `swipe / pinch`），但 `AX_MUTATING_METHODS` 没更新。

**后果**：调用后缓存不失效 → 后续 `ax.get(app)` 拿旧树。

**已缓解**：无自动机制。

**缓解流程**（vendor 升级时执行）：
1. 对比新旧 sky module 的导出方法（`vendor/cua_node/lib/node_modules/@oai/sky/dist/.../index.d.ts` 或 `create_client.js`）
2. 新增的方法根据其是否 mutate 决定：
   - 改变 UI（click 类、input 类、focus 类）→ 加进 `AX_MUTATING_METHODS`
   - 只读（list / query / get）→ 不管
3. 补对应单元测试

详见 [`sky-and-vendor-sync.md`](./sky-and-vendor-sync.md)。

## R3.1 多 agent 并发共享 globalThis

**触发**：多个 agent 客户端同时打 `/exec` 到同一 cua-router。

**后果**：
- Agent A 刚 `ax.get(app)` 建缓存
- Agent B `sky.click({app})` 改 UI 并失效缓存
- 或反过来 A 的操作让 B 的 `ax.get` 拿到 A 的操作后结果
- 结果：**跨 agent 干扰**，AX 缓存/失效被误伤

**已缓解**：无。当前设计假设单 agent。

**未来缓解思路**：
- 按 threadId / requestId 分租户缓存
- 或者每次 `/exec` 之前显式 `ax.invalidate()`（性能损失但安全）

**当前实际影响**：cua-router 通常 1 个客户端连接，问题不显。多客户端场景需谨慎评估。

## R6.1 改 mjs 忘 daemon restart

**触发**：改完 `computer-use-client.mjs` 直接跑 `exec.sh`。

**后果**：node_repl 沿用旧 bootstrap，改动完全不生效。可能表现为 `ax is undefined`、`ax.get is not a function`、老函数继续跑等。

**已缓解**：
- `references/runtime-exec.md` 明确"修改 mjs 后需 daemon.sh restart"
- `docs/README.md` 顶部提示

**未缓解**：无自动检测。

**改进思路**：`daemon.sh start` 可以检测 mjs mtime 与 pid 记录里的启动时间，如果 mjs 更新更晚，自动 restart。约 15 行 bash。

## R6.2 vendor 升级后 wrapper 过时

见 [`sky-and-vendor-sync.md`](./sky-and-vendor-sync.md)。

## 快速自检（改动前必读）

改 `computer-use-client.mjs`：
- [ ] 新增 sky 方法 → 判断是否 mutate → 是则进白名单
- [ ] 改 `ax.get` 决策路径 → `age >= maxAgeMs`、refresh 优先级不能动
- [ ] `Symbol.for` 键名不改
- [ ] 补对应单元测试
- [ ] 本地 `daemon.sh restart` 验证 `typeof ax === "object"`

改 vendor：
- [ ] 对比 sky 导出方法差异
- [ ] 更新 `AX_MUTATING_METHODS` 白名单
- [ ] 重跑 `bash exec.sh` 常规模板，看是否有报错
- [ ] 更新 `vendor/manifest.json` sha256

改 `cua-router.py`：
- [ ] `SKY_BOOTSTRAP` / `SKY_READINESS_PROBE` 中的 `nodeRepl.write` 输出格式与外部依赖保持一致
- [ ] `wrap_js_for_repl` 若变，同步更新 `tests/test_cua_router.py`

发新版：
- [ ] 4 处 JSON 版本号同步（见 [`release-workflow.md`](./release-workflow.md)）
- [ ] `daemon.sh restart` 后验证 `typeof ax`、`ax._stats()`
- [ ] 至少跑一次跨交互 end-to-end 测试
