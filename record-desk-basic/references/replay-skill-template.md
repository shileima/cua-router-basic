# 回放技能模板（依赖 cua-router-basic 高效执行）

由录制生成的回放技能应**依赖 cua-router-basic**，用 `sky.*` + `ax.*` 执行，而不是坐标盲点。这样更准、更快、更抗 UI 漂移。

> **完整性原则**：回放步骤必须**严格覆盖录制里的全部结构性动作**，从打开/激活应用、地址栏导航等前置动作，一直到保存与结果校验，逐步复刻、不删减不跳步（对齐 `codex-record-skill`）。只把随场景变化的演示值抽成输入参数，动作与其顺序保持不变。

> **执行纪律（强制）**：回放时**认真对待录制里的每一个正常 action**，不得跳过、合并或忽略。每个 action 必须走完「操作前审视 AX Tree → 记录本步目标节点 → 执行 → 操作后审视 AX Tree 验证上一步 → 规划下一步」循环；验证失败时停止跳步，先排查再继续。

> **动作等价约束（强制）**：回放步骤必须保持录制动作类型一致。录制是地址栏输入 URL，才允许用地址栏导航；录制是页面内搜索框输入、页面按钮点击、筛选项点击或表单提交时，必须定位并操作对应页面控件，禁止直接打开操作后的最终 URL 或用 `window.location` / AppleScript `set URL` 绕过。

## 目标技能骨架

```
<workflow-name>/
├── SKILL.md            # 触发词 + 步骤 + 输入参数 + 依赖引用
└── references/*.md     # 复杂步骤的定位细节（按需）
```

## SKILL.md 模板

```markdown
---
name: <workflow-name>
description: >
  <一句话说明这个工作流做什么>。由 record-desk-basic 录制生成，用 Computer Use 回放。
  触发词：「<触发短语1>」「<触发短语2>」…
---

# <workflow-name>

## 依赖

参照 `cua-router-basic` 的 `references/install.md` 与 `references/runtime-exec.md`。
执行 sky 操作前必须 `daemon.sh start` 并用 `nodeRepl.write("ok")` 验证。

## 输入参数

| 参数 | 说明 | 示例 |
|---|---|---|
| `<param1>` | <来自录制里应参数化的值> | … |

## 回放执行纪律

每个 action（对应录制时间线里的一个正常操作）必须按以下循环执行，**一步都不能合并或省略**：

| 阶段 | 要求 |
|---|---|
| **操作前** | `ax.get(app)` 审视当前 AX Tree 与 UI 状态；确认与录制该步前的上下文一致；**书面记录**本步目标节点（role、文案、`element_index` 或语义定位） |
| **执行** | 只做本步这一个 action，严格对应录制事件 |
| **操作后** | 再次 `ax.get(app)`（外部系统动作后 `{ refresh: true }`），**验证上一步是否生效**（文本、焦点、页面、按钮状态等） |
| **规划下一步** | 基于最新 AX Tree 定位下一节点；验证失败则停止跳步，排查/降级后再继续 |

禁止：跳过「看似重复」的点击/导航；连做多个录制步骤而不逐步校验；在验证失败时凭猜测继续。

## 回放步骤

遵循 `cua-router-basic` 主文件核心操作规范。**按录制时间线逐个动作展开为一个步骤，严格覆盖完整链路**（含打开/激活应用、导航等前置动作，不假设已在目标页面）。每步严格执行上方「回放执行纪律」。

1. 打开/激活目标应用并导航到起始页（如地址栏输入 URL）——这也是录制的一部分，必须写出来。
2. **操作前** `ax.get("<bundleId>")` 审视 AX Tree → 定位本步目标 → 交互 → **操作后** `ax.get(app)` 验证上一步生效。
3. 交互用 `sky.click / sky.set_value / sky.press_key`；URL/中文先判断控件能力，原生输入框用 `set_value`，页面内搜索/筛选/表单字段必须定位到对应控件再输入，不能直接改成最终结果 URL。
4. shell / AppleScript / swift 等外部系统动作后必须 `ax.get(app, { refresh: true })`，避免复用旧 `element_index`。
   - AX 缺失时按 AX → hover → OCR → 坐标扫描 降级（见 cua-router-basic `references/ax-locating.md`）。
5. 最后一步做结果校验（如出现「已保存」或目标节点文本），与录制的收尾动作对应。
```

