# 安装到 Cursor 并置顶 `/` 菜单

```bash
SKILL_ROOT="/path/to/cua-router-basic"
bash "$SKILL_ROOT/scripts/install-cursor.sh"
```

脚本会：

1. 软链到 `~/.cursor/skills/cua-router-basic`。
2. 写入 Cursor 全局状态 `cursor/glass.pinnedItems.v1`，Pin 该技能。
3. 更新 `cursor.skills.recentlyUsed`，提升 `/` 菜单排序。

取消 Pin：

```bash
bash "$SKILL_ROOT/scripts/install-cursor.sh" --unpin
```

安装后若 `/` 列表未刷新，执行 **Developer: Reload Window**。
