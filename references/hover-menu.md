# hover 触发隐藏菜单

用于卡片右上角 `...`、hover 后才显示的按钮/菜单，且 AX Tree 初始不暴露目标控件的场景。

## 标准流程

1. 先用 `get_app_state({ disableDiff:true })` 或截图确认页面与卡片位置。
2. 用 macOS `swift + CoreGraphics` 把鼠标移动到卡片中心，触发 hover。
3. 用 `sky.click({ x, y })` 点击 hover 后出现的右上角菜单热区。
4. 重新 `get_app_state({ disableDiff:true })` 验证菜单出现。
5. 菜单打开后，优先用菜单项的 `element_index` 点击，不要继续坐标点击菜单项。

## macOS hover 模板

```bash
# 1. 触发 hover：把鼠标移动到目标卡片中心
swift -e 'import CoreGraphics; import Foundation; let p = CGPoint(x: 360, y: 210); if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) { e.post(tap: .cghidEventTap) }; Thread.sleep(forTimeInterval: 1.0)'

# 2. 点击 hover 后出现的右上角菜单热区，并重新读取 AX Tree 验证菜单出现
SKILL_ROOT="${CUA_ROUTER_INSTALL_DIR:-${HOME}/.automan/skills/cua-router-basic}"
if [ ! -f "$SKILL_ROOT/SKILL.md" ]; then SKILL_ROOT="${HOME}/.cursor/skills/cua-router-basic"; fi
bash "$SKILL_ROOT/scripts/exec.sh" -t 60000 '{
  await sky.click({ app: "com.google.Chrome", x: 485, y: 172 });
  await new Promise(r => setTimeout(r, 1000));
  const s = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const menuLines = s.text.split("\n").filter(l => /启用中|创建副本|分享|移动到空间|删除|菜单/.test(l));
  nodeRepl.write(JSON.stringify({ opened: menuLines.length > 0, menuLines: menuLines.slice(0, 20) }));
}'
```

## RPA 工作流卡片实测经验

列表卡片横向排列时：

- `x=525` 可能落到第 2 张卡片主体并进入配置页。
- 对第 1 张卡片，应先 hover 卡片中心，例如 `360,210`。
- 再点击更靠左的右上角菜单热区，例如 `485,172`。
- 成功验证：AX Tree 出现 `启用中 / 创建副本 / 分享 / 移动到空间 / 删除`。

## 失败处理

- 如果没有菜单出现：重新读取截图或 AX Tree，校准 hover 点和菜单点。
- 如果误点进入详情页：禁止继续盲点，先通过地址栏 `set_value + Return` 返回列表页。
- 如果菜单已打开：优先点击菜单项 `element_index`，例如 `删除`，再处理确认弹窗。
