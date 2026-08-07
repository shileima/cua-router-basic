# Canvas / 流程图节点双击

Canvas 节点外层常是 `container`，父层可能是 `contenteditable`。直接双击 container 容易被文本选中消费，React `onDoubleClick` 不触发。

## 标准流程

1. `press_key("Escape")` 退出 contenteditable 文本编辑/光标模式。
2. 等待约 600ms。
3. 对节点内部 `文本` / `未加标签的图片` 子元素执行 `click({ click_count: 2 })`。

## 关键规则

- 必须先 Escape。
- 参数名必须是 `click_count`，不是 `clickCount`。
- 双击目标是节点内部子元素，不是外层 container。
- 双击后重新 `ax.get(app)` 验证配置面板是否出现（wrapper 已自动失效缓存，直接 `ax.get` 即可拿到新树）。

## 标准代码模板

```js
{
  function findNodeDblClickTarget(axText, nodeLabel) {
    const exact = axText.split("\n").find((l) =>
      new RegExp(`^\\s+\\d+\\s+文本\\s+${nodeLabel}\\b`).test(l)
    );
    if (exact) return parseInt(exact.match(/^\s*(\d+)/)[1]);
    return ax.findIdx(axText, "未加标签的图片");
  }

  await sky.press_key({ app: "com.google.Chrome", key: "Escape" });
  await new Promise((r) => setTimeout(r, 600));

  const s = await ax.get("com.google.Chrome");
  const targetIdx =
    findNodeDblClickTarget(s.text, "3") ??
    ax.findIdx(s.text, "文本", "3") ??
    ax.findIdx(s.text, "未加标签的图片");

  if (!targetIdx) {
    nodeRepl.write(JSON.stringify({ error: "node dblclick target not found" }));
  } else {
    await sky.click({ app: "com.google.Chrome", element_index: targetIdx, click_count: 2 });
    await new Promise((r) => setTimeout(r, 1500));
    const s2 = await ax.get("com.google.Chrome");
    const panelLines = ax.linesMatching(
      s2.text,
      /(LLM|属性定义|捕获|新建).*(按钮|文本栏)/,
      { limit: 10 }
    );
    nodeRepl.write(
      JSON.stringify({
        dblclickTarget: targetIdx,
        panelOpened: panelLines.length > 0,
        panelLines,
      })
    );
  }
}
```

要点：
- `press_key` 后 wrapper 自动失效缓存，随后的 `ax.get` 是真调用。
- 双击 `sky.click` 同样失效缓存，`s2 = await ax.get(...)` 也是真调用。
- 中间两次 `findIdx` 都复用同一份 `s.text` / `s2.text`，不重复取树。

## 禁止做法

```js
await sky.click({ app: "com.google.Chrome", element_index: 284, clickCount: 2 });
await sky.click({ app: "com.google.Chrome", element_index: 57, click_count: 2 });
await sky.click({ app: "com.google.Chrome", x: 560, y: 360, click_count: 2 });
```
