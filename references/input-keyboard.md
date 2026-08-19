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

## 稳定输入最高优先级：/usr/bin/pbcopy + sky.press_key(Command+v)

除 Chrome 地址栏导航等明确验证过的原生控件外，所有页面输入框、Electron/WebView 输入框、桌面 IM 输入区、contenteditable、Monaco/CodeMirror、聊天框、搜索框，默认优先使用稳定粘贴闭环：

1. `ax.get(app, { refresh: true })` 重新定位目标输入控件，禁止跨交互复用旧 `element_index`。
2. `sky.click({ app, element_index })` 聚焦输入控件。
3. shell 层 `/usr/bin/pbcopy` 写入目标文本（用绝对路径，避免沙箱 PATH 收窄导致 `pbcopy` 不可用；不可用时见「pbcopy 不可用时的兜底」）。
4. `sky.press_key({ app, key: "Command+a" })` 清空当前内容。
5. `sky.press_key({ app, key: "Command+v" })` 粘贴。
6. `ax.get(app, { refresh: true })` 校验目标文本已出现在控件 Value/文本/联想结果中。
7. 只有校验通过后才允许点击「发送」「搜索」「提交」等动作；发送类动作优先点击按钮，不用 Return 代替。

`set_value` 不再作为普通输入的首选，只适合 Chrome 地址栏、明确原生且写后能校验生效的 input/textarea。AppleScript 粘贴只做最后兜底；若使用 AppleScript，之后必须强制刷新 AX 并校验。

## set_value、稳定粘贴与 type_text

| | `set_value` | 稳定粘贴（首选） | `type_text` |
|---|---|---|---|
| 机制 | 通过 Accessibility API 写 AXValue | `/usr/bin/pbcopy` 设置剪贴板，再用 `sky.press_key({ app, key: "Command+a" })` / `sky.press_key({ app, key: "Command+v" })` | 模拟键盘逐字输入 |
| 是否需要 element_index | 需要 | 需要先重新定位并聚焦目标控件，不依赖可写 AXValue | 不需要，写当前焦点 |
| URL / 特殊字符 | 地址栏可靠，其它控件需校验 | 可靠 | 易丢字符 |
| 中文 / IME | 常被 Web/Electron 受控输入框吞掉或不触发事件 | 可靠 | 易异常 |
| 适用控件 | Chrome 地址栏、明确原生且可校验生效的 input/textarea | 普通表单、搜索框、聊天框、桌面 IM、contenteditable、Monaco/CodeMirror、Electron/WebView 输入区 | 最后兜底 |

决策规则：

1. Chrome 地址栏导航可用 `set_value + Return`；如用户明确要求验证粘贴链路，也可用稳定粘贴。
2. 普通文本输入、搜索、聊天、消息发送场景，最高优先级使用**稳定粘贴**。
3. `set_value` 只在明确原生控件且写后能通过 AX 校验时使用。
4. 含 URL、中文、符号的内容禁止 `type_text`。
5. `type_text` 只做最后兜底，且写入后必须验证。

## 文本输入区 ≠ 地址栏

| AX 特征 | 实际控件 | set_value 是否有效 |
|---|---|---|
| `Description: 地址和搜索栏` | Chrome 地址栏 | 有效 |
| `文本栏` + Placeholder/Description | 页面原生输入框 | 通常有效 |
| `文本输入区` / `Description: 编辑器容器` | Monaco、CodeMirror、contenteditable、桌面 IM 输入区 | 通常无效，改用稳定粘贴 |
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

## 稳定粘贴示例

用于普通输入、搜索、聊天、`set_value` 失败或录制显示用户真实键盘输入的场景。关键点：

1. 先用 `ax.get(app, { refresh: true })` 重新定位输入区。
2. 用 `sky.click` 聚焦输入区。
3. 在 shell 层用 `/usr/bin/pbcopy` 设置剪贴板（绝对路径，避免 `pbcopy 在当前环境不可用`）。
4. 用 `sky.press_key({ app, key: "Command+a" })` / `sky.press_key({ app, key: "Command+v" })` 执行清空与粘贴。
5. 粘贴后必须 `ax.get(app, { refresh: true })` 验证。

```bash
TEXT="$(cat <<'EOF'
要输入的中文、URL 或多行文本
EOF
)"
printf '%s' "$TEXT" | /usr/bin/pbcopy

bash "$SKILL_ROOT/scripts/exec.sh" -t 60000 '{
  const app = "cn.neixin.pc";
  const expected = "要输入的中文、URL 或多行文本";
  let s = await ax.get(app, { refresh: true });
  const inputIdx = ax.findIdx(s.text, "文本输入区", "说点什么") || ax.findIdx(s.text, "文本栏", "搜索");
  if (!inputIdx) throw new Error("未找到输入控件");
  await sky.click({ app, element_index: inputIdx });
  await new Promise((r) => setTimeout(r, 300));
  await sky.press_key({ app, key: "Command+a" });
  await sky.press_key({ app, key: "Command+v" });
  await new Promise((r) => setTimeout(r, 500));
  s = await ax.get(app, { refresh: true });
  nodeRepl.write(JSON.stringify({
    pasted: s.text.includes(expected),
    focused: ax.findFocusedIdx(s.text),
    sendIdx: ax.findIdx(s.text, "发送"),
  }));
}'
```

消息发送类场景不要用 `Return` 代替发送。粘贴后重新取树定位「发送」按钮，再 `sky.click({ app, element_index: sendIdx })` 并用 `{ refresh: true }` 校验发送结果。

## pbcopy 不可用时的兜底

报错 `pbcopy 在当前环境不可用` **几乎不是本机缺少 pbcopy**（macOS 固定自带 `/usr/bin/pbcopy`），而是执行命令的 Agent 运行在受限/沙箱 shell 里，`PATH` 被收窄或清空，找不到裸 `pbcopy`。因此：

1. **首选：绝对路径调用**。所有写剪贴板一律用 `/usr/bin/pbcopy`，不要依赖 `PATH`：

```bash
printf '%s' "$TEXT" | /usr/bin/pbcopy
```

2. **补 PATH 后重试**。若绝对路径仍报缺失（极少见），先补齐系统路径再执行：

```bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
printf '%s' "$TEXT" | /usr/bin/pbcopy
```

3. **AppleScript 写剪贴板兜底**（不依赖 pbcopy，仍需 `/usr/bin/osascript`）：

```bash
/usr/bin/osascript -e 'set the clipboard to (system attribute "CUA_CLIP")' 2>/dev/null || \
  CUA_CLIP="$TEXT" /usr/bin/osascript -e 'set the clipboard to (system attribute "CUA_CLIP")'
```

   或直接把文本作为参数传入：

```bash
/usr/bin/osascript - "$TEXT" <<'APPLESCRIPT'
on run argv
  set the clipboard to (item 1 of argv)
end run
APPLESCRIPT
```

4. **最后兜底：改用 `set_value` 或 `type_text`**。上述剪贴板方式都不可用时，对原生输入框用 `sky.set_value`，其它控件用 `sky.type_text`，写入后**必须** `ax.get(app, { refresh: true })` 校验。含 URL/中文/符号内容优先 `set_value`，避免 `type_text` 丢字符。

> 无论走哪种兜底，写入剪贴板/输入后都要用 `sky.press_key({ app, key: "Command+a" })` + `sky.press_key({ app, key: "Command+v" })`（剪贴板路径）或直接校验控件 Value，再 `ax.get(app, { refresh: true })` 确认目标文本已生效，通过后才允许点击发送/搜索/提交。
