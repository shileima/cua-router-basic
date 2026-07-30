---
name: cua-router-basic
disable-model-invocation: true
description: >
  cua-router + sky Computer Use API 基础技能。封装了在 macOS 上通过 cua-router 本地服务
  调用 sky（OpenAI Computer Use）操控系统浏览器、桌面应用的公共依赖、初始化流程和辅助函数。
  其他 sky/cua-router 相关技能开发时，应参照本技能的规范和辅助函数。

  当用户提到以下情况时激活：
  「cua-router 怎么启动」「sky bootstrap 怎么写」「computer use api 初始化」
  「AX Tree 怎么找元素」「get_app_state 怎么用」「sky.click / sky.set_value 怎么用」
  「用 sky 操控 Chrome」「用 sky 填表单」「用 sky 自动化操作浏览器」
  「cua-router 服务检查」「computer use 依赖路径」「sky runtime 初始化」
  「安装 cua-router-basic」「setup computer use」「安装 computer use 技能」
  「set_value 不生效」「type_text 和 set_value 区别」「文本输入区 地址栏」
  「弹层识别不到」「浮层漏掉」「AX Tree 对话框」「overlay 定位」
  「双击不生效」「canvas 点击」「contenteditable 双击」「React Flow 节点」

  开发新的 sky/cua-router 技能时，使用本技能作为公共规范参照，不需要在每个技能里重复描述依赖和操作规范。
  本技能不直接执行业务操作，只提供依赖说明、初始化代码和操作规范。
  Agent 在技能或 vendor 未安装时应先执行下方「Agent 安装」章节，再执行业务操作。
---

# cua-router-basic — sky Computer Use 基础规范

本技能是所有依赖 cua-router + sky Computer Use API 的技能的**公共基础**，统一管理依赖声明、初始化流程、辅助函数和操作规范。新技能开发时直接参照本文件，无需重复描述。

## Agent 安装（首次使用）

Agent 在执行任何 sky/cua-router 操作前，**必须先确认技能与 vendor 已就绪**。若 `$SKILL_ROOT/SKILL.md` 不存在，或 `$SKILL_ROOT/vendor/codex/bin/codex` 不可执行，按以下流程自动安装（无需用户手动 git clone）。

`SKILL_ROOT` 默认路径：若存在 `~/.automan/skills` 则为 `~/.automan/skills/cua-router-basic`，否则为 `~/.cursor/skills/cua-router-basic`（可通过 `CUA_ROUTER_INSTALL_DIR` 覆盖）。

#### 方式 A：远程一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
```

安装完成后脚本会输出 `SKILL_ROOT=...`，后续命令均基于该路径。

若本机有 `~/.automan/skills`，还会同步 Claude Code agents 技能符号链接：
`~/.automan/claude-code-agents/main/skills/cua-router-basic` → `../../../skills/cua-router-basic`

#### 方式 B：技能目录已存在，仅缺 vendor

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/skills/cua-router-basic}"
if [ ! -f "$SKILL_ROOT/SKILL.md" ]; then
  SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"
fi
bash "$SKILL_ROOT/scripts/install-full.sh" --vendor-mode auto
```

#### 方式 C：Cursor / Claude Code Plugin 安装

- **Cursor**：`/add-plugin shileima/cua-router-basic`（或从 Plugin 市场安装）
- **Claude Code**：`/plugin install cua-router-basic@cua-router-basic-dev`（需先添加本仓库 marketplace）

Plugin 仅注册 slim 技能包；**首次使用前仍需 vendor bootstrap**（`daemon.sh start` 或 `install-full.sh` 会自动完成）。

#### 安装后验证

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/skills/cua-router-basic}"
if [ ! -f "$SKILL_ROOT/SKILL.md" ]; then
  SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"
