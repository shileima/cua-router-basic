# vendor — 技能内置运行时

此目录在 Git 仓库中为空（~735 MB 二进制不入库）。首次使用前需填充 vendor/：

| 方式 | 命令 |
|------|------|
| 完整安装（自动） | `bash scripts/install-full.sh` |
| 从 ChatGPT.app 提取 | `bash scripts/setup-vendor.sh` |
| 从 Release 下载 | `bash scripts/download-vendor.sh` |

| 目录 | 内容 |
|------|------|
| `codex/bin/codex` | app-server 可执行文件 |
| `cua_node/` | node、node_repl、`@oai/sky` 等 node 模块 |
| `computer-use/` | SkyComputerUseClient 原生客户端 |
| `manifest.json` | 提取时间与校验信息 |
