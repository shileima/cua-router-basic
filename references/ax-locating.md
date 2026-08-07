# AX Tree 元素定位与弹层处理

## 基础规则

- 定位必须基于**完整 AX 快照**：使用 `ax.get(app)`（内部固定 `disableDiff:true`，跨 `/exec` 缓存）。
- 搜索范围必须是完整 `s.text`，禁止按 idx 区间切片。
- 每次 `sky.click / set_value / press_key / scroll / type_text` 后，对应 app 的缓存会**自动失效**；下一次 `ax.get(app)` 会重新拉。
- 外部触发（`swift + CoreGraphics`、AppleScript、手动移鼠标）不会走 sky wrapper，必须 `ax.get(app, { refresh: true })` 或 `ax.invalidate(app)` 手动刷新。
- 弹层、Modal、Portal 常出现在高 idx；idx 大不代表不重要。

## 内置 helpers（bootstrap 后已挂到 `globalThis.ax`）

| helper | 用途 |
|---|---|
| `ax.get(app, { refresh, maxAgeMs })` | 拿完整快照；命中缓存则不发新请求 |
| `ax.invalidate(app?)` | 手动失效指定 app 或全部缓存 |
| `ax.findIdx(text, ...kw)` | 首个匹配行的 `element_index` |
| `ax.findAllIdx(text, ...kw)` | 所有匹配的 `{ idx, line }` |
| `ax.findFocusedIdx(text)` | 当前焦点元素 idx |
| `ax.linesMatching(text, pattern, {limit})` | 字符串或正则筛出的原始行 |
| `ax.summarize(state, opts)` | 输出前收敛，避免整树回传 |
| `ax._stats()` | 调试：命中率、每个 app 缓存年龄 |
| `ax._resetStats()` | 调试：归零计数 |

无需在每段业务代码里重新定义 `findIdx / findAllIdx / findFocusedIdx`。

### `ax.get` 的三种取树策略

| 场景 | 写法 | 语义 |
|---|---|---|
| 正常业务（有明确 sky 交互） | `ax.get(app)` | 无交互命中缓存；`sky.*` 后自动失效 |
| 外部触发已知（swift / AppleScript / 手动） | `ax.get(app, { refresh: true })` | 强制重取 |
| 轮询等待异步 UI 更新（SSE / stream / 无限滚动） | `ax.get(app, { maxAgeMs: 300 })` | 缓存年龄 ≥ 300ms 自动重取 |

`maxAgeMs: 0` 语义 = 强制刷新，等价于 `refresh: true`。

## 弹层定位流程（一次取树 + 多次搜索）

```js
{
  const s = await ax.get("com.google.Chrome");
  const focusedIdx = ax.findFocusedIdx(s.text);
  const overlayIdx =
    ax.findIdx(s.text, "确定", "按钮") ??
    ax.findIdx(s.text, "关闭", "按钮");
  const candidates = ["dialog", "Dialog", "alert", "Modal", "弹窗", "浮层", "sheet"]
    .flatMap((kw) => ax.findAllIdx(s.text, kw))
    .filter((c, i, arr) => arr.findIndex((x) => x.idx === c.idx) === i)
    .slice(0, 15);

  nodeRepl.write(
    JSON.stringify({ textLen: s.text.length, focusedIdx, overlayIdx, candidates })
  );
}
```

要点：整段只调一次 `ax.get`，多个 `findIdx / findAllIdx` 共享同一份 `s.text`。

## 场景：轮询等待异步 UI 更新（工作流跑动 / SSE / stream / 无限滚动）

**风险**：页面 JS 自身触发的 UI 变化（RPA 工作流跑动、AI 对话 stream、SSE 推送、异步日志追加、上传进度）**不经过 sky wrapper**，AX 缓存不会自动失效。用普通 `ax.get(app)` 轮询会一直命中启动瞬间的旧树，看不到进展。

**实测证据（RPA 工作流调试页面 6 次 × 1.2s 轮询）**：

| 写法 | 6 次 textLen 观测 | 真调用次数 | 结果 |
|---|---|---|---|
| `ax.get(app)` | 10424 × 6（**卡死在初始态**） | 1 | ❌ 拿到陈旧树 |
| `ax.get(app, { refresh: true })` | 每次最新 | 6 | ✅ |
| `ax.get(app, { maxAgeMs: 300 })` | 每次最新 | 6 | ✅ 语义更清晰 |

**标准模板**：等待某个"完成"标志出现，超时兜底。

```js
{
  const app = "com.google.Chrome";
  const DEADLINE_MS = 30000;
  const POLL_INTERVAL_MS = 1000;
  const start = Date.now();
  let done = false;
  let lastLen = 0;

  while (Date.now() - start < DEADLINE_MS) {
    const s = await ax.get(app, { maxAgeMs: 300 });
    lastLen = s.text.length;

    // 成功标志
    if (
      ax.findIdx(s.text, "运行完成") ??
      ax.findIdx(s.text, "执行成功") ??
      ax.findIdx(s.text, "已完成")
    ) {
      done = true;
      break;
    }
    // 失败标志（快速失败，别把 30 秒等完）
    if (
      ax.findIdx(s.text, "执行失败") ??
      ax.findIdx(s.text, "运行错误")
    ) {
      break;
    }

    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }

  nodeRepl.write(JSON.stringify({
    done,
    elapsedMs: Date.now() - start,
    lastLen,
    stats: ax._stats(),
  }));
}
```

要点：
- 只用 `maxAgeMs: 300`，不用 `refresh: true` —— 前者在同一轮询周期内多个 `findIdx` 复用同一份树，一次 RPC 找多个标志；后者会强制每次 `ax.get` 都真调用（浪费）。
- 循环里**只调一次 `ax.get`**，多个 `findIdx` 复用 `s.text`。
- 不要漏成功标志之外的失败标志，否则会等满超时。
- 结束后打 `ax._stats()` 便于排查（应看到 `staleMisses` 累加、`hits` 极少）。

## AX → hover → OCR → 坐标扫描四级降级

当目标视觉可见但 AX 不暴露时，必须按顺序降级：

1. AX Tree 定位：`ax.findFocusedIdx` / `ax.findIdx` / `ax.findAllIdx`。
2. hover 触发隐藏控件：详见 `references/hover-menu.md`。
3. 截图 OCR 定位：用 `s.screenshot.url` + macOS Vision/OCR 定位。
4. 固定坐标扫描：使用预先校准的一组候选坐标。
5. 每次尝试后 `ax.get(app, { refresh: true })` 验证；hover / swift 等外部交互必须显式 refresh。

返回日志建议：

```json
{
  "successAttempt": "ax:<label> | hover-menu:<hoverX>,<hoverY>-><menuX>,<menuY> | ocr:<text>@<x>,<y> | coord-scan:<x>,<y>",
  "successX": 344,
  "successY": 393,
  "strategy": "ax | hover-menu | ocr | coord-scan"
}
```