## 从事件到步骤的映射建议

| 录制事件 | 回放写法 |
|---|---|
| 点击某按钮（有 AX target） | `ax.findIdx(s.text, "<按钮文案>")` → `sky.click({ app, x, y })` |
| 在原生输入框输入文本 | `sky.set_value({ app, element_index: idx, value })` |
| 浏览器顶部地址栏输入 URL | 仅在明确导航动作时，定位 Chrome/Safari 顶部地址栏后 `sky.set_value(..., url)` + `press_key("Return")` |
| 页面内搜索框/筛选框/表单字段输入文本 | 先定位对应页面控件，再输入并校验；不要直接跳最终结果页 URL |
| 页面内按钮点击、筛选项切换、列表翻页 | 先定位当前页面上的具体控件，再逐步点击；不要省略中间状态 |
| 在不支持 AX 写值的输入区输入文本 | 聚焦输入区 → shell `/usr/bin/pbcopy` 写剪贴板（绝对路径，`pbcopy 不可用` 时见 `cua-router-basic` 的 `references/input-keyboard.md` 兜底章节）→ shell `/usr/bin/osascript` 系统级 `Command+A` / `Command+V` → `ax.get(app, { refresh: true })` 校验 |
| 发送消息 | 粘贴后重新取树定位「发送」按钮 → `sky.click({ app, element_index: sendIdx })`；不要用 `Return` 代替 |
| hover 后才出现的菜单 | 先 swift 移动鼠标触发 hover，再点热区（cua-router-basic `references/hover-menu.md`） |
| Canvas / React Flow 双击 | `Escape` → 等 600ms → 对节点内文本 `click_count: 2`（`references/canvas-double-click.md`） |
| 纯视觉校验/无稳定 AX target | 保留坐标兜底，但必须配 OCR/AX 二次确认 |

## 不支持 AX 写值时的系统级粘贴模板

录制事件如果表现为用户真实键盘输入，但目标控件无法通过 `set_value` 写入，生成技能时使用下面的结构：

```bash
# 1) 先在 exec.sh 中用 sky.click 聚焦输入区。

# 2) shell 层设置剪贴板并触发系统级粘贴。
TEXT="$(cat <<'EOF'
<来自输入参数的文本>
EOF
)"
printf '%s' "$TEXT" | /usr/bin/pbcopy
/usr/bin/osascript -e 'tell application "System Events" to keystroke "a" using command down'
/usr/bin/osascript -e 'tell application "System Events" to keystroke "v" using command down'
```

```js
// 3) 重新取树验证，之后再定位发送/保存按钮。
const s = await ax.get(app, { refresh: true });
const sendIdx = ax.findIdx(s.text, "发送");
if (sendIdx == null) throw new Error("未找到发送按钮");
await sky.click({ app, element_index: sendIdx });
const afterSend = await ax.get(app, { refresh: true });
```

## 单步回放代码骨架（生成技能时应嵌入类似结构）

```js
// 操作前：审视 AX Tree，记录本步目标节点
let s = await ax.get(app, { refresh: true });
let idx = ax.findIdx(s.text, "<本步目标文案>");
if (idx == null) throw new Error("操作前未找到目标节点: <本步目标文案>");

// 执行：只做本步 action
await sky.click({ app, element_index: idx });

// 操作后：再次审视 AX Tree，验证上一步生效
s = await ax.get(app, { refresh: true });
// 在此断言预期变化（文本已写入、页面已跳转、按钮已禁用等）
if (!/* 上一步验证条件 */) throw new Error("上一步操作未生效，停止跳步");
```

## 校验

- 用 `skill-creator` 规范校验生成技能结构完整、可发现。
- 回放技能必须能在 cua-router-basic 运行时下实际跑通，而不仅是结构合法。
- 回放时必须逐步执行每个 action，且每步都有操作前/后的 AX Tree 审视与验证，不得批量跳过。
