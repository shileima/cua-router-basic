# cua-router-basic

cua-router + sky Computer Use API 基础技能。封装 macOS 上通过 cua-router 本地服务调用 sky 操控浏览器/桌面应用的依赖、初始化流程和辅助函数。

**平台**：macOS arm64（Apple Silicon）  
**仓库**：https://github.com/shileima/cua-router-basic

**文档入口**：
- 用户 / Agent：[`SKILL.md`](./SKILL.md) + [`references/`](./references/)（操作规范、示例、故障降级）
- 维护者：[`docs/`](./docs/README.md)（架构、AX 缓存设计、风险清单、vendor 同步、发布流程、排查）

---

## 快速安装

### 方式 A：Agent 远程一键安装（推荐）

无需预先 git clone，Agent 或用户可直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/shileima/cua-router-basic/main/scripts/install-remote.sh | bash
```

脚本会自动：下载 slim 技能包 → bootstrap vendor（ChatGPT 提取或 Release 下载）→ 注册到 `~/.cursor/skills` 并 Pin。

若本机存在 `~/.automan/skills` 目录，默认安装到 `~/.automan/skills/cua-router-basic`，并同步：
- `~/.cursor/skills/cua-router-basic` → 技能目录（符号链接）
- `~/.automan/claude-code-agents/main/skills/cua-router-basic` → `../../../skills/cua-router-basic`

### 方式 B：Git clone + 一键安装

```bash
git clone git@github.com:shileima/cua-router-basic.git
cd cua-router-basic
bash scripts/install-full.sh
```

`install-full.sh` 会自动：
1. 检测 vendor 是否已存在
2. 若本机有 ChatGPT.app → 从本地提取 vendor
3. 否则 → 从 [GitHub Releases](https://github.com/shileima/cua-router-basic/releases) 下载 vendor
4. 注册到 `~/.cursor/skills` 并 Pin 到 `/` 菜单

### 方式 C：Plugin 安装（Cursor / Claude Code）

**Cursor**：

```
/add-plugin shileima/cua-router-basic
```

**Claude Code**（添加 marketplace 后）：

```
/plugin marketplace add shileima/cua-router-basic
/plugin install cua-router-basic@cua-router-basic-dev
```

Plugin 注册 slim 技能包；首次使用前执行 vendor bootstrap：

```bash
bash ~/.cursor/skills/cua-router-basic/scripts/install-full.sh --vendor-mode auto
# 或直接 daemon.sh start（会自动 bootstrap vendor）
```

### 方式 D：仅安装技能本体（Slim）

适合 CI 或已有 vendor 的场景：

```bash
git clone git@github.com:shileima/cua-router-basic.git ~/.automan/skills/cua-router-basic
bash ~/.automan/skills/cua-router-basic/scripts/install-slim.sh --no-cursor
bash ~/.automan/skills/cua-router-basic/scripts/download-vendor.sh
bash ~/.automan/skills/cua-router-basic/scripts/install-cursor.sh
```

### 方式 E：指定安装目录

```bash
bash scripts/install-full.sh --target ~/.automan/skills/cua-router-basic
# 或
bash scripts/install-remote.sh --target ~/.automan/skills/cua-router-basic
```

---

## 启动与验证

```bash
# 启动 cua-router 守护进程
bash scripts/daemon.sh start

# 健康检查
bash scripts/daemon.sh status

# 执行测试 JS
bash scripts/exec.sh 'nodeRepl.write("ok")'
```

服务默认监听 `http://localhost:18901`。

---

## 目录结构

```
cua-router-basic/
├── SKILL.md              # Agent 技能规范（Cursor 读取）
├── .meta.json            # 版本元信息
├── .cursor-plugin/       # Cursor Plugin manifest
├── .claude-plugin/       # Claude Code Plugin + marketplace
├── scripts/              # 安装、服务、发布脚本
│   ├── install-remote.sh # Agent 远程一键安装
│   ├── install-automan.sh # 同步 ~/.automan/claude-code-agents 技能符号链接
│   ├── install-full.sh   # 完整安装
│   ├── install-slim.sh   # 仅技能本体
│   ├── download-vendor.sh
│   ├── setup-vendor.sh   # 从 ChatGPT.app 提取 vendor
│   ├── daemon.sh         # start | stop | status | restart
│   ├── exec.sh           # 调用 /exec 端点
│   └── release.sh        # 维护者发布
├── vendor/               # 运行时二进制（~735 MB，不入 Git）
└── runtime/              # 本地 CODEX_HOME（不入 Git，首次启动生成）
```