fi
bash "$SKILL_ROOT/scripts/daemon.sh" start
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
# 输出 ok 表示技能与 cua-router 均已就绪
```

## 依赖

技能包内已自带全部运行时依赖，**不依赖 `~/.codex` 或 `/Applications/ChatGPT.app`**。

`SKILL_ROOT` = 本 `SKILL.md` 所在目录的绝对路径。Agent 读取本技能时应先解析此路径，后续命令均基于 `$SKILL_ROOT`。

#### 首次安装 vendor（仅需一次）

vendor 会在以下时机**自动 bootstrap**（优先 ChatGPT.app 提取，否则从 GitHub Release 下载）：

- `bash scripts/install-remote.sh` / `install-full.sh`
- `bash scripts/daemon.sh start`（vendor 缺失时自动调用 `install-full.sh --vendor-mode auto`）

也可手动从本机 ChatGPT.app 提取：

```bash
bash "$SKILL_ROOT/scripts/setup-vendor.sh"
```

前提：本机已安装 ChatGPT/Codex 桌面应用，且已在 Codex 中安装过 Computer Use 插件（`~/.codex/computer-use/` 存在）。无 ChatGPT 时使用 Release 下载即可。

#### 服务依赖

| 依赖 | 说明 |
|------|------|
| **cua-router** | 本地 HTTP 服务，监听 `localhost:18901`，所有 sky 操作均通过其 `/exec` 端点执行 |
| **app-server** | 技能包内 `vendor/codex/bin/codex app-server`，由 cua-router 以 stdio 方式启动 |
| **sky runtime** | 技能包内 `vendor/cua_node` 的 node_repl + `@oai/sky`，每次 cua-router 重启后需 bootstrap |

#### 文件依赖（技能包内）

| 文件路径 | 用途 |
|----------|------|
| `{SKILL_ROOT}/scripts/cua-router.py` | cua-router 主程序 |
| `{SKILL_ROOT}/scripts/daemon.sh` | 守护进程管理（推荐：`start` / `status` / `restart` / `stop`） |
| `{SKILL_ROOT}/scripts/exec.sh` | `/exec` 封装：自动启动服务、发送 JS、解析 `nodeRepl.write` 输出 |
| `{SKILL_ROOT}/scripts/install-cursor.sh` | 安装到 `~/.cursor/skills` 并 Pin 到 `/` 菜单前列 |
| `{SKILL_ROOT}/scripts/install-automan.sh` | 同步 `~/.automan/claude-code-agents/main/skills` 符号链接 |
| `{SKILL_ROOT}/scripts/install-remote.sh` | Agent 远程一键安装（slim + vendor + Cursor/automan 注册） |
| `{SKILL_ROOT}/scripts/install-full.sh` | 完整安装（vendor bootstrap + Cursor 注册） |
| `{SKILL_ROOT}/scripts/computer-use-client.mjs` | sky runtime 入口模块，bootstrap 时 import |
| `{SKILL_ROOT}/scripts/setup-vendor.sh` | 从 ChatGPT.app 提取 vendor 依赖 |
| `{SKILL_ROOT}/vendor/codex/bin/codex` | 内置 app-server 可执行文件 |
| `{SKILL_ROOT}/vendor/cua_node/` | 内置 node + node_repl + `@oai/sky` |
| `{SKILL_ROOT}/vendor/computer-use/Codex Computer Use.app` | SkyComputerUseClient 原生客户端 |
| `{SKILL_ROOT}/runtime/config.toml` | 启动时自动生成，指向 vendor 内路径 |

#### 环境变量（可选）

| 变量 | 说明 |
|------|------|
| `CODEX_BIN` | 覆盖 vendor 内 codex 路径（通常不需要） |
| `CUA_ROUTER_API_KEY` / `NEWAPI_API_KEY` | 走 newapi proxy 时的 API Key（仅 `/responses` 路由需要，`/exec` 不需要） |
| `CUA_ROUTER_NEWAPI_BASE` | newapi 上游地址，默认 `https://newapi.waimai.test.sankuai.com/v1` |
| `CHATGPT_RESOURCES` | setup-vendor 源路径，默认 `/Applications/ChatGPT.app/Contents/Resources` |

#### 系统依赖

- macOS + Chrome（bundle id: `com.google.Chrome`）
- Python 3（用于运行 cua-router.py）
- vendor 来源（二选一，auto 模式自动选择）：ChatGPT.app 提取，或 GitHub Release 预构建 tarball

## 启动与检查 cua-router

#### ⚠️ 禁止裸 `&` 后台启动

