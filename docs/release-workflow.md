# 发布与本地同步流程

三条独立路径：**本地临时试用**（automan / cursor）、**正式 release**（tag + GitHub Release）、**回滚**。

**版本记录与迭代功能**单独维护在仓库根目录 [`RELEASE.md`](../RELEASE.md)，不在本文档内维护版本历史。

## 版本号约定

- **正式版**：semver `x.y.z`（如 `0.4.8`, `0.5.0`）。`scripts/bump-version.sh` 只接受这种格式。
- **beta / 试用版**：`x.y.z-beta.N`（如 `0.4.9-beta.2`）。`bump-version.sh` **不支持**，需手动改 4 处 JSON。
  - 语义：功能已完成、内部试用中，未正式 release 到 GitHub。
  - 一般不打 tag、不生成 dist tarball。

## 4 处版本号必须同步

任何版本变更（含 beta）都要同时改：

| 文件 | 位置 |
|---|---|
| `.meta.json` | 顶层 `"version"` |
| `.cursor-plugin/plugin.json` | 顶层 `"version"` |
| `.claude-plugin/plugin.json` | 顶层 `"version"` |
| `.claude-plugin/marketplace.json` | `plugins[]` 里 `name == "cua-router-basic"` 那项的 `"version"` |

只改一处 CI 不会挂，但会导致 marketplace 显示错乱。

## 路径 A：本地 beta 试用（applied to automan）

**场景**：功能开发完，先在本机 automan / cursor 里试用几天再决定要不要正式发。

```bash
cd /Users/shilei/code/cua-router-basic

# 1. 改版本号（4 处手动改，或写个 sed，因为 bump-version.sh 不接 beta）
# 例如 0.4.9-beta.2

# 2. 本地单元测试
node --test tests/test_computer_use_client.mjs
python3 -m unittest tests.test_cua_router

# 3. 同步到 automan 安装目录（不覆盖 vendor / runtime）
AUTOMAN_ROOT="$HOME/.automan/claude-code-agents/cua-agent/skills/cua-router-basic"
mkdir -p "$AUTOMAN_ROOT/references" "$AUTOMAN_ROOT/tests"
cp .meta.json                          "$AUTOMAN_ROOT/"
cp SKILL.md                            "$AUTOMAN_ROOT/"
cp scripts/computer-use-client.mjs     "$AUTOMAN_ROOT/scripts/"
cp scripts/exec.sh                     "$AUTOMAN_ROOT/scripts/"
cp references/*.md                     "$AUTOMAN_ROOT/references/"
cp tests/test_computer_use_client.mjs  "$AUTOMAN_ROOT/tests/"

# 4. 重启 daemon 让新 bootstrap 生效（必做）
bash "$AUTOMAN_ROOT/scripts/daemon.sh" restart

# 5. 验证
bash "$AUTOMAN_ROOT/scripts/exec.sh" \
  'nodeRepl.write("ax=" + typeof ax + ";v=" + JSON.stringify(ax._stats()))'
# 期望：ax=object;v={"hits":0,...}
```

### Cursor / Claude 端

Cursor / Claude 的插件位置在 `~/.cursor/skills/cua-router-basic` 或 `~/.claude/skills/cua-router-basic`。同步方式类似：

```bash
for ROOT in "$HOME/.cursor/skills/cua-router-basic" "$HOME/.claude/skills/cua-router-basic"; do
  [ -d "$ROOT" ] || continue
  cp .meta.json "$ROOT/"
  cp SKILL.md "$ROOT/"
  cp scripts/computer-use-client.mjs "$ROOT/scripts/"
  mkdir -p "$ROOT/references"
  cp references/*.md "$ROOT/references/"
  bash "$ROOT/scripts/daemon.sh" restart
done
```

### 不 push、不 commit 的原因

beta 试用期通常有多次小改动。策略：
- 改动直接 apply 到本机各客户端
- 本地 `git status` 保留 dirty，等确认稳定再 commit
- 或者本地 commit + 不 push（`git status` 显示 `ahead N commits`）

## 路径 B：正式发布（走 release.sh）

