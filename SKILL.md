---
name: cua-router-basic
disable-model-invocation: true
description: >
  cua-router + sky Computer Use API 基础技能。封装了在 macOS 上通过 cua-router 本地服务
  调用 sky（OpenAI Computer Use）操控系统浏览器、桌面应用的公共依赖、初始化流程和辅助函数。
  其他 sky/cua-router 相关技能开发时，应参照本技能的规范和 references 模块。

  当用户提到以下情况时激活：
  「cua-router 怎么启动」「sky bootstrap 怎么写」「computer use api 初始化」
  「AX Tree 怎么找元素」「get_app_state 怎么用」「sky.click / sky.set_value 怎么用」
  「用 sky 操控 Chrome」「用 sky 填表单」「用 sky 自动化操作浏览器」
  「cua-router 服务检查」「computer use 依赖路径」「sky runtime 初始化」
  「安装 cua-router-basic」「setup computer use」「安装 computer use 技能」
  「set_value 不生效」「type_text 和 set_value 区别」「文本输入区 地址栏」
  「弹层识别不到」「浮层漏掉」「AX Tree 对话框」「overlay 定位」
  「hover 触发菜单」「卡片右上角三点」「隐藏菜单」「鼠标悬停」
  「双击不生效」「canvas 点击」「contenteditable 双击」「React Flow 节点」

  开发新的 sky/cua-router 技能时，使用本技能作为公共规范参照，不需要在每个技能里重复描述依赖和操作规范。
  本技能不直接执行业务操作，只提供依赖说明、初始化代码和操作规范。
  Agent 在技能或 vendor 未安装时应先执行下方「快速启动」章节，再执行业务操作。
---

# cua-router-basic — sky Computer Use 基础规范

本技能是所有依赖 cua-router + sky Computer Use API 的公共基础。主文件只保留入口规范；详细说明拆分到 `references/` 模块。

## 模块索引

| 模块 | 内容 | 何时读取 |
|---|---|---|
| `references/install.md` | 安装、依赖、SKILL_ROOT、vendor、关键文件 | 首次安装、依赖异常、路径不确定 |
| `references/runtime-exec.md` | daemon 启动、bootstrap、exec.sh、nodeRepl.write、地址栏导航 | 执行任何 sky 操作前 |
| `references/ax-locating.md` | AX Tree 辅助函数、弹层定位、AX → hover → OCR → 坐标扫描降级 | 查找元素、处理弹层/浮层 |
| `references/hover-menu.md` | macOS `swift + CoreGraphics` 触发 hover、卡片右上角 `...` 菜单 | hover 后才显示的菜单/按钮 |
| `references/input-keyboard.md` | press_key 键名、set_value/type_text、地址栏与输入框差异 | 输入文本、粘贴、键盘快捷键 |
| `references/canvas-double-click.md` | Canvas / React Flow 节点双击标准流程 | 双击节点打开配置面板 |
| `references/cursor-install.md` | 安装到 Cursor 并置顶 `/` 菜单 | Cursor 技能安装/置顶 |

## 传输模式（node_repl vs mcp）

桌面控制有两条传输链路，由环境变量 `SKY_TRANSPORT` 选择：

| 模式 | 值 | 桌面控制在哪执行 | 何时用 |
|---|---|---|---|
| node_repl | `node_repl`（**默认，推荐**） | app-server 托管的 node_repl 内 `sky.*` | 所有场景（含 Automan Desktop 宿主） |
| MCP | `mcp` | cua-router 进程内的签名 `cua mcp` 子进程 | **实验性 / 当前不可用**：见下方说明 |

**为什么默认 node_repl**：`list_apps` / `get_app_state` 等桌面控制依赖 CUAService 与 codex **app-server 的 event-observer 连接**。app-server 托管的 node_repl 会话持有该连接，因此可用。独立的 `cua mcp` stdio 子进程**不建立**该连接，CUAService 会卡在 `CodexAppServerThreadEventObserver.connection` 上静默挂死（表现为 `/cua` 返回空错误 / `mcp_error`）。故 `SKY_TRANSPORT=mcp` 目前**不能驱动桌面控制**，仅保留为 opt-in。

**授权前提**：CUAService 需要 macOS 的**辅助功能（Accessibility）+ 屏幕录制（Screenshots）**授权。首次触碰权限时会弹出官方「Enable ChatGPT Computer Use」窗口，点两个 Allow 即可（授权按 bundle id `com.openai.sky.CUAService` 记录，与谁拉起服务无关，一次授权长期有效）。

