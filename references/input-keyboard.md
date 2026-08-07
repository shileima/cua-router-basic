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

## set_value 与 type_text

| | `set_value` | `type_text` |
|---|---|---|
| 机制 | 通过 Accessibility API 写 AXValue | 模拟键盘逐字输入 |
| 是否需要 element_index | 需要 | 不需要，写当前焦点 |
| URL / 特殊字符 | 可靠 | 易丢字符 |
| 中文 / IME | 可靠 | 易异常 |
| 适用控件 | 原生 input / textarea / 地址栏 | 最后兜底 |

决策规则：

1. Chrome 地址栏导航只用 `set_value + Return`。
2. 页面普通表单优先 `set_value`。
3. 含 URL、中文、符号的内容禁止 `type_text`。
4. `type_text` 只做最后兜底，且写入后必须验证。

## 文本输入区 ≠ 地址栏

| AX 特征 | 实际控件 | set_value 是否有效 |
|---|---|---|
| `Description: 地址和搜索栏` | Chrome 地址栏 | 有效 |
| `文本栏` + Placeholder/Description | 页面原生输入框 | 通常有效 |
| `文本输入区` / `Description: 编辑器容器` | Monaco、CodeMirror、contenteditable | 通常无效 |
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

## 粘贴示例

```js
{
  const s1 = await ax.get("cn.neixin.pc");
  const inputIdx = ax.findIdx(s1.text, "文本输入区", "说点什么");
  await sky.click({ app: "cn.neixin.pc", element_index: inputIdx });
  await new Promise((r) => setTimeout(r, 400));
  await sky.press_key({ app: "cn.neixin.pc", key: "Cmd+V" });
}
```