在 Cursor Agent / 临时 Shell 里执行 `python3 cua-router.py &` **会在 Shell 退出时被 SIGHUP 杀掉**，表现为执行中途 `Connection refused`、日志反复出现 `listening on 18901`。

**正确做法**：用 `nohup` 脱离终端，并写入 pid 文件，整个会话复用同一实例。

#### 推荐：daemon.sh（一键 start / status / stop / restart）

```bash
SKILL_ROOT="/path/to/cua-router-basic"   # 替换为实际技能根目录
bash "$SKILL_ROOT/scripts/daemon.sh" start    # 未运行时启动，已健康则跳过
bash "$SKILL_ROOT/scripts/daemon.sh" status   # 检查健康与 pid
bash "$SKILL_ROOT/scripts/daemon.sh" restart    # 卡死时重启
bash "$SKILL_ROOT/scripts/daemon.sh" stop       # 停止
```

`daemon.sh start` 会：检查 `/exec` 健康 → vendor 缺失时自动 bootstrap（ChatGPT 提取或 Release 下载）→ `nohup` 启动 → 等待就绪（最多 45s）。

#### 手动启动（等价于 daemon.sh start）

```bash
SKILL_ROOT="/path/to/cua-router-basic"
nohup python3 "$SKILL_ROOT/scripts/cua-router.py" --port 18901 \
  >> /tmp/cua-router.log 2>&1 &
echo $! > /tmp/cua-router.pid
```

首次运行前若 vendor 缺失，`daemon.sh start` 会自动 bootstrap；也可手动执行 `bash "$SKILL_ROOT/scripts/install-full.sh"`。

#### Agent 执行 sky 操作前的标准流程

```bash
SKILL_ROOT="/path/to/cua-router-basic"
bash "$SKILL_ROOT/scripts/daemon.sh" start   # exec.sh 会自动调用，也可手动确保在线
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
```

推荐优先用 `exec.sh` 发 `/exec` 请求，避免手写 curl + JSON 转义。同一对话/session 内**不要重复启动** cua-router；只有 `status` 失败或 `Connection refused` 时再 `restart`。

#### 检查是否在线

```bash
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
# 输出 ok 表示在线
```

等价 curl：

```bash
curl -s -X POST http://localhost:18901/exec \
  -H 'Content-Type: application/json' \
  -d '{"code": "nodeRepl.write(\"ok\")", "timeout_ms": 5000}'
```

返回 `{"content":[{"type":"text","text":"ok"}]}` 表示在线。

#### 前台调试（仅本地手动调试时用）

```bash
bash "$SKILL_ROOT/scripts/start.sh"
```

`start.sh` 前台运行，**不适合** Agent 自动化场景。

## Bootstrap sky

`cua-router.py` 会在**首次** `/exec` 时自动 bootstrap sky，通常无需手动执行。

仅在自动 bootstrap 失败、或需要显式确认时，可手动发送：

```bash
export SKILL_ROOT="/path/to/cua-router-basic"
bash "$SKILL_ROOT/scripts/exec.sh" -t 20000 \
  "const { setupComputerUseRuntime } = await import('$SKILL_ROOT/scripts/computer-use-client.mjs'); await setupComputerUseRuntime({ globals: globalThis }); nodeRepl.write('bootstrapped');"
```

已 bootstrap 的 node_repl 会话若重复 import 可能报 `"already declared"`，可忽略。

## 执行 JS 与读取结果

#### ⚠️ 必须通过 `nodeRepl.write()` 输出

node_repl **不会**把代码块的最后一条表达式回传给 `/exec` HTTP 响应。以下写法 HTTP 响应永远是 `"text": ""`，即使 `get_app_state()` 在段内已成功：

```js
// ❌ 错误：Agent 会看到空响应
{
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  s.text.slice(0, 8000);
}
```

正确写法：

```js
// ✅ 需要把结果传回 Agent 时
{
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  nodeRepl.write(JSON.stringify({
    url: (s.text.match(/URL: ([^\s,\n]+)/) || [, ""])[1],
    textLen: s.text.length,
    preview: s.text.slice(0, 2000),
  }));
}
```

区分两种场景：

| 场景 | 是否需要 `nodeRepl.write` |
|------|---------------------------|
| 同一段 `/exec` 代码内用 `s.text` 找元素并 click/set_value | 否（段内变量即可） |
| 把 AX Tree / URL / 截图路径传回 Agent 或 Shell | **是** |

