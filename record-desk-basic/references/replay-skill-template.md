# 回放技能模板（依赖 cua-router-basic 高效执行）

由录制生成的回放技能应**依赖 cua-router-basic**，用 `sky.*` + `ax.*` 执行，而不是坐标盲点。这样更准、更快、更抗 UI 漂移。

> **完整性原则**：回放步骤必须**严格覆盖录制里的全部结构性动作**，从打开/激活应用、地址栏导航等前置动作，一直到保存与结果校验，逐步复刻、不删减不跳步（对齐 `codex-record-skill`）。只把随场景变化的演示值抽成输入参数，动作与其顺序保持不变。

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

## 回放步骤

遵循 `cua-router-basic` 主文件核心操作规范。**按录制时间线逐个动作展开为一个步骤，严格覆盖完整链路**（含打开/激活应用、导航等前置动作，不假设已在目标页面）。每步：定位 → 交互 → 验证。

1. 打开/激活目标应用并导航到起始页（如地址栏输入 URL）——这也是录制的一部分，必须写出来。
2. 用地址栏/应用状态定位目标窗口：`ax.get("<bundleId>")` → `ax.findIdx(...)`。
3. 交互用 `sky.click / sky.set_value / sky.press_key`（URL/中文优先 `set_value`）。
4. 关键步骤后 `ax.get(app)` 校验结果，避免坐标盲点。
   - AX 缺失时按 AX → hover → OCR → 坐标扫描 降级（见 cua-router-basic `references/ax-locating.md`）。
5. 最后一步做结果校验（如出现「已保存」或目标节点文本），与录制的收尾动作对应。
```

## 从事件到步骤的映射建议

| 录制事件 | 回放写法 |
|---|---|
| 点击某按钮（有 AX target） | `ax.findIdx(s.text, "<按钮文案>")` → `sky.click({ app, x, y })` |
| 在输入框输入文本/URL | `sky.set_value(idx, "<值或参数>")` +（URL 时）`press_key("Return")` |
| hover 后才出现的菜单 | 先 swift 移动鼠标触发 hover，再点热区（cua-router-basic `references/hover-menu.md`） |
| Canvas / React Flow 双击 | `Escape` → 等 600ms → 对节点内文本 `click_count: 2`（`references/canvas-double-click.md`） |
| 纯视觉校验/无稳定 AX target | 保留坐标兜底，但必须配 OCR/AX 二次确认 |

## 校验

- 用 `skill-creator` 规范校验生成技能结构完整、可发现。
- 回放技能必须能在 cua-router-basic 运行时下实际跑通，而不仅是结构合法。
