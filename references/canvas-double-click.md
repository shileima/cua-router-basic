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
- 双击后重新 `get_app_state({ disableDiff:true })` 验证配置面板是否出现。

## 标准代码模板

```js
{
  function findIdx(axText, ...keywords) {
    const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
    if (!line) return null;
    return parseInt(line.match(/^\s*(\d+)/)[1]);
  }
  function findNodeDblClickTarget(axText, nodeLabel) {
    const exact = axText.split("\n").find(l =>
      new RegExp(`^\\s+\\d+\\s+文本\\s+${nodeLabel}\\b`).test(l)
    );
    if (exact) return parseInt(exact.match(/^\s*(\d+)/)[1]);
    return findIdx(axText, "未加标签的图片");
  }

  await sky.press_key({ app: "com.google.Chrome", key: "Escape" });
  await new Promise(r => setTimeout(r, 600));

  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const targetIdx = findNodeDblClickTarget(s.text, "3")
    ?? findIdx(s.text, "文本", "3")
    ?? findIdx(s.text, "未加标签的图片");

  if (!targetIdx) {
    nodeRepl.write(JSON.stringify({ error: "node dblclick target not found" }));
  } else {
    await sky.click({ app: "com.google.Chrome", element_index: targetIdx, click_count: 2 });
    await new Promise(r => setTimeout(r, 1500));
    const s2 = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
    const panelLines = s2.text.split("\n").filter(l =>
      /LLM|属性定义|捕获|新建/.test(l) && (/按钮/.test(l) || /文本栏/.test(l))
    );
    nodeRepl.write(JSON.stringify({ dblclickTarget: targetIdx, panelOpened: panelLines.length > 0, panelLines: panelLines.slice(0, 10) }));
  }
}
```

## 禁止做法

```js
await sky.click({ app: "com.google.Chrome", element_index: 284, clickCount: 2 });
await sky.click({ app: "com.google.Chrome", element_index: 57, click_count: 2 });
await sky.click({ app: "com.google.Chrome", x: 560, y: 360, click_count: 2 });
```