截图在 `s.screenshot.url`（本地 `file://` 路径），同样不会自动出现在 HTTP 响应中，需 `nodeRepl.write` 传出。

#### exec.sh 用法

```bash
SKILL_ROOT="/path/to/cua-router-basic"

# 健康检查（默认只打印 content[0].text）
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'

# 读取 AX Tree 摘要
bash "$SKILL_ROOT/scripts/exec.sh" -t 60000 \
  '{ const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true }); nodeRepl.write(JSON.stringify({ textLen: s.text.length, url: (s.text.match(/URL: ([^\s,\n]+)/)||[,""])[1] })); }'

# 从文件执行、输出完整 JSON
bash "$SKILL_ROOT/scripts/exec.sh" --json -f "$SKILL_ROOT/scripts/example.js"

# 不自动启动 cua-router
bash "$SKILL_ROOT/scripts/exec.sh" --no-start 'nodeRepl.write("ok")'
```

选项：`-t MS` 超时、`--json` 完整响应、`--text` 仅文本（默认）、`-f FILE` 从文件读代码。

## 安装到 Cursor 并置顶 `/` 菜单

```bash
SKILL_ROOT="/path/to/cua-router-basic"
bash "$SKILL_ROOT/scripts/install-cursor.sh"
```

脚本会：

1. 软链到 `~/.cursor/skills/cua-router-basic`（指向 `$SKILL_ROOT`）
2. 写入 Cursor 全局状态 `cursor/glass.pinnedItems.v1`，Pin 该技能
3. 更新 `cursor.skills.recentlyUsed`，提升 `/` 菜单排序

安装后若 `/` 列表未刷新，执行 **Developer: Reload Window** 重载 Cursor 窗口。

取消 Pin（保留软链）：

```bash
bash "$SKILL_ROOT/scripts/install-cursor.sh" --unpin
```

## 辅助函数

以下函数可在任意 `/exec` 代码块中直接使用（粘贴到代码开头即可）：

#### findIdx — 从 AX Tree 文本按关键字定位 element_index

**必须在完整 `axText` 上搜索**，禁止按 idx 区间切片（如 `20-80`）。弹层、对话框、Portal 节点常挂在**高 idx**（如 #313），低区间扫描必然漏掉。

```js
function findIdx(axText, ...keywords) {
  const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
  if (!line) return null;
  return parseInt(line.match(/^\s*(\d+)/)[1]);
}
```

#### findAllIdx — 列出所有匹配行（弹层候选）

```js
function findAllIdx(axText, ...keywords) {
  return axText.split("\n")
    .filter(l => keywords.every(k => l.includes(k)))
    .map(l => ({ idx: parseInt(l.match(/^\s*(\d+)/)[1]), line: l.trim() }));
}
```

#### findFocusedIdx — 读取当前焦点元素（对话框常自动聚焦）

```js
function findFocusedIdx(axText) {
  const focusedLine = axText.split("\n").find(l => /focused UI element is/.test(l));
  return focusedLine ? parseInt(focusedLine.match(/\b(\d+)\b/)?.[1]) : null;
}
```

用法示例（同一段 `/exec` 内完成查找与点击，无需 `nodeRepl.write`）：

```js
{
  function findIdx(axText, ...keywords) {
    const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
    if (!line) return null;
    return parseInt(line.match(/^\s*(\d+)/)[1]);
  }
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const btnIdx = findIdx(s.text, "创建工作流", "按钮");
  await sky.click({ app: "com.google.Chrome", element_index: btnIdx });
}
```

若需把定位结果传回 Agent：

```js
{
  function findIdx(axText, ...keywords) { /* ... */ }
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const btnIdx = findIdx(s.text, "创建工作流", "按钮");
  nodeRepl.write(JSON.stringify({ btnIdx, url: (s.text.match(/URL: ([^\s,\n]+)/) || [, ""])[1] }));
}
```

#### 获取当前页面 URL

```js
const url = (s.text.match(/URL: ([^\s,\n]+)/) || [, ""])[1];
```

#### 获取 focused 元素 index（对话框自动聚焦时使用）