**前置**：
- 版本号已定，semver `x.y.z`
- 本地 `vendor/` 完整（`bash scripts/setup-vendor.sh` 已跑过）
- `gh` CLI 已登录并有 repo 权限

```bash
cd /Users/shilei/code/cua-router-basic

# 1. Bump 版本（同时改 4 处 JSON）
bash scripts/bump-version.sh 0.5.0
git diff  # 核对：.meta.json + 2 个 plugin.json + marketplace.json

# 1.5 更新 RELEASE.md（版本锚点 + 详情，见文件顶部维护约定）

# 2. 提交 + 走 release
bash scripts/release.sh 0.5.0
# 该脚本会：
#   - 提交 chore(release): 0.5.0
#   - 打包 slim (~50KB) + vendor (~几十 MB) tarball 到 dist/
#   - git tag v0.5.0
#   - gh release create v0.5.0 --generate-notes + 上传 dist/*
```

`release.sh` 常用选项：

```bash
--dry-run       # 只打包，不 tag、不 gh release（本地验证用）
--skip-git      # 仅上传（补传 asset 时用）
--skip-upload   # 打包完停在 dist/，人工检查
--notes FILE    # 用外部 markdown 作为 release notes（可从 RELEASE.md 对应版本详情截取）
```

### 上游同步（CI）

`main` 分支 push 后：
- `.github/workflows/ci.yml`：验证 slim install 能跑
- `.github/workflows/release.yml`：如果检测到 tag `v*`，上传 dist artifact

## 路径 C：回滚

### 回滚 1：本地客户端回退

```bash
# 从 git 历史取上一个 beta 前的版本
AUTOMAN_ROOT="$HOME/.automan/claude-code-agents/cua-agent/skills/cua-router-basic"
git -C /Users/shilei/code/cua-router-basic show HEAD~1:scripts/computer-use-client.mjs \
  > "$AUTOMAN_ROOT/scripts/computer-use-client.mjs"
bash "$AUTOMAN_ROOT/scripts/daemon.sh" restart
```

### 回滚 2：已 release 到 GitHub

```bash
# 删除 remote tag（谨慎）
git push origin :refs/tags/v0.5.0
gh release delete v0.5.0 --yes

# 或者仅 mark 为 draft
gh release edit v0.5.0 --draft
```

用户端如果已经装了坏版本，通过 `scripts/update-remote.sh` 重装上一个好版本：

```bash
curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/update-remote.sh \
  | bash -s -- --version 0.4.8 --force
```

## 常见发布事故

| 症状 | 原因 | 修复 |
|---|---|---|
| Cursor 里显示旧版本号 | 4 处 JSON 只改了 `.meta.json` | 同步改所有 4 处 |
| `pip install`-like 场景装不上 vendor | dist 里 vendor tarball 缺失 | `release.sh` 前确认 `vendor/` 完整 |
| CI slim install 通过但真机 `ax is undefined` | slim install 只有 skill 文件，vendor 是另一步 | 用户需再跑 `bash scripts/install-full.sh` 或 `download-vendor.sh` |
| 用户 `daemon.sh start` 失败 `codex not found` | vendor 没同步或 CODEX_BIN 环境变量污染 | `bash scripts/setup-vendor.sh` 或清 `CODEX_BIN` |
| 用户装完 `ax.get is not a function` | 装了包但 daemon 用的还是旧 bootstrap | `daemon.sh restart` |

## Checklist：一次典型发布

```
[ ] 版本号定：x.y.z 或 x.y.z-beta.N
[ ] 4 处 JSON 已改
[ ] node --test tests/test_computer_use_client.mjs → 23/23
[ ] python3 -m unittest tests.test_cua_router → 2/2
[ ] 本地 daemon.sh restart → typeof ax === object
[ ] 至少一个端到端 case（真 Chrome + ax.get + sky.click + ax.get）
[ ] beta：只同步到 automan / cursor / claude，不 push
[ ] 正式：git commit + gh release + upload dist/*
[ ] 更新根目录 RELEASE.md：版本锚点表 + 详情（beta 与正式版各一条）
```
