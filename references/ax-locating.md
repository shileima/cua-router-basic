# AX Tree 元素定位与弹层处理

## 基础规则

- 解析 AX Tree 必须使用 `get_app_state({ disableDiff: true })`。
- 搜索范围必须是完整 `s.text`，禁止按 idx 区间切片。
- 每次 click / set_value / press_key 后必须重新取状态验证。
- 弹层、Modal、Portal 常出现在高 idx；idx 大不代表不重要。

## 辅助函数

```js
function findIdx(axText, ...keywords) {
  const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
  if (!line) return null;
  return parseInt(line.match(/^\s*(\d+)/)[1]);
}

function findAllIdx(axText, ...keywords) {
  return axText.split("\n")
    .filter(l => keywords.every(k => l.includes(k)))
    .map(l => ({ idx: parseInt(l.match(/^\s*(\d+)/)[1]), line: l.trim() }));
}

function findFocusedIdx(axText) {
  const line = axText.split("\n").find(l => /focused UI element is/.test(l));
  return line ? parseInt(line.match(/\b(\d+)\b/)?.[1]) : null;
}
```

## 弹层定位流程

```js
{
  function findIdx(axText, ...keywords) {
    const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
    if (!line) return null;
    return parseInt(line.match(/^\s*(\d+)/)[1]);
  }
  function findAllIdx(axText, ...keywords) {
    return axText.split("\n")
      .filter(l => keywords.every(k => l.includes(k)))
      .map(l => ({ idx: parseInt(l.match(/^\s*(\d+)/)[1]), line: l.trim() }));
  }
  function findFocusedIdx(axText) {
    const line = axText.split("\n").find(l => /focused UI element is/.test(l));
    return line ? parseInt(line.match(/\b(\d+)\b/)?.[1]) : null;
  }

  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const focusedIdx = findFocusedIdx(s.text);
  const overlayIdx = findIdx(s.text, "确定", "按钮") ?? findIdx(s.text, "关闭", "按钮");
  const candidates = ["dialog", "Dialog", "alert", "Modal", "弹窗", "浮层", "sheet"]
    .flatMap(kw => findAllIdx(s.text, kw))
    .filter((c, i, arr) => arr.findIndex(x => x.idx === c.idx) === i)
    .slice(0, 15);

  nodeRepl.write(JSON.stringify({ textLen: s.text.length, focusedIdx, overlayIdx, candidates }));
}
```

## AX → hover → OCR → 坐标扫描四级降级

当目标视觉可见但 AX 不暴露时，必须按顺序降级：

1. AX Tree 定位：`findFocusedIdx` / `findIdx` / `findAllIdx`。
2. hover 触发隐藏控件：详见 `references/hover-menu.md`。
3. 截图 OCR 定位：用 `s.screenshot.url` + macOS Vision/OCR 定位。
4. 固定坐标扫描：使用预先校准的一组候选坐标。
5. 每次尝试后重新取 AX Tree 验证。

返回日志建议：

```json
{
  "successAttempt": "ax:<label> | hover-menu:<hoverX>,<hoverY>-><menuX>,<menuY> | ocr:<text>@<x>,<y> | coord-scan:<x>,<y>",
  "successX": 344,
  "successY": 393,
  "strategy": "ax | hover-menu | ocr | coord-scan"
}
```