| 目录 | 大小 | Git 跟踪 |
|------|------|----------|
| `scripts/` + `SKILL.md` | ~50 KB | ✅ |
| `vendor/` | ~735 MB | ❌ Release 分发 |
| `runtime/` | 可变 | ❌ 本地生成 |

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `CUA_ROUTER_RELEASE_BASE` | 覆盖 vendor 下载基址，默认 `https://github.com/shileima/cua-router-basic/releases/download/v<version>` |
| `CUA_ROUTER_VENDOR_URL` | 直接指定 vendor tarball URL |
| `CUA_ROUTER_GITHUB_REPO` | 覆盖 GitHub 仓库（默认 `shileima/cua-router-basic`） |
| `CUA_ROUTER_INSTALL_DIR` | 覆盖默认安装目录 |
| `CHATGPT_RESOURCES` | setup-vendor 源路径，默认 `/Applications/ChatGPT.app/Contents/Resources` |

默认安装目录：若存在 `~/.automan/skills` 则为 `~/.automan/skills/cua-router-basic`，否则为 `~/.cursor/skills/cua-router-basic`。

---

## 维护者：发布新版本

### 前置条件

- macOS arm64，已安装 ChatGPT.app 且装过 Computer Use 插件
- 已执行 `bash scripts/setup-vendor.sh`（本地 vendor/ 就绪）
- 已安装并登录 [`gh`](https://cli.github.com/) CLI

### 一键发布

```bash
# 打包 + 打 tag + 创建 GitHub Release + 上传产物
bash scripts/release.sh 0.3.0

# 推送到 GitHub
git push origin main
git push origin v0.3.0
```

发布产物（位于 `dist/`）：

| 文件 | 说明 |
|------|------|
| `cua-router-basic-slim-<ver>.tar.gz` | 技能本体 (~24 KB) |
| `cua-router-basic-vendor-darwin-arm64-<ver>.tar.gz` | vendor 二进制 (~270 MB) |
| `SHA256SUMS` | 校验和 |
| `release-manifest.json` | 版本与 vendor 元信息 |

### 仅打包（不上传）

```bash
bash scripts/release.sh --dry-run 0.3.0
# 或
bash scripts/package-release.sh
```

### 版本号管理

```bash
bash scripts/bump-version.sh 0.4.0   # 同步 .meta.json 与 Plugin manifest 版本号
```

会自动更新：`.meta.json`、`.cursor-plugin/plugin.json`、`.claude-plugin/plugin.json`、`.claude-plugin/marketplace.json`。

---

## 维护者：日常维护

### 更新 vendor（ChatGPT 升级后）

```bash
bash scripts/setup-vendor.sh
bash scripts/daemon.sh restart
bash scripts/exec.sh 'nodeRepl.write("ok")'
# 验证通过后发布新版本
bash scripts/release.sh 0.3.1
```

### 清理本地 runtime 缓存

`runtime/` 是本地 CODEX_HOME，可安全删除后重启服务自动重建：

```bash
bash scripts/daemon.sh stop
rm -rf runtime/.tmp runtime/*.sqlite*
bash scripts/daemon.sh start
```

### 升级已安装技能

```bash
cd ~/.automan/skills/cua-router-basic   # 或你的安装目录
git pull origin main
bash scripts/install-full.sh --vendor-mode download --force-vendor
bash scripts/daemon.sh restart
```

---

## CI / 自动化

- **Push / PR** → `.github/workflows/ci.yml` 验证脚本语法与 slim 打包
- **Tag `v*.*.*`** → `.github/workflows/release.yml` 校验 tag 与版本一致

> vendor 二进制无法在无 ChatGPT.app 的 CI 中构建，需维护者在本地执行 `scripts/release.sh` 上传。

---

## 系统要求

- macOS + Apple Silicon（arm64）
- Python 3
- Google Chrome（`com.google.Chrome`）
- 首次 vendor 来源（二选一）：
  - 本机 ChatGPT/Codex 桌面应用 + Computer Use 插件
  - GitHub Release 预构建 vendor tarball

---

## 相关文档

- 技能规范与 API 用法：见 [SKILL.md](./SKILL.md)
- vendor 说明：见 [vendor/README.md](./vendor/README.md)
