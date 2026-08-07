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

## 快速启动

执行任何 sky/cua-router 操作前，先确认服务在线：

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/skills/cua-router-basic}"
if [ ! -f "$SKILL_ROOT/SKILL.md" ]; then
  SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"
fi
bash "$SKILL_ROOT/scripts/daemon.sh" start
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
```

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
| URL 导航 | 地址栏 `set_value(addrIdx, url)` + `press_key("Return")` | `type_text(url)` |
| 获取 AX Tree | `ax.get(app)`（内部固定 `disableDiff:true` + 缓存自动失效） | 手写 `disableDiff:false`、跨交互复用旧树 |
| 一段代码内取多次树 | 只调一次 `ax.get(app)`，多次 `ax.findIdx` 复用 `s.text` | 每次 `findIdx` 前都取一次树 |
| 外部触发（swift / AppleScript / 手动鼠标） | 之后立刻 `ax.get(app, { refresh: true })` 或 `ax.invalidate(app)` | 直接 `ax.get(app)` 拿旧树 |
| 元素搜索 | 在完整 `s.text` 上 `ax.findIdx / ax.findAllIdx` | 按 idx 区间切片 |
| 输出到 `nodeRepl.write` | 用 `ax.summarize(s, { keywords, patterns, maxLines })` 或先 `filter + slice` | 回传完整 `s.text` 造成 payload 爆炸 |
| AX 缺失降级 | AX → hover → OCR → 坐标扫描 | AX 找不到就放弃或只点单个硬编码坐标 |
| hover 菜单 | 先系统鼠标移动触发 hover，再点菜单热区，最后 `ax.get(app, {refresh:true})` 验证 | 直接点卡片主体或菜单项全程用坐标 |
| 中文/URL 输入 | 优先 `set_value` | 盲目 `type_text` |
| Canvas 双击 | `Escape` → 等 600ms → 对节点内文本/图片 `click_count: 2` | `clickCount`、双击 container、坐标双击 |
| 弹层/对话框 | 操作后 `ax.get(app)` → `ax.findFocusedIdx` → 全文搜索 | 只扫低 idx |

## 内置全局工具（bootstrap 后自动可用）

无需在代码块里重复定义。参见 `scripts/computer-use-client.mjs`。

- `sky.*`：Computer Use 原生 API。`click / double_click / set_value / type_text / press_key / scroll / hover / mouse_move / key_down / key_up` 调用后会自动失效对应 `app` 的 AX 缓存；无 `app` 参数（坐标点击）保守失效全部。
- `ax.get(app, { refresh?: boolean })`：拿完整 AX 快照，跨 `/exec` 缓存；固定 `disableDiff:true`。
- `ax.invalidate(app?)`：手动失效指定 app 或全部缓存。
- `ax.findIdx(text, ...keywords)`：定位第一个匹配行的 `element_index`。
- `ax.findAllIdx(text, ...keywords)`：返回所有匹配 `{ idx, line }`。
- `ax.findFocusedIdx(text)`：定位当前焦点元素。
- `ax.linesMatching(text, pattern, { limit })`：按字符串或正则筛出匹配行。
- `ax.summarize(state, { keywords, patterns, maxLines, textPreview, includeUrl, includeFocused })`：只回传必要字段，避免把整棵树塞进 `nodeRepl.write`。

> 性能：`ax.get(app)` 在没有交互动作时命中缓存，不会重复调 `sky.get_app_state`；一旦通过 `sky.*` 交互（哪怕出错），对应 app 缓存立即失效，下次 `ax.get(app)` 会自动重新拉，正确性等价于每次都取新树。

## 性能建议（保持定位正确性的前提下）

1. **一次取树，多次搜索**：同一步业务里如果需要找多个元素，只调一次 `ax.get(app)`，然后 `ax.findIdx(s.text, ...)` 复用 `s.text`。
2. **中间等待不取树**：只在真正要做定位或验证结果时才 `ax.get(app)`；纯粹的 `setTimeout` 不要跟着取一次。
3. **输出前收敛**：`nodeRepl.write` 前用 `ax.summarize` 或 `filter/slice`；不要把 `s.text` 整个 `JSON.stringify` 回传（Chrome 完整树常有数十万字符）。
4. **外部交互后显式刷新**：`swift + CoreGraphics`、AppleScript、手动移鼠标不会经过 sky wrapper，之后必须 `ax.get(app, { refresh: true })` 或 `ax.invalidate(app)`。
5. **不要退回 diff 模式**：diff 语义会导致 `findIdx` 漏找、`element_index` 错位；性能优化只靠"减少调用次数"，不靠"取更小的树"。

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
