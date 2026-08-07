# cua-router-basic 维护者文档

面向**维护者**（要改 mjs / py、同步 vendor、发版、排故障）。用户侧的技能使用规范在 [`../SKILL.md`](../SKILL.md) 和 [`../references/`](../references/)。

## 目录

| 文档 | 何时读 |
|---|---|
| [`architecture.md`](./architecture.md) | 想理解整体分层：HTTP → app-server → node_repl → sky → CUAService |
| [`ax-cache-design.md`](./ax-cache-design.md) | 改 `computer-use-client.mjs`、调整缓存/失效/wrapper 语义 |
| [`risks.md`](./risks.md) | 出线上问题、评估新改动引入的风险、复现"缓存陈旧"类 bug |
| [`sky-and-vendor-sync.md`](./sky-and-vendor-sync.md) | sky API 版本升级、vendor 同步、新增 sky 方法要不要 wrap |
| [`release-workflow.md`](./release-workflow.md) | 发新版、beta 试用、本地 automan / cursor / claude 应用、回滚 |
| [`troubleshooting.md`](./troubleshooting.md) | `ax is undefined`、`get_app_state` 超时、缓存陈旧、preflight 失败等 |

## 快速心智模型

```
用户业务代码
   └─ ax.get(app) / sky.click(...)          ← globalThis 上的两组 API
        └─ scripts/computer-use-client.mjs   ← wrap sky + 挂 ax helpers + 管理 AX 缓存
            └─ vendor/cua_node/@oai/sky       ← 原生 sky client（不可改，随 vendor 同步）
                └─ SkyComputerUseClient       ← native pipe + CUAService（受 macOS 权限管控）
```

关键守则：
1. **正确性红线**：`disableDiff:true` 语义不可动；每次 sky 交互后对应 app 缓存必须失效（wrapper 已自动，别绕开）。
2. **性能优化只能减少调用次数**，不能改取树的模式（不能用 diff 换性能）。
3. **改 mjs 后必须 `daemon.sh restart`**，否则 node_repl 沿用旧 bootstrap，改动不生效。
4. **改 sky API 白名单前先读 [`ax-cache-design.md`](./ax-cache-design.md)**，白名单不全会导致缓存陈旧类 bug。
5. **发版走 [`release-workflow.md`](./release-workflow.md)**，4 处版本号必须同步。

## 版本历史锚点

- `0.4.8` 及之前：无 AX 缓存，每次 `sky.get_app_state({app,disableDiff:true})` 都是真 RPC。
- `0.4.9-beta.1`：引入 `globalThis.ax` + wrapper 自动失效缓存。基础功能完成。
- `0.4.9-beta.2`：新增 `ax.get({ maxAgeMs })` 与 `ax._stats()` / `ax._resetStats()`，处理"轮询异步 UI"场景。当前 head。

改动到具体文件的映射见 [`architecture.md#关键文件`](./architecture.md#关键文件)。
