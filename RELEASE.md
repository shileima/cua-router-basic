# 版本发布记录

本文件维护每次发版的**版本锚点**与**迭代功能摘要**。发版流程（beta 试用、正式发布、回滚）见 [`docs/release-workflow.md`](docs/release-workflow.md)。

## 维护约定

每次发版（含 beta）在表格与下方详情中**追加一条**，不要改 `release-workflow.md` 里的版本历史。

| 时机 | 动作 |
|---|---|
| beta 试用 | 追加 `x.y.z-beta.N` 行 + 可选简短说明 |
| 正式发布 | 追加 `x.y.z` 行；若 beta 已写过摘要，正式版可合并 beta 条目 |
| GitHub Release | 可将下方对应版本的「详情」复制为 release notes，或用 `release.sh --notes RELEASE.md` 截取 |

## 版本锚点（摘要）

| 版本 | 关键变化 |
|---|---|
| **0.4.30** | 回放动作等价约束：禁止用最终 URL 替代页面内搜索/筛选/表单操作；Chrome/Safari 地址栏写入保护 |
| **0.4.29** | record-desk-basic 强化回放执行纪律（每 action 操作前/后审视 AX Tree、验证上一步、禁止跳步）；安装流程提前同步 companion 技能 |
| **0.4.28** | 启动前端口自愈清理（18901/18902 被占用时自动清理，无需手动 kill/FORCE_TAKEOVER）；安装后自动唤起「Enable ChatGPT Computer Use」授权窗 |
| **0.4.27** | 新增 `/cua` 结构化端点 + `SKY_TRANSPORT` 传输模式（node_repl/mcp）；兼容 codex 0.148+ 沙箱（vendor 回退 + process 垫片） |
| **0.4.9-beta.2** | 新增 `ax.get({maxAgeMs})` + `ax._stats()` / `ax._resetStats()` 应对轮询异步 UI |
| **0.4.9-beta.1** | 引入 `globalThis.ax` + sky wrapper 自动失效缓存 |
| 0.4.8 | 无 AX 缓存 |
| 0.5.0（预留） | beta 稳定后的第一个正式版号；应包含 beta.1/beta.2 的所有变化 |

---

## 详情

### 0.4.30

- **动作等价约束**：回放必须复刻录制中的动作类型；页面内搜索框、筛选按钮、表单提交不得折叠为直接打开最终 URL。
- **地址栏保护**：Chrome/Safari 普通文本输入默认不得写入顶部导航地址栏；仅明确的 URL 导航动作才允许地址栏 `set_value` + Return。
- **文档同步**：`SKILL.md`、`record-desk-basic` 技能与模板（`event-stream.md`、`replay-skill-template.md`）统一上述纪律。

### 0.4.29

- **record-desk-basic**：强化回放执行纪律——每个 action 操作前/后审视 AX Tree、验证上一步结果、禁止跳步。
- **安装流程**：提前同步 companion 技能（record-desk-basic 等）。

### 0.4.28

- **端口自愈**：18901/18902 被占用时自动清理，无需手动 `kill` 或 `FORCE_TAKEOVER`。
- **授权引导**：安装后自动唤起「Enable ChatGPT Computer Use」授权窗。

### 0.4.27

- **结构化端点**：新增 `/cua` HTTP 端点。
- **传输模式**：`SKY_TRANSPORT` 支持 `node_repl` / `mcp`。
- **codex 兼容**：兼容 codex 0.148+ 沙箱（vendor 回退 + process 垫片）。

### 0.4.9（beta.1 → beta.2，未正式 release）

本系列核心是引入 AX Tree 缓存与自动失效机制，在保持定位正确性的前提下大幅减少 `sky.get_app_state` 调用；同时提供轮询异步 UI 场景的兜底方案，并补齐维护者文档。

**beta.1**

- 引入 `globalThis.ax`（`get / invalidate / findIdx / findAllIdx / findFocusedIdx / linesMatching / summarize`）。
- `ax.get(app)` 内部固定 `disableDiff:true`，跨 `/exec` 缓存。
- sky 交互（click、scroll、type_text 等）后自动 invalidate 对应 app 缓存。
- Node 单元测试 0 → 23 用例。

**beta.2**

- `ax.get(app, { maxAgeMs })`：缓存年龄 ≥ N ms 判定陈旧，兜住外部触发未 refresh 的异步 UI 场景。
- `ax._stats()` / `ax._resetStats()` 调试接口。
- `references/ax-locating.md` 新增「轮询等待异步 UI 更新」章节。

**升级注意**

- 改 `computer-use-client.mjs` 后必须 `daemon.sh restart`。
- 轮询异步 UI 勿用普通 `ax.get(app)`，推荐 `{ maxAgeMs: 300 }` 或 `{ refresh: true }`。

### 0.4.8 及之前

- 无 AX 缓存；每次 `sky.get_app_state({ app, disableDiff: true })` 都是真 RPC。
