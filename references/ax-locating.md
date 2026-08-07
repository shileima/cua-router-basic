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
| `ax.get(app, { refresh })` | 拿完整快照；命中缓存则不发新请求 |
| `ax.invalidate(app?)` | 手动失效指定 app 或全部缓存 |
| `ax.findIdx(text, ...kw)` | 首个匹配行的 `element_index` |
| `ax.findAllIdx(text, ...kw)` | 所有匹配的 `{ idx, line }` |
| `ax.findFocusedIdx(text)` | 当前焦点元素 idx |
| `ax.linesMatching(text, pattern, {limit})` | 字符串或正则筛出的原始行 |
| `ax.summarize(state, opts)` | 输出前收敛，避免整树回传 |

无需在每段业务代码里重新定义 `findIdx / findAllIdx / findFocusedIdx`。

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
