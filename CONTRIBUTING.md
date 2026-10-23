**开发与检查**

重构以 [唯一主规划](docs/PROJECT-PLAN.md) 为准，模块与迁移范围见该文件；当前源码现状见 [源码核对](docs/SOURCE-BASELINE.md)。原 docs 已归档，历史架构与计划不再作为实施指令。下述命令仍用于现有工程维护。

使用 `.fvmrc` 指定的 Flutter 3.44.0（Dart 3.12.0）、Python 3.12、uv 0.11.2，以及 Node.js 24。服务端依赖由 `server/pyproject.toml` 和 `server/uv.lock` 管理，Web 原型依赖使用 `package-lock.json`。

```sh
flutter pub get --enforce-lockfile
uv sync --project server --frozen
npm ci --prefix remote_lab_ui --registry=https://registry.npmjs.org
python scripts/check.py --quick
python scripts/check.py --security
```

可以用 `--scope client`、`--scope server`、`--scope web`、`--scope desktop` 单独检查某一部分；`--quick` 仅跑静态检查，不代替完整检查。电脑端当前用 Rust 1.96.0 验证，完整检查包含 Clippy、Rust 权限测试与 stdio MCP 黑盒测试，详见 [电脑端说明](next/desktop/README.md)。依赖审计必须能连接官方公告源，网络错误不会当作“没有漏洞”。

Windows 原生可靠性与 Android 调试构建：

```sh
python scripts/check.py --scope client --native
```

格式化与生成代码后再提交：

```sh
dart format lib test integration_test tool
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev schema generate drift_schemas test/generated_migrations
git diff --check
```

更新数据库结构时，先递增 schema 版本，再执行 `dart run drift_dev schema dump lib/data/db/app_database.dart drift_schemas`，保留历史快照，添加带真实字段内容的迁移验证。不能通过删除失败的迁移测试或覆盖旧快照来通过 CI。

旧版维护记录见 [已归档维护制度](archive/2026-10-22-planning-reset/docs/MAINTENANCE.md)；当前检查入口以本文件及实际脚本为准。PR 应说明触发场景、改后行为、验证结果和仍然存在的限制。不要把格式化、重构、协议变化和新功能混在一个无法解释的提交中。尚未提交的个人开发内容必须先确认归属，不能用 `git reset --hard` 或覆盖生成物来清理别人的工作。

不要提交 `mcp.env`、`mcp_data/`、密钥、真实聊天/截图、用户备份或原始生产日志。测试使用明确的人工构造内容。密钥扫描使用校验过的固定版本 Gitleaks：

```sh
python scripts/install_gitleaks.py
python scripts/install_hooks.py
.tools/gitleaks git --redact=100 --log-opts=--all --no-banner
```

Windows 可使用 `.tools/gitleaks.exe`。白名单必须精确限定测试文件和合成值，附复核日期，不得按整个业务目录忽略。报告中的潜在密钥始终脱敏。

安装器只设置当前仓库的 hook，不覆盖已有 hook 配置。提交前扫描暂存区，CI 再扫描历史；本机未安装扫描器时提交会明确失败，先运行安装命令。无需把工具二进制提交到仓库。
