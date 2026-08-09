# 输入、键盘与地址栏

## press_key 键名规范

`sky.press_key({ key })` 使用 X keysym 风格键名，用 `+` 连接组合键。

| 常见写法 | sky 原生是否认 | bootstrap 归一化后 |
|---|---|---|
| `Command+v` / `command+V` | 是 | - |
| `Super_L+v` | 是 | - |
| `Cmd+V` / `Meta+v` | 否 | `Command+V` |
| `Ctrl+c` / `Control+c` | 否 | `Control_L+c` |
| `Shift+Tab` / `Alt+Tab` / `Option+v` | 否 | `Shift_L+Tab` / `Alt_L+Tab` / `Alt_L+v` |
| `Return` / `Escape` / `F2` | 是 | - |

归一化在 `scripts/computer-use-client.mjs` 的 bootstrap 层完成。修改后需 `daemon.sh restart`。

## set_value、系统级粘贴与 type_text

| | `set_value` | 系统级粘贴 | `type_text` |
|---|---|---|---|
| 机制 | 通过 Accessibility API 写 AXValue | `pbcopy` 设置剪贴板，再用系统级 `Command+A` / `Command+V` | 模拟键盘逐字输入 |
| 是否需要 element_index | 需要 | 先聚焦目标控件，不依赖可写 AXValue | 不需要，写当前焦点 |
| URL / 特殊字符 | 可靠 | 可靠 | 易丢字符 |
| 中文 / IME | 可靠 | 可靠 | 易异常 |
| 适用控件 | 原生 input / textarea / 地址栏 | 不支持 AX 写值的编辑器、桌面 IM、contenteditable | 最后兜底 |

决策规则：

1. Chrome 地址栏导航只用 `set_value + Return`。
2. 页面普通表单优先 `set_value`。
3. 目标软件不支持 AX 写值、`set_value` 无效、或控件是 Monaco / CodeMirror / contenteditable / 桌面 IM 输入区时，降级为**系统级粘贴**。
4. 含 URL、中文、符号的内容禁止 `type_text`。
5. `type_text` 只做最后兜底，且写入后必须验证。

## 文本输入区 ≠ 地址栏

| AX 特征 | 实际控件 | set_value 是否有效 |
|---|---|---|
| `Description: 地址和搜索栏` | Chrome 地址栏 | 有效 |
| `文本栏` + Placeholder/Description | 页面原生输入框 | 通常有效 |
| `文本输入区` / `Description: 编辑器容器` | Monaco、CodeMirror、contenteditable、桌面 IM 输入区 | 通常无效，改用系统级粘贴 |
| `for screen reader` | 隐藏辅助字段 | 跳过 |

地址栏定位：

```js
const addrIdx = ax.findIdx(axText, "settable, string", "地址");
```

普通输入框定位（用 `linesMatching` 过滤排除项）：

```js
const fieldLine = ax
  .linesMatching(axText, /settable, string.*关键词/, { limit: 5 })
  .find((l) => !/地址|编辑器|screen reader|文本输入区/.test(l));
```

## 系统级粘贴示例

用于 `set_value` 失败或录制显示用户真实键盘输入、但目标软件不支持 AX 写值的场景。关键点：

1. 先用 `sky.click` 聚焦输入区。
2. 在 shell 层用 `pbcopy` 设置剪贴板。
3. 在 shell 层用 `osascript` 发送系统级 `Command+A` / `Command+V`。
4. 粘贴是外部系统动作，之后必须 `ax.get(app, { refresh: true })` 或 `ax.invalidate(app)` 再验证。

```js
{
  const s1 = await ax.get("cn.neixin.pc");
  const inputIdx = ax.findIdx(s1.text, "文本输入区", "说点什么");
  await sky.click({ app: "cn.neixin.pc", element_index: inputIdx });
  await new Promise((r) => setTimeout(r, 400));
}
```

```bash
TEXT="$(cat <<'EOF'
要输入的中文、URL 或多行文本
EOF
)"
printf '%s' "$TEXT" | pbcopy
osascript -e 'tell application "System Events" to keystroke "a" using command down'
osascript -e 'tell application "System Events" to keystroke "v" using command down'
```

```js
{
  const s2 = await ax.get("cn.neixin.pc", { refresh: true });
  nodeRepl.write(
    JSON.stringify({
      pasted: /要输入的中文|URL/.test(s2.text),
      sendIdx: ax.findIdx(s2.text, "发送"),
    }),
  );
}
```

消息发送类场景不要用 `Return` 代替发送。粘贴后重新取树定位「发送」按钮，再 `sky.click({ app, element_index: sendIdx })` 并用 `{ refresh: true }` 校验发送结果。