```js
const idx = findFocusedIdx(s.text);
// 或内联：
const focusedLine = s.text.split("\n").find(l => /focused UI element is/.test(l));
const idx = parseInt((focusedLine || "").match(/\b(\d+)\b/)?.[1]);
```

#### 弹层 / 浮层 / 对话框定位

AX Tree 的 **idx 与视觉层级无关**：主页面内容通常在低 idx，**后渲染的弹层、调试浮层、Modal、Drawer 常 append 到树末尾（高 idx）**。只扫 `idx 20-80` 会系统性漏掉弹层。

**禁止做法**：

```js
// ❌ 按 idx 区间切片 — 弹层在 #313 时完全不可见
const lines = s.text.split("\n").filter(l => {
  const idx = parseInt(l.match(/^\s*(\d+)/)?.[1]);
  return idx >= 20 && idx <= 80;
});
```

**推荐流程**（触发弹层的 click 之后，同一段或下一段 `/exec` 内）：

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

  // 1. 优先看焦点（Modal 打开时常自动聚焦首项）
  const focusedIdx = findFocusedIdx(s.text);

  // 2. 全文关键词搜索 — 在完整 s.text 上，不截断 idx
  const overlayIdx = findIdx(s.text, "调试", "按钮")
    ?? findIdx(s.text, "确定", "按钮")
    ?? findIdx(s.text, "关闭", "按钮");

  // 3. 首次未命中：扩大候选，把匹配行传回 Agent 二次判断
  const overlayKeywords = ["调试", "dialog", "Dialog", "alert", "Modal", "弹窗", "浮层", "sheet"];
  const candidates = overlayKeywords.flatMap(kw => findAllIdx(s.text, kw))
    .filter((c, i, arr) => arr.findIndex(x => x.idx === c.idx) === i)
    .slice(0, 15);

  nodeRepl.write(JSON.stringify({
    textLen: s.text.length,
    focusedIdx,
    overlayIdx,
    candidates,
    hint: candidates.length === 0 ? "expand keywords on full axText, do not slice by idx range" : undefined,
  }));
}
```

**定位策略优先级**：

| 优先级 | 方法 | 适用场景 |
|--------|------|----------|
| 1 | `findFocusedIdx(s.text)` | 对话框打开后焦点已在弹层内 |
| 2 | `findIdx(s.text, …keywords)` 全文搜索 | 已知按钮/标题文案 |
| 3 | `findAllIdx` + 传回 Agent | 首次关键词未命中，需人工选候选 |
| 4 | 读 `s.screenshot.url` 截图 | AX Tree 无弹层节点时的兜底 |

**关键规则**：

- 每次可能弹出浮层的操作后，**必须**重新 `get_app_state({ disableDiff: true })`
- 搜索范围 = **完整** `s.text`，`textLen` 可达数千行；idx 大不代表「不重要」
- 第一次 `findIdx` 返回 `null` **不等于弹层不存在**，应换关键词或 `findAllIdx` 全文检索，**禁止**缩小 idx 区间重试

## 标准操作规范

所有依赖本技能的代码块必须遵守以下规范：

| 操作 | 正确方式 | 禁止方式 |
|------|---------|---------|
| **读取 `/exec` 结果** | `nodeRepl.write(...)` 或 `exec.sh` | 依赖块内最后一条表达式（HTTP 响应恒为空）|
| **URL 导航** | `set_value(addrIdx, url)` + `press_key("Return")` | `press_key("Command+L")` + `type_text(url)`（会混入 `l` 字符）|
| **键盘快捷键** | `press_key({ key: "Command+v" })` 等 keysym 格式；bootstrap 会自动把 `Cmd`/`Meta`/`Ctrl`/`Shift`/`Alt`/`Option` 归一化 | 直接使用 `Cmd+V`、`Meta+v`、`Ctrl+c`（sky 原生不认，会报 `keyNotFound`）|
| **粘贴文本到输入框** | 优先 `set_value(element_index, text)`；剪贴板粘贴用 `Command+v`（或 `Cmd+V`，已自动归一化） | 对不支持 set_value 的控件盲目 `type_text` 中文 |
| **输入中文 / 特殊字符** | `set_value(element_index, text)` | `type_text(text)`（IME 与特殊字符输入异常）|
| **点击按钮 / 链接** | `click({ element_index })` 从 AX Tree 动态定位 | 硬编码坐标（窗口尺寸变化会失效）|
| **双击 / Canvas 节点** | `Escape` → 等 600ms → 对节点内 **`文本`/图片** 子元素 `click({ click_count: 2 })` | 用 `clickCount`；未 Escape；双击 `container`；坐标双击 |
| **变量声明** | 每段代码用 `{ ... }` 块作用域包裹 | 顶层 `const/let/var`（Node REPL session 内重复声明报错）|
| **获取 AX Tree** | `get_app_state({ disableDiff: true })`，每次操作前重新获取 | 省略 `disableDiff: true`（页面无变化时仅返回 "no change" 短文本）；复用旧 AX Tree |
| **元素搜索** | `findIdx` / `findAllIdx` 在**完整** `s.text` 上关键词全文搜索 | 按 idx 区间切片（如 20-80）；假设弹层一定在低 idx |
| **弹层 / 对话框** | 操作后重新取树 → 先 `findFocusedIdx` → 再全文 `findIdx` | 第一次 null 就放弃；只在主内容区低 idx 查找 |
| **触发 UI 刷新后截图** | 先执行任意操作，再 `get_app_state` | 无操作直接调（可能返回旧截图）|

`disableDiff` 说明：默认 `false` 时，若页面 accessibility tree 相对上次无变化，`s.text` 仅为 `"There has been no change in the accessibility tree..."`，**无法用于元素定位**。解析 AX Tree 时必须传 `disableDiff: true` 获取完整树。

#### press_key 键名规范

`sky.press_key({ key })` 使用 **X keysym 风格** 键名，用 `+` 连接组合键（如 `Control_L+c`、`Command+v`、`Return`）。

| 常见写法 | sky 原生是否认 | bootstrap 归一化后 |
|---------|--------------|-------------------|
| `Command+v` / `command+V` | ✅ | — |
| `Super_L+v` | ✅ | — |
| `Cmd+V` / `Meta+v` | ❌ `keyNotFound("Cmd")` | ✅ → `Command+V` |
| `Ctrl+c` / `Control+c` | ❌ | ✅ → `Control_L+c` |
| `Shift+Tab` / `Alt+Tab` / `Option+v` | ❌ | ✅ → `Shift_L+Tab` / `Alt_L+Tab` / `Alt_L+v` |
| `Return` / `Escape` / `F2` | ✅ | — |

归一化在 `scripts/computer-use-client.mjs` 的 bootstrap 层自动完成，**无需**业务代码手动转换。修改该文件后需 `daemon.sh restart` 使新 session 生效。

**粘贴示例**（IM / 聊天输入框）：

```js
{
  const s1 = await sky.get_app_state({ app: "cn.neixin.pc", disableDiff: true });
  const inputIdx = findIdx(s1.text, "文本输入区", "说点什么");
  await sky.click({ app: "cn.neixin.pc", element_index: inputIdx });
  await new Promise(r => setTimeout(r, 400));
  // Cmd+V 会被自动归一化为 Command+V
  await sky.press_key({ app: "cn.neixin.pc", key: "Cmd+V" });
}
```

若控件支持 AX 写入，**仍优先** `set_value`（见下节），比剪贴板粘贴更可靠。

#### set_value 与 type_text 的应用场景

两者底层机制不同，**不可互换**：

| | `set_value` | `type_text` |
|---|-------------|-------------|
| **机制** | 通过 Accessibility API 直接写入元素的 AXValue | 向当前焦点模拟键盘逐字输入 |
| **需要 element_index** | ✅ 必须指定 | ❌ 写入当前焦点，不指定元素 |
| **URL / 特殊字符**（`://`、`?`、`=`） | ✅ 可靠 | ❌ 常丢失（如 `https//` 缺 `:`） |
| **中文 / IME** | ✅ 可靠 | ❌ 组合输入、选字异常 |
| **适用控件** | 原生可编辑控件（地址栏、`<input>`、`<textarea>`） | 仅当控件**不支持** set_value 且无特殊字符时的兜底 |

