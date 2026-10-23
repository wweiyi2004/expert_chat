**维护责任与支持边界**

维护人：仓库所有者及其明确指定的模块维护者。当前主产品为 Flutter 客户端和独立文档 MCP；旧 Gateway/AuthService 属于兼容保留，Web 原型属于实验参考。保留的模块均应通过各自检查，实验身份不豁免安全更新。

| 范围 | 维护约定 |
| --- | --- |
| Windows / Android 客户端 | 本机可构建验证；正式发布还需覆盖安装、数据恢复与目标设备验收 |
| iOS / macOS / Linux | 不把本机 Windows 通过当作这些平台通过；使用对应 runner/设备记录结果 |
| 独立 MCP | 当前单用户主链路；上传、文档处理和备份恢复优先保证数据完整性 |
| Gateway / AuthService | 兼容已有部署；不自动删除或替用户迁移；退役前须确认使用量及迁移方案 |
| remote_lab_ui | 可运行的实验 UI，未承诺生产业务后端；无独立生产可用性保证 |
| Windows 无障碍 | 当前限制和退出条件见 [兼容记录](WINDOWS-ACCESSIBILITY.md) |

**每次变更**

统一入口为 `python scripts/check.py`，默认执行各模块完整检查；`--security` 另执行公告检查。常规 CI 包含客户端 Ubuntu/Windows 测试、服务测试与锁文件一致性、Web 类型/lint/运行时构建测试、历史密钥扫描和 `required` 汇总作业。Actions 固定提交 SHA，默认只读仓库权限并设置超时。

`native-validation.yaml` 验证 Android、iOS 无签名构建和 Windows 磁盘数据库/恢复流程。生成代码在 CI 中重建并比较差异，格式不一致和无说明的 `skip: true` 会失败。`main`/`master` 的分支保护应要求 `required` 和原生验证作业；仓库文件不能自行开启 GitHub 远端分支保护，需由维护者在远端配置并确认实际运行。

**定期维护**

| 周期 | 自动化与人工责任 |
| --- | --- |
| 每周一 09:30 中国时间 | `maintenance.yaml` 检查 Dart/Python/npm 公告；Dependabot 分组提供升级 PR；维护者处理适用性和兼容例外 |
| 每月 1 日 09:30 中国时间 | 原生验证工作流运行恢复演练；维护者核对上次正式备份能否实际恢复，并复核工具链限制 |
| 每次发布 | 固定提交、签名、覆盖升级、用户数据检查、设备后台行为、产物哈希和回退方式；原生改动重新建立 Shorebird 基线 |
| 每季度 | 复核平台与实验功能支持范围、实际使用量、旧服务退役条件、插件补丁是否能退出 |

定时工作流要在推送到默认分支并启用 GitHub Actions 后才会执行。本轮创建配置不等于它们已在远端执行。

**依赖升级**

Python 在 `server/pyproject.toml` 调整版本，执行以下命令并提交两份锁文件；独立服务的 `requirements.txt` 仅引用共同运行时锁，Docker 安装时校验哈希。

```sh
uv lock --project server --python 3.12
uv export --project server --frozen --no-dev --no-emit-project --no-header --output-file server/requirements.lock
python scripts/check.py --scope server --security
```

Web 使用官方源执行 `npm install` 后提交锁文件，检查 `typecheck`、`lint`、`test`、`audit`，并在涉及 Drizzle/esbuild 时运行 `npm run db:generate`。不要使用 `audit fix --force` 自动接受回退或跨版本变化。当前成组约束与补丁复核见 [依赖决策](DEPENDENCY-DECISIONS.md)。

**数据与服务运行**

MCP 的上传 SQL 行记录已提交的偏移；未提交尾部在重试/启动时截断，完成上传先复制并同步文件，再提交文档与回执，最后清理暂存副本。相同完成请求在回执保留期内返回同一文档，不创建第二份。默认 24 小时清理过期上传/回执，可用 `MCP_UPLOAD_RETENTION_HOURS` 调整；不自动删除正式文档。不足已提交长度的文件会明确报错，不能猜测或补写用户字节。

数据库和文档目录必须一起备份。SQLite 运行中应使用 SQLite backup API，或停止服务后复制整个数据目录；不能只复制活跃的 `.sqlite3` 文件而遗漏 WAL。每月在隔离目录恢复一次，比较文档字节、数据库记录与用户可见结果，记录恢复用时。维护命令只作用于指定的备份副本。

文档解析/编辑/转换使用独立进程，默认 30 秒、512 MB、每服务进程最多 2 个同时运行的文档任务；超时会结束该任务的进程。输入上限 50 MB，Office 容器另有展开量、条目数和压缩比限制，PDF/幻灯片页数和表格范围也受限。`DOCUMENT_TIMEOUT_SECONDS` 和 `DOCUMENT_MEMORY_MB` 仅在有实际负载证据时调整。

`GET /health` 提供不含密钥、文档和路径的可用性探针。容器默认使用 UID 10001，宿主机挂载的数据目录应授权给此 UID。对于存储空间、备份失败和反复出现的 503，应设置部署侧告警；仓库不假设用户已接入某家监控云服务。

客户端“问题反馈”可开启本次运行诊断，仅收集阶段、耗时、序号与时间，最多 128 条，默认关闭；关闭或退出程序即清空，不自动上传。模型输出成功率不能由“生成生命周期结束”事件直接推导。

**性能与发布追溯**

```sh
flutter test --no-pub tool/archive_benchmark_test.dart --reporter expanded
python scripts/release_manifest.py path/to/artifact.zip --output output/release-manifest.json
```

性能工具只创建合成临时数据库，测量 1 万/10 万条消息和有/无匹配查询，记录结果上限及延迟，不读取真实聊天。固定提交、设备、构建模式后再比较趋势，不把桌面测试耗时当成手机 SLA。

发布清单默认拒绝脏工作区，记录提交、应用版本、schema、备份格式、依赖锁哈希与产物 SHA-256。`--allow-dirty` 只用于本地审阅，清单会明确标记不可作为正式发布依据。清单不替代签名和设备验收。
