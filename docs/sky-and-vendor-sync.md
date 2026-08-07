# sky API 变更 与 vendor 同步指南

任何 vendor 变动（升级 codex / cua_node / sky）都可能影响 `computer-use-client.mjs` 的 wrapper 白名单和 `press_key` 归一化逻辑。本文档给出**判断影响面 + 适配步骤**。

## Vendor 三大件

```
vendor/
├── codex/bin/codex                                 # ③ app-server 二进制
├── cua_node/                                       # ④ node_repl + @oai/sky
│   ├── bin/node
│   ├── bin/node_repl
│   └── lib/node_modules/@oai/sky/                  # ← 我们 wrap 的对象
│       └── dist/project/cua/sky_js/src/targets/mac/create_client.js
├── computer-use/
│   └── Codex Computer Use.app/                     # ⑤ 桌面 client（含 SkyComputerUseClient）
└── manifest.json                                   # sha256 校验
```

## 何时需要同步 vendor

| 触发条件 | 影响 |
|---|---|
| ChatGPT.app 升级、内置 codex 有新版 | codex + cua_node 需要重新 setup |
| macOS 通过"设置 → 桌面 Computer Use 插件"更新 | `Codex Computer Use.app` 需要重新 setup |
| 某些 sky RPC 报 `version mismatch` / `incompatible` | 强制升级 vendor |
| 出现 `Native pipe startup failed` / `service startup request failed` | 常见 vendor 与 CUAService 不一致 |
| 开发新技能发现调用某 sky 方法说 "unknown tool" 或参数拒绝 | sky 版本变了 |

## 同步流程（从本机 ChatGPT.app 提取）

```bash
# 前置：ChatGPT.app 已装、Computer Use 插件已在 ChatGPT 里成功用过一次
# （否则 ~/.codex/computer-use/ 里没有 Codex Computer Use.app）

cd /Users/shilei/code/cua-router-basic
bash scripts/setup-vendor.sh           # 复制 codex + cua_node + Codex Computer Use.app
bash scripts/daemon.sh restart
bash scripts/exec.sh 'nodeRepl.write("cua-ready=" + typeof ax)'   # 期望: object
```

`setup-vendor.sh` 会：
1. 从 `/Applications/ChatGPT.app/Contents/Resources/` 提取 `codex` + `cua_node`
2. 从 `~/.codex/computer-use/` 提取 `Codex Computer Use.app`
3. 计算 `SkyComputerUseClient` 的 sha256 写入 `vendor/manifest.json`
4. 打印 `codex --version` 供人肉核对

若无 ChatGPT.app（例如 CI），走 `download-vendor.sh` 从 release 拉预打包 vendor。

## 同步后必做的适配检查

### 1. sky 客户端导出方法对比

sky 客户端的关键实现：

```
vendor/cua_node/lib/node_modules/@oai/sky/dist/project/cua/sky_js/src/targets/mac/create_client.js
```

`create_client({ target: "mac" })` 返回的对象上，我们目前依赖以下方法：

```js
// mutation 类（会改变 AX 树）
click, double_click, right_click, drag, scroll,
set_value, type_text,
press_key, key_down, key_up,
hover, mouse_move,

// 读取类
get_app_state, list_apps, screenshot,
```

**流程**：

```bash
node -e '
  const m = require("./vendor/cua_node/lib/node_modules/@oai/sky/dist/project/cua/sky_js/src/targets/mac/create_client.js");
  const c = m.create_client({ target: "mac" });
  console.log(Object.keys(c).sort().join("\n"));
'
```

对比输出与 `AX_MUTATING_METHODS` 白名单（在 `scripts/computer-use-client.mjs`）。

**决策规则**：

| 新方法名字包含 | 判定 | 处理 |
|---|---|---|
| `click / drag / scroll / hover / press / key / type / set_value / drop / swipe / pinch / mouse` | **mutation** | 加入 `AX_MUTATING_METHODS` + 补测试 |
| `list_ / get_ / query_ / read_ / screenshot / dump` | 只读 | 不 wrap，透传 |
| 不确定 | 需读源码或 doc | 若无法判断，宁可当 mutation 处理（宁可白发一次 RPC，也不留缓存陈旧空间） |

**参数校验方式变化**：sky 新版可能对某些字段收紧校验（比如 `app must be a plain data property`）。wrapper 不做参数校验，直接透传，若报错文档在 [`troubleshooting.md`](./troubleshooting.md) 记录。

### 2. press_key 别名扩展

`normalizePressKey` 只归一化以下别名：

```
cmd/command/meta/super → Command
ctrl/control           → Control_L
shift                  → Shift_L
alt/option             → Alt_L
```

若 sky 新版接受更多别名（比如 `Win`, `Fn`），可以选择：
- 补充 `ALIASES` 表
- 或维持现状（sky 原生已认的 key 会直接透传）