**决策流程**（按优先级）：

1. **Chrome 地址栏导航** → 只用 `set_value` + `Return`（见下方地址栏示例）
2. **页面普通表单**（AX 行含 `文本栏` + 有意义的 Description/Placeholder/Value）→ 优先 `set_value`
3. **含 URL、中文、符号的内容** → 只用 `set_value`，禁止 `type_text`
4. **`type_text` 仅作最后兜底**：纯 ASCII、无特殊字符、且已 `click` 聚焦目标元素；写入后必须用截图或页面变化验证，**不能**只看 AX Value

#### 常见误判：文本输入区 ≠ 地址栏

Chrome AX Tree 中常有多个 `(settable, string)` 元素，Agent 极易定位错误：

| AX 特征 | 实际控件 | set_value 是否有效 |
|---------|----------|-------------------|
| `Description: 地址和搜索栏` | Chrome 地址栏（Omnibox） | ✅ 有效 |
| `文本栏 … Placeholder/Description: …` | 页面原生 `<input>` | ✅ 通常有效 |
| `文本输入区` / `Description: 编辑器容器` | Monaco、CodeMirror、contenteditable | ❌ **无效**（API 不报错但 Value 不变） |
| `for screen reader` | 辅助技术隐藏字段 | ❌ 跳过 |

