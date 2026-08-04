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

## Bootstrap sky

`cua-router.py` 会在首次 `/exec` 时自动 bootstrap sky。仅在自动 bootstrap 失败或需要显式确认时手动执行：

```bash
bash "$SKILL_ROOT/scripts/exec.sh" -t 20000 \
  "const { setupComputerUseRuntime } = await import('$SKILL_ROOT/scripts/computer-use-client.mjs'); await setupComputerUseRuntime({ globals: globalThis }); nodeRepl.write('bootstrapped');"
```

重复 import 可能报 `already declared`，可忽略。

## 必须通过 `nodeRepl.write()` 输出

node_repl 不会把最后一条表达式作为 HTTP 响应返回。

错误示例：

```js
{
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  s.text.slice(0, 8000);
}
```

正确示例：

```js
{
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  nodeRepl.write(JSON.stringify({
    url: (s.text.match(/URL: ([^\s,\n]+)/) || [, ""])[1],
    textLen: s.text.length,
    preview: s.text.slice(0, 2000),
  }));
}
```

## exec.sh 常用方式

```bash
# 健康检查
bash "$SKILL_ROOT/scripts/exec.sh" 'nodeRepl.write("ok")'

# 读取 AX Tree 摘要
bash "$SKILL_ROOT/scripts/exec.sh" -t 60000 \
  '{ const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true }); nodeRepl.write(JSON.stringify({ textLen: s.text.length, url: (s.text.match(/URL: ([^\s,\n]+)/)||[,""])[1] })); }'

# 从文件执行
bash "$SKILL_ROOT/scripts/exec.sh" --json -f "$SKILL_ROOT/scripts/example.js"
```

## Chrome 地址栏导航

```js
{
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const addrLine = s.text.split("\n").find(l => /settable, string/.test(l) && /地址/.test(l));
  const addrIdx = parseInt((addrLine || "10 ").match(/^\s*(\d+)/)[1]);
  await sky.set_value({ app: "com.google.Chrome", element_index: addrIdx, value: "https://example.com" });
  await sky.press_key({ app: "com.google.Chrome", key: "Return" });
}
```
