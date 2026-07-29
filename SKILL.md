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

  开发新的 sky/cua-router 技能时，使用本技能作为公共规范参照，不需要在每个技能里重复描述依赖和操作规范。
  本技能不直接执行业务操作，只提供依赖说明、初始化代码和操作规范。
  Agent 在技能或 vendor 未安装时应先执行下方「Agent 安装」章节，再执行业务操作。
---

# cua-router-basic — sky Computer Use 基础规范

本技能是所有依赖 cua-router + sky Computer Use API 的技能的**公共基础**，统一管理依赖声明、初始化流程、辅助函数和操作规范。新技能开发时直接参照本文件，无需重复描述。

## Agent 安装（首次使用）

Agent 在执行任何 sky/cua-router 操作前，**必须先确认技能与 vendor 已就绪**。若 `$SKILL_ROOT/SKILL.md` 不存在，或 `$SKILL_ROOT/vendor/codex/bin/codex` 不可执行，按以下流程自动安装（无需用户手动 git clone）。

`SKILL_ROOT` 默认路径：`~/.cursor/skills/cua-router-basic`（可通过 `CUA_ROUTER_INSTALL_DIR` 覆盖）。

#### 方式 A：远程一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
```

安装完成后脚本会输出 `SKILL_ROOT=...`，后续命令均基于该路径。

#### 方式 B：技能目录已存在，仅缺 vendor

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-$HOME/.cursor/skills/cua-router-basic}"
bash "$SKILL_ROOT/scripts/install-full.sh" --vendor-mode auto
```

#### 方式 C：Cursor / Claude Code Plugin 安装

- **Cursor**：`/add-plugin shileima/cua-router-basic`（或从 Plugin 市场安装）
- **Claude Code**：`/plugin install cua-router-basic@cua-router-basic-dev`（需先添加本仓库 marketplace）

Plugin 仅注册 slim 技能包；**首次使用前仍需 vendor bootstrap**（`daemon.sh start` 或 `install-full.sh` 会自动完成）。

#### 安装后验证

```bash
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-$HOME/.cursor/skills/cua-router-basic}"
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
| `{SKILL_ROOT}/scripts/install-remote.sh` | Agent 远程一键安装（slim + vendor + Cursor 注册） |
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

```js
function findIdx(axText, ...keywords) {
  const line = axText.split("\n").find(l => keywords.every(k => l.includes(k)));
  if (!line) return null;
  return parseInt(line.match(/^\s*(\d+)/)[1]);
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
const focusedLine = s.text.split("\n").find(l => /focused UI element is/.test(l));
const idx = parseInt((focusedLine || "").match(/\b(\d+)\b/)?.[1]);
```

## 标准操作规范

所有依赖本技能的代码块必须遵守以下规范：

| 操作 | 正确方式 | 禁止方式 |
|------|---------|---------|
| **读取 `/exec` 结果** | `nodeRepl.write(...)` 或 `exec.sh` | 依赖块内最后一条表达式（HTTP 响应恒为空）|
| **URL 导航** | `set_value(addrIdx, url)` + `press_key("Return")` | `press_key("Cmd+L")` + `type_text(url)`（会混入 `l` 字符）|
| **输入中文 / 特殊字符** | `set_value(element_index, text)` | `type_text(text)`（IME 与特殊字符输入异常）|
| **点击按钮 / 链接** | `click({ element_index })` 从 AX Tree 动态定位 | 硬编码坐标（窗口尺寸变化会失效）|
| **变量声明** | 每段代码用 `{ ... }` 块作用域包裹 | 顶层 `const/let/var`（Node REPL session 内重复声明报错）|
| **获取 AX Tree** | `get_app_state({ disableDiff: true })`，每次操作前重新获取 | 省略 `disableDiff: true`（页面无变化时仅返回 "no change" 短文本）；复用旧 AX Tree |
| **触发 UI 刷新后截图** | 先执行任意操作，再 `get_app_state` | 无操作直接调（可能返回旧截图）|

`disableDiff` 说明：默认 `false` 时，若页面 accessibility tree 相对上次无变化，`s.text` 仅为 `"There has been no change in the accessibility tree..."`，**无法用于元素定位**。解析 AX Tree 时必须传 `disableDiff: true` 获取完整树。

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