典型错误：Agent 看到「文本输入区 (settable, string)」以为可填 URL，对 Monaco 编辑器调用 `set_value` → AX Value 仍为空 → 误判「set_value 不生效」→ 改 `type_text` → `:` 等字符丢失。

**元素定位规则**：

```js
// ✅ 地址栏（URL 导航唯一正确目标）
const addrLine = axText.split("\n").find(l => /settable, string/.test(l) && /地址/.test(l));

// ✅ 页面普通输入框（按 Description/Placeholder 匹配业务字段）
const fieldLine = axText.split("\n").find(l =>
  /settable, string/.test(l) && /关键词/.test(l) && !/地址|编辑器|screen reader|文本输入区/.test(l)
);

// ❌ 禁止用「文本输入区」填 URL 或当作地址栏
const badLine = axText.split("\n").find(l => /文本输入区/.test(l));
```

**写入结果验证**：

- **地址栏 / 原生 input**：可在同一段 `/exec` 内重新 `get_app_state`，检查行内 `Value: …` 是否更新
- **Monaco / 富文本编辑器**：AX Value **不可信**（常为空），须用截图或页面 DOM 变化确认；若 set_value 无效，**不要** fallback 到 type_text 填 URL，应换定位策略或改走地址栏导航

#### Canvas / 流程图节点：双击打开配置面板

Canvas 节点外层是 `container`，父层常为 `contenteditable`。直接对 container 双击会被**文本选中**消费掉，React `onDoubleClick` 不触发。已验证的**标准双击流程**如下（三步缺一不可）：

| 步骤 | 动作 | 说明 |
|------|------|------|
| 1 | `press_key("Escape")` | **必须先**退出 contenteditable 文本编辑/光标模式 |
| 2 | 等待 ~600ms | `await new Promise(r => setTimeout(r, 600))` |
| 3 | `click({ element_index, click_count: 2 })` | 双击节点**内部子元素**，不是 container |

**三个关键规则**：

1. **Escape 是必要的** — 未 Escape 时双击会触发词语选中（`Selected text`），配置面板不会弹出
2. **参数名是 `click_count`**（snake_case），**不是** `clickCount`（camelCase 会被忽略，等同单击）
3. **双击目标是节点内的 `文本` / `未加标签的图片` 子元素**，**不是**外层 `container`

**原因链**（理解为何必须按上述流程）：

| 层级 | 现象 | 机制 |
|------|------|------|
| AX Tree | 节点卡片是 `container`，无 AXPress | 须 fallback 鼠标事件，且须点对子元素 |
| 浏览器 | 父层 contenteditable 有焦点 | 双击 = 词语选中；Escape 先退出编辑态 |
| API | 传 `clickCount` 无效 | sky 只认 `click_count`（见 `ClickInput.click_count`） |

**标准代码模板**（同一段 `/exec` 内完成）：