`/cua` 结构化端点在两种模式下都可调用；node_repl 模式下由 `sky.*` 承接。

## 快速启动

执行任何 sky/cua-router 操作前，先确认服务在线：

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/claude-code-agents/cua-agent/skills/cua-router-basic}"
[ -f "$SKILL_ROOT/SKILL.md" ] || SKILL_ROOT="${HOME}/.automan/skills/cua-router-basic"
[ -f "$SKILL_ROOT/SKILL.md" ] || SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"

# 默认 node_repl 模式（推荐；含 Automan Desktop 宿主）：
bash "$SKILL_ROOT/scripts/daemon.sh" start
bash "$SKILL_ROOT/scripts/daemon.sh" authorize   # 首次前台唤起 Enable ChatGPT Computer Use 授权窗，点两个 Allow
bash "$SKILL_ROOT/scripts/cua.sh" list_apps                       # 冒烟：应返回 app 列表
bash "$SKILL_ROOT/scripts/cua.sh" get_app_state '{"app":"Finder"}' # 应返回截图 + AX 文本
```

### `/cua` 结构化端点

`scripts/cua.sh <tool> [json-arguments]` 驱动桌面控制（默认经 node_repl 的 `sky.*`）。支持工具：
`list_apps get_app_state click perform_secondary_action set_value select_text scroll drag press_key type_text`。

```bash
bash "$SKILL_ROOT/scripts/cua.sh" get_app_state '{"app":"com.google.Chrome"}'
bash "$SKILL_ROOT/scripts/cua.sh" click '{"app":"Finder","x":100,"y":200}'
bash "$SKILL_ROOT/scripts/cua.sh" press_key '{"app":"Finder","key":"Command+a"}'
bash "$SKILL_ROOT/scripts/cua.sh" type_text '{"app":"Finder","text":"hello"}'
```

> MCP 模式下若返回 `-1743`：说明宿主 app 缺「控制 ChatGPT Computer Use」的自动化授权。请在**宿主 app（Automan Desktop）**里首次触发一次桌面控制以弹窗授权，或到「系统设置 → 隐私与安全性 → 自动化」勾选。node_repl 派生进程无法弹窗（promptPolicy=0），只能由前台宿主 app 授权。

首次在本机使用 Computer Use（读 AX 树 / 操控 Chrome）前，若系统尚未授权，会自动前台弹出 **Enable ChatGPT Computer Use** 窗口；也可手动执行：

```bash
bash "$SKILL_ROOT/scripts/daemon.sh" authorize
```

环境变量 `CUA_ROUTER_PERMISSION_PROMPT`：`auto`（默认，缺权限时弹窗）、`force`（总是弹窗）、`off`（跳过，仅适合已授权环境）。

输出 `ok` 后才继续调用 `sky.*`。

## Chrome 预检（Playwright 干扰）

`sky.get_app_state({ app: "com.google.Chrome" })` 需要 Chrome 有**可见窗口**。Playwright MCP / cursor-ide-browser 常以 `--no-startup-window` 占用 Chrome，导致 `-10005: timeoutReached`。

`exec.sh` 在代码 targeting Chrome 时会自动预检；默认 **auto**（停 Playwright + 确保有窗口）：

```bash
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" status   # 只检查
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" fix      # 手动修复
```

环境变量 `CUA_ROUTER_CHROME_PREFLIGHT`：

| 值 | 行为 |
|---|---|
| `auto` | `exec.sh`  targeting Chrome 时的默认值；停 Playwright、确保 Chrome 窗口 |
| `warn` | 只警告并退出（`daemon.sh start` 使用此模式） |
| `off` | 跳过预检 |

## 核心操作规范

所有依赖本技能的代码块必须遵守：

| 操作 | 正确方式 | 禁止方式 |
|---|---|---|
| 读取 `/exec` 结果 | `nodeRepl.write(...)` 或 `exec.sh` | 依赖代码块最后一条表达式 |
| 重复执行 JS | 直接使用 `exec.sh`；`/exec` 自动隔离每次作用域 | 为避免 `already declared` 手工改全局变量 |
| URL 导航 | 仅当当前动作本身是地址栏 / 原生 URL 输入框导航时，地址栏 `set_value(addrIdx, url)` + `press_key("Return")` | 用 URL 导航替代页面内搜索、筛选、按钮点击、表单提交等用户动作；`type_text(url)` |
| 录制回放动作等价 | 按录制动作类型逐步复刻：页面内搜索框就定位页面输入框，筛选按钮就点击按钮，提交表单就操作表单 | 直接打开最终 URL、改 `window.location`、AppleScript `set URL` 来跳过页面内控件操作 |
| 浏览器顶部地址栏保护 | 普通文本输入默认不得落到 Chrome/Safari 顶部导航地址栏；只有明确的 URL 打开/导航动作才允许向地址栏写入 | 在 Chrome/Safari 把搜索词、表单内容、聊天内容写到地址栏 |
| 文本输入（最高优先级） | 目标控件聚焦后用 `/usr/bin/pbcopy` 设置剪贴板（绝对路径，避免沙箱 PATH 收窄报 `pbcopy 在当前环境不可用`），再用 `sky.press_key({ app, key: "Command+a" })` + `sky.press_key({ app, key: "Command+v" })`，随后 `ax.get(app, { refresh: true })` 校验 Value/文本/按钮状态 | 裸 `pbcopy`、优先 `set_value`、`type_text` 或 AppleScript 粘贴后不校验 |
| 获取 AX Tree | `ax.get(app)`（内部固定 `disableDiff:true` + 缓存自动失效） | 手写 `disableDiff:false`、跨交互复用旧树 |
| 一段代码内取多次树 | 只调一次 `ax.get(app)`，多次 `ax.findIdx` 复用 `s.text` | 每次 `findIdx` 前都取一次树 |
| 外部触发（swift / AppleScript / 手动鼠标） | 之后立刻 `ax.get(app, { refresh: true })` 或 `ax.invalidate(app)` | 直接 `ax.get(app)` 拿旧树 |
| 元素搜索 | 在完整 `s.text` 上 `ax.findIdx / ax.findAllIdx` | 按 idx 区间切片 |
| 输出到 `nodeRepl.write` | 用 `ax.summarize(s, { keywords, patterns, maxLines })` 或先 `filter + slice` | 回传完整 `s.text` 造成 payload 爆炸 |
| AX 缺失降级 | AX → hover → OCR → 坐标扫描 | AX 找不到就放弃或只点单个硬编码坐标 |
| hover 菜单 | 先系统鼠标移动触发 hover，再点菜单热区，最后 `ax.get(app, {refresh:true})` 验证 | 直接点卡片主体或菜单项全程用坐标 |
| 中文/URL 输入 | 普通输入/搜索/聊天场景优先稳定粘贴：`/usr/bin/pbcopy` + `sky.press_key({ app, key: "Command+a" })` + `sky.press_key({ app, key: "Command+v" })`，之后 `ax.get(app, { refresh: true })` 校验；Chrome 地址栏等明确原生控件可用 `set_value`；`pbcopy 不可用` 时见 `references/input-keyboard.md` 兜底章节 | 盲目 `type_text`、优先 AppleScript 粘贴、写入后不校验 |
| 消息发送 | 粘贴后重新取树定位并点击「发送」按钮 | 用 `Return` 代替发送按钮 |
| Canvas 双击 | `Escape` → 等 600ms → 对节点内文本/图片 `click_count: 2` | `clickCount`、双击 container、坐标双击 |
| 弹层/对话框 | 操作后 `ax.get(app)` → `ax.findFocusedIdx` → 全文搜索 | 只扫低 idx |

## 内置全局工具（bootstrap 后自动可用）

无需在代码块里重复定义。参见 `scripts/computer-use-client.mjs`。

- `sky.*`：Computer Use 原生 API。`click / double_click / set_value / type_text / press_key / scroll / hover / mouse_move / key_down / key_up` 调用后会自动失效对应 `app` 的 AX 缓存；无 `app` 参数（坐标点击）保守失效全部。
- `ax.get(app, { refresh?: boolean, maxAgeMs?: number })`：拿完整 AX 快照，跨 `/exec` 缓存；固定 `disableDiff:true`。
  - `refresh: true`：强制重取，绕过缓存。
  - `maxAgeMs: N`：仅当缓存年龄 `< N` 毫秒时命中，否则重取。`maxAgeMs: 0` 等价于 `refresh: true`。**推荐轮询/等待异步 UI 更新的场景传 `maxAgeMs: 300~500`。**
- `ax.invalidate(app?)`：手动失效指定 app 或全部缓存。
- `ax.findIdx(text, ...keywords)`：定位第一个匹配行的 `element_index`。
- `ax.findAllIdx(text, ...keywords)`：返回所有匹配 `{ idx, line }`。
- `ax.findFocusedIdx(text)`：定位当前焦点元素。
- `ax.linesMatching(text, pattern, { limit })`：按字符串或正则筛出匹配行。
- `ax.summarize(state, { keywords, patterns, maxLines, textPreview, includeUrl, includeFocused })`：只回传必要字段，避免把整棵树塞进 `nodeRepl.write`。
- `ax._stats()` / `ax._resetStats()`：调试用；返回 `{ hits, misses, staleMisses, refreshes, invalidations, hitRate, cacheSize, entries }`，每个 entry 附带 `ageMs / textLen`。

> 性能：`ax.get(app)` 在没有交互动作时命中缓存，不会重复调 `sky.get_app_state`；一旦通过 `sky.*` 交互（哪怕出错），对应 app 缓存立即失效，下次 `ax.get(app)` 会自动重新拉，正确性等价于每次都取新树。外部触发（swift / AppleScript / 页面自身异步更新）不走 wrapper，必须显式 `refresh:true` 或 `maxAgeMs:N` 兜底。

## 性能建议（保持定位正确性的前提下）

1. **一次取树，多次搜索**：同一步业务里如果需要找多个元素，只调一次 `ax.get(app)`，然后 `ax.findIdx(s.text, ...)` 复用 `s.text`。
2. **中间等待不取树**：只在真正要做定位或验证结果时才 `ax.get(app)`；纯粹的 `setTimeout` 不要跟着取一次。
3. **输出前收敛**：`nodeRepl.write` 前用 `ax.summarize` 或 `filter/slice`；不要把 `s.text` 整个 `JSON.stringify` 回传（Chrome 完整树常有数十万字符）。
4. **外部交互后显式刷新**：`swift + CoreGraphics`、AppleScript、手动移鼠标、页面自身异步更新不会经过 sky wrapper：
   - 明确知道交互点：`ax.get(app, { refresh: true })` 或 `ax.invalidate(app)`。
   - 轮询/不确定何时更新：`ax.get(app, { maxAgeMs: 300~500 })` 兜底。
5. **不要退回 diff 模式**：diff 语义会导致 `findIdx` 漏找、`element_index` 错位；性能优化只靠"减少调用次数"，不靠"取更小的树"。
6. **卡壳时用 `ax._stats()` 排查**：怀疑拿到陈旧树时，看 `hitRate` 与 `entries[].ageMs`；`ax.invalidate()` 全清后重试若结果变化则确认是缓存问题。

## hover 菜单快速模板

详细说明见 `references/hover-menu.md`。

```bash
swift -e 'import CoreGraphics; import Foundation; let p = CGPoint(x: 360, y: 210); if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) { e.post(tap: .cghidEventTap) }; Thread.sleep(forTimeInterval: 1.0)'

bash "$SKILL_ROOT/scripts/exec.sh" -t 60000 '{
  await sky.click({ app: "com.google.Chrome", x: 485, y: 172 });
  await new Promise(r => setTimeout(r, 1000));
  const s = await ax.get("com.google.Chrome", { refresh: true });
  const menuLines = ax.linesMatching(s.text, /启用中|创建副本|分享|移动到空间|删除|菜单/, { limit: 20 });
  nodeRepl.write(JSON.stringify({ opened: menuLines.length > 0, menuLines }));
}'
```

## 其他技能如何引用

在新技能的 `SKILL.md` 中只写公共引用，不要复制大段内容：

```markdown
## 依赖

参照 `cua-router-basic` 的 `references/install.md` 与 `references/runtime-exec.md`。
执行 sky 操作前必须 `daemon.sh start` 并用 `nodeRepl.write("ok")` 验证。

## 操作规范

遵循 `cua-router-basic` 主文件核心操作规范；具体场景按需读取：
- AX/弹层定位：`references/ax-locating.md`
- hover 隐藏菜单：`references/hover-menu.md`
- 输入与键盘：`references/input-keyboard.md`
- Canvas 双击：`references/canvas-double-click.md`
```
