# 启动、Bootstrap 与执行

## 禁止裸 `&` 后台启动

不要在临时 Shell 中执行 `python3 cua-router.py &`，Shell 退出会导致服务被 SIGHUP 杀掉。统一使用 `daemon.sh`。

## 启动与检查

```bash
SKILL_ROOT="/path/to/cua-router-basic"
bash "$SKILL_ROOT/scripts/daemon.sh" start
bash "$SKILL_ROOT/scripts/daemon.sh" status
bash "$SKILL_ROOT/scripts/daemon.sh" restart
bash "$SKILL_ROOT/scripts/daemon.sh" stop
```

健康检查：

```bash
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'
```

输出 `ok` 表示在线。

## Chrome 预检（Playwright 干扰）

当 `exec.sh` 执行的 JS 涉及 `com.google.Chrome` 或 `"Google Chrome"` 时，会自动调用 `scripts/lib/preflight-chrome.sh`。

典型故障：Playwright 以 `--no-startup-window` 占用 Chrome，`get_app_state` 报 `-10005: timeoutReached`。

```bash
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" status
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" fix
```

`CUA_ROUTER_CHROME_PREFLIGHT` 控制行为：

- `auto`（`exec.sh` 默认）：检测到 Playwright Chrome 或无窗口时自动修复
- `warn`（`daemon.sh start` 使用）：仅 stderr 警告，不阻断
- `off`：跳过

手动修复等价于：

```bash
export CUA_ROUTER_CHROME_PREFLIGHT=auto
bash "$SKILL_ROOT/scripts/lib/preflight-chrome.sh" fix
```

## Bootstrap sky 与 ax

`cua-router.py` 会在首次 `/exec` 时自动 bootstrap，同时把两个全局挂到 `globalThis`：

- `sky.*`：Computer Use 原生 API（`press_key` 归一化 + mutation 后自动失效 AX 缓存）。
- `ax.*`：AX Tree helpers（`get / invalidate / findIdx / findAllIdx / findFocusedIdx / linesMatching / summarize`）。

`ax.get(app)` 内部固定 `disableDiff:true`，且缓存跨 `/exec` 有效；任何 `sky` 交互调用后对应 app 缓存会自动失效，下次 `ax.get(app)` 会重新拉。修改 `computer-use-client.mjs` 后需 `daemon.sh restart` 才能加载新版。

仅在自动 bootstrap 失败或需要显式确认时手动执行：

```bash
bash "$SKILL_ROOT/scripts/exec.sh" -t 20000 \
  "const { setupComputerUseRuntime } = await import('$SKILL_ROOT/scripts/computer-use-client.mjs'); await setupComputerUseRuntime({ globals: globalThis }); nodeRepl.write('bootstrapped:' + (typeof ax));"
```

`/exec` 会自动把每段 JS 包进独立块级作用域。重复执行包含顶层 `const` / `let` / `class` 的命令时，不应再出现 `Identifier ... has already been declared` 这类 REPL 变量污染错误。

## 必须通过 `nodeRepl.write()` 输出

node_repl 不会把最后一条表达式作为 HTTP 响应返回。

每次 `/exec` 都会自动隔离作用域；命令里仍推荐使用局部 `const` / `let`，无需为了重复执行改成全局变量。

错误示例（返回值被丢弃，且回传大 payload 风险）：

```js
{
  const s = await ax.get("com.google.Chrome");
  s.text.slice(0, 8000);
}
```

正确示例（用 `ax.summarize` 收敛输出）：

```js
{
  const s = await ax.get("com.google.Chrome");
  nodeRepl.write(JSON.stringify(ax.summarize(s, { textPreview: 2000 })));
}
```

## exec.sh 常用方式

```bash
# 健康检查
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'

# 读取 AX Tree 摘要（走 ax.get 命中缓存 + summarize 收敛输出）
bash "$SKILL_ROOT/scripts/exec.sh" -t 60000 \
  '{ const s = await ax.get("com.google.Chrome"); nodeRepl.write(JSON.stringify(ax.summarize(s))); }'

# 从文件执行
bash "$SKILL_ROOT/scripts/exec.sh" --json -f "$SKILL_ROOT/scripts/example.js"
```

## Chrome 地址栏导航

```js
{
  const s = await ax.get("com.google.Chrome");
  const addrIdx = ax.findIdx(s.text, "settable, string", "地址");
  await sky.set_value({ app: "com.google.Chrome", element_index: addrIdx, value: "https://example.com" });
  await sky.press_key({ app: "com.google.Chrome", key: "Return" });
}
```