**红线**：不能把 sky 已原生认可的 key 归一化成别的（比如把 `Return` 归成 `Enter`），否则会破坏调用。

### 3. `get_app_state` 语义变化检查

我们 wrapper 依赖：
- `input.app: string`
- `input.disableDiff: boolean`
- 返回的 `state.text: string`（完整 AX Tree 文本）

若 sky 新版：
- 改字段名（比如 `bundleId` 代替 `app`）→ 更新 `writeCacheEntry` 判定条件与 `ax.get` 传参
- 改返回结构（比如 `state.ax: string` 代替 `state.text`）→ 更新所有 `findIdx / summarize` helper 内部对 `state.text` 的引用
- 引入新参数（比如 `format: "yaml"`）→ 明确默认值，保持 disableDiff 语义

**关键**：任何返回结构变化后必须重跑 23 用例单元测试 + 手工在真 Chrome 上跑一次 `ax.get + findIdx + sky.click` 全链路。

### 4. `sky.screenshot` / `list_apps` 等只读方法

- 只读方法**不 wrap**，通过 `{ ...sky, ...overrides }` 透传。
- 但要留意：如果只读方法内部有副作用（比如 `list_apps` 触发焦点切换），当前 wrapper **不会失效缓存**，会成为潜在 R1.1 风险源。经验上目前的只读方法都无副作用，若发现例外要单独加进白名单。

### 5. `Codex Computer Use.app` / CUAService 变化

sky_js 层可能没变但底层 native pipe 协议变了，症状：
- `-10005: timeoutReached` 频繁
- `Native pipe startup failed`
- `Sky RPC deadline exceeded`

处理：`bash scripts/setup-vendor.sh` 强制重新提取 + `daemon.sh restart`；同时更新 `vendor/manifest.json` 的 `sky_client_sha256`。

## 白名单更新示范

假设 sky 新增 `pinch` 方法：

```diff
 const AX_MUTATING_METHODS = Object.freeze([
   "click",
   "double_click",
   "right_click",
   "drag",
   "scroll",
+  "pinch",           // 新增：多指缩放，会改变缩放态 UI
   "set_value",
   ...
 ]);
```

补测试：

```js
test("wrapSkyClient: pinch 后自动失效对应 app 缓存", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  mock.pinch = async (input) => ({ ok: true, input });
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state ?? 1, 1);

  await sky.pinch({ app: "com.google.Chrome", scale: 1.5, x: 100, y: 100 });

  await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state, 2);
});
```

## codex app-server 升级

`codex app-server` 输出的 JSON-RPC 协议变化 → 影响 `cua-router.py` 的 `_req / _read_loop / mcpServer/tool/call` 消息格式。

**排查路径**：
1. `daemon.sh restart` 后 `tail /tmp/cua-router.log` 看 `[app-server:stderr]` 日志
2. 若 `initialize` / `thread/start` 阶段挂 → 协议不兼容
3. 参考 `cua-router.py` 里的 `SKY_BOOTSTRAP` / `SKY_READINESS_PROBE` 常量，确保 params 字段名与新版 app-server 一致

## 兼容性策略

- **对上层用户 API 尽量兼容**：`ax.*` 与 `sky.*` 的接口是我们对外承诺。sky 层变了尽量在 wrapper 内吸收。
- **`ax.get(app)` 返回结构就是 `{ text, screenshot?, ... }`**：即使 sky 返回结构变了，wrapper 也应在 `ax.get` 里适配回同一种结构，避免上层用户代码大改。
- **回退开关**：若 wrapper 出错影响主流程，可在 `setupComputerUseRuntime` 里加环境变量 `CUA_ROUTER_AX_HELPERS_OFF=1`，跳过 `ax` 挂载，恢复到原生 sky。目前**没实现**，但保留这个应急路径。

## Checklist：一次典型 vendor 同步

```
[ ] bash scripts/setup-vendor.sh
[ ] node -e 'const m=require("./vendor/.../create_client.js");
              console.log(Object.keys(m.create_client({target:"mac"})).sort().join("\n"))'
[ ] 对比输出与 AX_MUTATING_METHODS，缺失方法评估是否要加
[ ] node --test tests/test_computer_use_client.mjs（23/23 期望）
[ ] bash scripts/daemon.sh restart
[ ] bash scripts/exec.sh 'nodeRepl.write("ax=" + typeof ax + ";stats=" + JSON.stringify(ax._stats()))'
[ ] 跑一次端到端：ax.get → findIdx → sky.click → ax.get 验证
[ ] 若 sky 协议变了，同步更新 references/*.md 里的示例
[ ] 更新 vendor/manifest.json 里的 codex_version / sky_client_sha256
[ ] 记录本次 vendor 版本到 docs/CHANGELOG.md 或 commit message
```