```js
{
  function findIdx(axText, ...keywords) {
    const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
    if (!line) return null;
    return parseInt(line.match(/^\s*(\d+)/)[1]);
  }
  // 找节点内可双击的子元素：精确匹配「文本 N」，其次「未加标签的图片」
  function findNodeDblClickTarget(axText, nodeLabel) {
    const exact = axText.split("\n").find(l =>
      new RegExp(`^\\s+\\d+\\s+文本\\s+${nodeLabel}\\b`).test(l)
    );
    if (exact) return parseInt(exact.match(/^\s*(\d+)/)[1]);
    return findIdx(axText, "未加标签的图片");
  }

  // Step 1: Escape 退出编辑态
  await sky.press_key({ app: "com.google.Chrome", key: "Escape" });
  await new Promise(r => setTimeout(r, 600));

  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });

  // Step 2: 定位节点内子元素（例：节点编号「3」→ 找「文本 3」或图标）
  const targetIdx = findNodeDblClickTarget(s.text, "3")
    ?? findIdx(s.text, "文本", "3")
    ?? findIdx(s.text, "未加标签的图片");

  if (!targetIdx) {
    nodeRepl.write(JSON.stringify({ error: "node dblclick target not found", hint: "search full axText for 文本 N or 未加标签的图片" }));
  } else {
    // Step 3: click_count: 2 双击（必须是 snake_case）
    await sky.click({ app: "com.google.Chrome", element_index: targetIdx, click_count: 2 });
    await new Promise(r => setTimeout(r, 1500));

    const s2 = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
    const panelLines = s2.text.split("\n").filter(l =>
      /LLM|属性定义|捕获|新建/.test(l) && (/按钮/.test(l) || /文本栏/.test(l))
    );
    nodeRepl.write(JSON.stringify({
      dblclickTarget: targetIdx,
      panelOpened: panelLines.length > 0,
      panelLines: panelLines.slice(0, 10),
    }));
  }
}
```

**禁止做法**：

```js
// ❌ camelCase — click_count 被忽略，等同单击
await sky.click({ app: "com.google.Chrome", element_index: 284, clickCount: 2 });

// ❌ 未 Escape 直接双击 container
await sky.click({ app: "com.google.Chrome", element_index: 57, click_count: 2 });

// ❌ 坐标双击 — 仍会被 contenteditable 词语选中消费
await sky.click({ app: "com.google.Chrome", x: 560, y: 360, click_count: 2 });
```

**失败后的 fallback**（标准流程仍无效时）：

| 优先级 | 做法 |
|--------|------|
| 1 | 确认已 Escape + 用的是 `click_count` + 目标是 `文本`/图片子元素 |
| 2 | 全文搜索工具栏等价按钮（`findIdx(s.text, "编辑", "按钮")`） |
| 3 | 单击选中节点 + `press_key("Return")` / `F2` |
| 4 | 上报阻塞，附 `findAllIdx` 候选供用户判断 |

**验证双击成功**：重新 `get_app_state` 后应出现配置面板相关节点（如「捕获」「新建 LLM」「属性定义」等按钮/文本栏）。若出现 `Selected text` 说明未 Escape 或点错了 container。

#### 地址栏 index 获取（Chrome URL 导航标准方式）

```js
{
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const addrLine = s.text.split("\n").find(l => /settable, string/.test(l) && /地址/.test(l));
  const addrIdx = parseInt((addrLine || "10 ").match(/^\s*(\d+)/)[1]);
  await sky.set_value({ app: "com.google.Chrome", element_index: addrIdx, value: "https://example.com" });
  await sky.press_key({ app: "com.google.Chrome", key: "Return" });
}
```

## 其他技能如何参照本技能

在新技能的 `SKILL.md` 中，**依赖**章节只需写：

```markdown
## 依赖

参照 `cua-router-basic` 技能的依赖说明和启动方式。
sky bootstrap 代码和辅助函数（findIdx 等）见 `cua-router-basic` 技能。
```

操作规范章节同理：

```markdown
## 操作规范

遵循 `cua-router-basic` 技能的标准操作规范（nodeRepl.write 输出、disableDiff、URL 导航、set_value 输入、块作用域等）。
```

新技能的 SKILL.md 只需聚焦**业务流程**，公共部分统一引用本技能，避免重复描述。
