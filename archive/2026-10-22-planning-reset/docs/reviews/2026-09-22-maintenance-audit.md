**Expert Chat 项目检查与持续维护建议 · 2026-09-22**

此文保留修复前的审查快照。后续实现与最新验证结果见[修复记录](2026-09-22-maintenance-remediation.md)。

**结论：项目已有较扎实的客户端回归测试和数据恢复设计，但还没有形成完整、可复现的发布与维护闭环。应优先修复数据保存边界和服务端依赖风险，再按职责拆分大型模块。现阶段不建议整体重写。**

审查对象是本机工作区，Git HEAD 为 `072dc8c`，`git describe` 为 `v3.5.0-dirty`，应用配置版本为 `3.6.0+4108`。开始时有 90 个修改文件、1 个删除文件、169 个未跟踪文件，共 260 项变更。本报告不代表远端主分支或已发布安装包的状态。

本次进行了仓库级文件盘点、代码与配置检索、核心链路审阅、全量现有单元/组件测试、依赖审计、原生可靠性测试，以及两项隔离故障复现。没有修改业务代码、升级项目依赖、调用真实模型服务或发布产物。不能据此宣称每一行代码均经人工审阅，或所有系统、设备和第三方服务均已验收。

**一、范围与实际检查结果**

盘点到 759 个非忽略文件；`lib/` 有 281 个非生成 Dart 文件、76,903 行；`test/` 有 130 个 Dart 测试及支持文件，其中 129 个以 `_test.dart` 结尾；另有 5 个原生集成测试文件。Python 服务共 15 个源码/测试文件、5,256 行。`remote_lab_ui/` 是独立的 vinext/React 原型，根 `.gitignore` 也将它描述为参考原型，应与 Flutter 正式产品分别管理。

| 检查 | 本轮结果 | 解读 |
| --- | --- | --- |
| Flutter 全量测试及覆盖率 | **1,183 通过，1 跳过** | `flutter test --no-pub --coverage --reporter expanded`；跳过的是模型用量设置页测试，尚无跳过原因/到期说明 |
| 根目录静态分析 | **退出码 1，2 条 info** | 都来自已忽略的 `tmp/background-stream/check_sse_fixture.dart` 的 `avoid_print`；不是生产代码编译错误 |
| 生产/测试/工具目录分析 | **通过** | `dart analyze lib test integration_test tool`，无问题 |
| Dart 格式检查 | **未通过，78 / 423 个文件需要格式化** | 使用 `--output=none --set-exit-if-changed`，没有改写文件 |
| Windows 原生可靠性测试 | **1 通过，Debug 原生构建通过** | 真实文件 SQLite、v15 升级、生成检查点、备份与恢复日志；全部使用临时数据和模拟模型 |
| Android ARM64 Debug 构建 | **通过，约 242 秒** | 仅构建，不安装或升级用户设备；工具链兼容警告见文末 |
| Python 按仓库依赖清单、隔离 Python 3.12 环境 | **18 通过，3 个子测试通过，1 条弃用警告** | 同时安装 gateway/MCP requirements；没有把全局 Python 环境通过当成唯一依据 |
| Web 原型 lint、构建及现有测试 | **通过，2 个测试通过** | 测试覆盖服务端渲染和源码连线，不能等同浏览器交互验收 |
| Web TypeScript 类型检查 | **失败，3 个错误** | 缺 `cloudflare:workers` 模块声明及 `Fetcher`、`D1Database` 类型 |
| Dart 依赖过期/公告检查 | 查询成功，本次输出未标记受公告影响、撤回或停用的包 | 有 21 个直接依赖出现更新信息；不等于全部依赖没有安全问题 |
| Python requirements 漏洞审计 | **3 个包命中公告** | 103 条工具记录，按公告别名合并为 54 组；不能理解为 103 个独立可利用漏洞 |
| npm 官方源漏洞审计 | **24 个受影响依赖项** | 1 critical、16 high、6 moderate、1 low；含开发依赖和传递影响 |
| 差异空白检查 | 通过 | `git diff --check` |
| 文档相对链接检查 | 未发现缺失目标 | 已检查 README、docs 及服务 README；不包含所有外链的可用性 |
| 常见密钥格式扫描 | 未发现可确认的真实凭据 | 命中为测试数据及脱敏规则；这是有限模式扫描，未审计全部 Git 历史 |

覆盖率：LCOV 记录的文件中，排除 `.g.dart` 后为 **23,401 / 32,532 行，71.93%**；包含生成代码则为 66.46%。分层为 data 85.58%、domain 76.70%、state 78.19%、features 63.40%。这些是被 LCOV 记录的文件的行覆盖率，不是分支覆盖率，也不包含所有平台分支和未加载文件。`main.dart` 未进入本轮单元测试覆盖记录。

**二、需要优先处理的具体问题**

P1 表示应在相关功能下一次正式发布前处理；P2 表示近期安排。优先级同时考虑影响和实际暴露路径，不直接照搬扫描器等级。

**F01 · P1 · 一条附件解析异常会造成正常附件被静默清空，已复现。**

位置：[drift_conversation_repository.dart](../../lib/data/drift_conversation_repository.dart)，重点为第 554 行 `_decodeList`、第 384 行附件 JSON 比较，以及第 342–358 行消息更新逻辑。

触发方式：在同一条消息的附件数组中保存一个正常附件和一个字段类型异常的附件，例如 `sizeBytes` 为字符串。读取时整组解析异常被捕获并转换为 `[]`，会话仍被标记为已加载。随后只修改会话标题并保存，也会把原来的 `attachments_json` 写成 SQL NULL，连正常附件的元数据一起丢失。

本次使用内存 SQLite 复现，未触碰真实会话。诊断脚本断言的是“当前缺陷确实发生”，其通过不代表行为正确。

建议：将纯会话元数据更新与消息内容写入分开；反序列化失败时保留原始字段并报告恢复状态，不把“无法读取”映射为“用户删除”。对合法条目可逐条恢复，但必须保留无法解析的原始内容。`_decodeObject`、角色与世界书等相似容错路径也应按相同原则检查。

验收：混合正常/异常附件的消息在打开、重命名、切换会话和追加新消息之后，原始异常字段及正常附件均不被无关操作改写；界面给出可理解的恢复提示。

**F02 · P1 · MCP 上传的文件操作和数据库事务不具备共同恢复机制，已复现。**

位置：[MCP 服务 main.py](../../server/mcp_server/app/main.py)，第 106 行 `_db`、第 314 行 `_append_upload`、第 354 行 `_finish_upload`。

分块先追加文件，再提交 `received_size`；完成上传时先移动文件，再提交文档记录。SQLite 回滚不会撤销已经完成的文件写入和移动。本次在临时目录注入“提交前失败”，得到：

| 故障点 | 复现结果 |
| --- | --- |
| 分块落盘后、SQL 提交前 | 数据库记录 0 字节，文件实际已有 3 字节 |
| 按数据库 offset 重试该分块 | 文件重复追加，完成上传时报“上传临时文件大小不一致” |
| 文件移入 documents 后、SQL 提交前 | uploads 记录仍在，原临时文件不存在；documents 表无记录，但有 1 个孤儿文件 |

建议：为上传建立持久状态/恢复日志；按已提交 offset 校验、定位和处理未提交尾部；给完成上传设计稳定文档 ID 和可重入步骤；启动时核对记录与文件，回收超时暂存上传。仅在异常处理中删除目标文件不足以解决进程崩溃和 commit 失败。

验收：对写文件、改 offset、移动文件、插入记录、commit 的各边界注入失败，重启后可以恢复或明确终止，不重复追加、不产生不可发现的文件，也不删除已有正式文档。

**F03 · P1 · Python 服务固定依赖包含已公开漏洞，解析资源限制也应前移。**

位置：[MCP requirements](../../server/mcp_server/requirements.txt)、[Gateway requirements](../../server/gateway/requirements.txt)、[文档处理 requirements](../../server/doc_edit/requirements.txt)。

本次审计解析出的相关版本和结果如下，针对的是仓库清单，不是对线上服务实际版本的确认：

| 包 | 解析版本 | 工具记录数 | 合并别名后的公告组 |
| --- | --- | --- | --- |
| pypdf | 5.4.0 | 77 | 41 |
| python-multipart | 0.0.20 | 12 | 6 |
| starlette | 0.46.2 | 14 | 7 |

例如，pypdf 官方公告确认旧版本在读取特制 FlateDecode PDF 时可能耗尽内存。当前 MCP 的 `_extract_text` 直接调用 `PdfReader`，因此这条解析路径值得优先处理。服务需要 Token，但经过认证上传的文档内容仍可能来自不可信来源。[pypdf 官方公告](https://github.com/py-pdf/pypdf/security/advisories/GHSA-7hfw-26vp-jp8m)

`MAX_FILE_BYTES` 限制上传文件大小，`RESOURCE_MAX_CHARS` 则在全文解析完成后才截断；两者都不能完整约束压缩文件展开量、PDF 解码内存或 CPU 时间。客户端已有 OOXML 展开限制，不应由此推断独立服务端也受到同样保护。

FastAPI 0.115.12 要求 `starlette<0.47.0`，会把环境留在较旧的 Starlette 分支，应组合升级 FastAPI、Starlette、MCP 相关依赖，而不是强制覆盖一个传递依赖。multipart/Starlette 公告的可达性需区分纯 MCP 服务和旧 REST 上传端点；并非所有公告都适用于每种部署。[Starlette 官方公告](https://github.com/Kludex/starlette/security/advisories/GHSA-2c2j-9gv5-cj73)、[python-multipart 官方公告](https://github.com/Kludex/python-multipart/security/advisories/GHSA-pp6c-gr5w-3c5g)

建议：更新成组依赖并生成包含传递依赖的锁文件；在受限进程内处理文档，设置耗时、展开字节、页数/单元格等预算；保留鉴权和路径检查。不要用一份版本宽泛的最新环境代替锁定环境回归。

验收：在干净 Python 3.12/Linux 环境重建镜像并通过测试；适用公告已修复，其余风险例外有依据及复核日期；恶意/超限文档只能使单次任务失败，不拖垮整个服务。

**F04 · P1（部署或共享开发服务前）· Web 原型依赖风险明显，必须明确是否继续维护。**

位置：[package.json](../../remote_lab_ui/package.json)，`next=16.2.6`、`vite=8.0.13`、`vinext=0.0.50` 等固定版本。

官方 npm 审计报告 24 个受影响依赖项，包括 Next.js critical 和 Vite high。Next.js 的相关公告对 Windows 托管服务器有特定条件；Vite 公告针对 Windows 上向网络暴露的开发服务器。此原型使用 vinext/Cloudflare worker，尚未证明其实际执行路径满足 Next.js 漏洞条件，不能直接断言当前原型存在远程代码执行。[Next.js 官方公告](https://github.com/vercel/next.js/security/advisories/GHSA-p293-qw3h-jr36)、[Vite 官方公告](https://github.com/vitejs/vite/security/advisories/GHSA-fx2h-pf6j-xcff)

本机 npm 默认镜像的 audit API 返回 404；改用 `--registry=https://registry.npmjs.org` 才取得有效结果。这属于本机审计配置问题，不是仓库业务缺陷。

建议二选一：若仅为设计参考，明确归档用途、停止公开部署并避免长期暴露开发服务器；若仍需要运行，给它配置独立的升级周期、类型检查、构建测试和依赖审计。不要直接执行 `npm audit fix --force`；其建议包含跨大版本变更，甚至旧版回退。

**F05 · P2 · 默认 MCP 凭据和文档目录未被 Git 忽略，存在误提交风险。**

位置：[启动入口](../../server/mcp_server/__main__.py) 第 56、102、121 行，以及根 [.gitignore](../../.gitignore)。启动入口会生成 `mcp.env` 和 `mcp_data/`，前者含 Token，后者含数据库与用户文档。

`git check-ignore --no-index` 验证 `server/mcp.env`、`server/mcp_data/documents.sqlite3`、`server/mcp_data/documents/file_audit.txt` 均未被忽略。现有 `server/**/data/` 规则不匹配 `mcp_data`。本次没有发现这些真实文件已被提交，结论是防护缺口。

建议：覆盖文档支持的运行目录，忽略运行时 `mcp.env`、`mcp_data/`，保留 `.example`；给提交和 CI 增加密钥扫描。已有历史若后来发现泄漏，应先轮换 Token，再处理历史。

**F06 · P2 · Web 构建通过不能替代类型检查，当前确有 3 个类型错误。**

位置：[db/index.ts](../../remote_lab_ui/db/index.ts) 第 1 行、[worker/index.ts](../../remote_lab_ui/worker/index.ts) 第 6、7 行，以及 [tsconfig.json](../../remote_lab_ui/tsconfig.json)。缺失 `cloudflare:workers`、`Fetcher` 和 `D1Database` 的环境声明。

建议：使用与 Wrangler/Worker 配置一致的生成类型或匹配的官方类型配置，加入 `typecheck` 脚本和 CI。应用构建工具的转译成功不等于 TypeScript 校验成功。另外忽略 `.tsbuildinfo`，避免一次检查产生未跟踪缓存文件。

**F07 · P2 · 发布追溯与检查门槛尚不完整。**

`.github/workflows/native-validation.yaml` 存在于工作区，但开始审查时未被 Git 跟踪。已有 CI 配置了 Flutter Ubuntu/Windows 检查与 Python 测试，是有用基础；仓库未配置 Web 检查、格式检查、依赖审计、依赖更新机器人或生成代码差异检查。远端分支保护、已执行 CI 和发布流水线设置没有在本次核实。

根目录分析会扫描被 Git 忽略的临时 Dart 文件，导致本机失败而干净 checkout 可能通过。78 个文件的格式差异也没有自动门槛。应明确检查目录/排除真正的产物目录，不能一概降低 lint 严格度来掩盖失败。

建议：先按功能整理现有变更，再以提交 SHA 关联版本、构建号、原生依赖清单、数据库 schema、备份格式、Shorebird 基线、测试结果及产物校验值。原生 Android 服务变更必须走完整安装包，项目自己的后台生成说明也已明确这一点。文档版本号不能替代可重建的提交记录。

**F08 · P2 · Windows 正式入口仍整体关闭语义树，这是已知产品限制。**

位置：[main.dart](../../lib/main.dart) 第 82–84 行。代码明确用 `semanticsEnabled => false` 绕过引擎崩溃；这样会损害屏幕阅读器和无障碍工具获取控件语义的能力。

这不是建议立即删除保护。应关联具体上游 issue/修复版本和负责人，在修复引擎上验证正式入口、流式页面、设置页和 Narrator 后再移除。独立测试入口能够读到控件，不能代替正式入口验收。

**三、可持续维护的结构调整**

| 当前热点 | 证据 | 建议的下一步 |
| --- | --- | --- |
| 设置页职责过多 | `settings_page.dart` 4,792 行；设置控制器 2,049 行 | 按模型连接、搜索、多媒体、MCP、数据、安全存储拆组件及设置操作；迁移逻辑独立，保留统一入口 |
| 聊天编排仍高度耦合 | `chat_page.dart` 3,054 行；ChatController 与 8 个 `part` 合计 5,098 行 | 继续抽出会话操作、持久化、请求快照、生成执行、工具执行的明确接口；`part` 只是分文件，仍共享私有状态 |
| 层间依赖方向混杂 | 静态导入统计：data→domain 13 条，domain→data 89 条；`long_task_runner.dart` 直接依赖 state 层 | 逐步把共享业务模型、请求参数与接口移到独立 model/contracts 区域；domain 接收不可变参数，避免依赖 SettingsController |
| 当前 MCP 与旧 Gateway 边界不清 | 独立 MCP 从 `gateway.app.document_mcp` 导入协议定义；两套服务重复文档抽取逻辑 | 抽出小型 `document_core` / `document_protocol` 包；Gateway 留作适配层，定义兼容范围与退役条件 |
| 数据版本不断增加 | 当前 schema 16，迁移覆盖有 v8 与 v15 场景，但没有完整历史 schema 快照体系 | 每个后续版本导出 schema；对明确支持的升级起点做迁移验证和真实数据夹具测试 |
| 本地插件补丁长期驻留 | `speech_to_text_windows` 使用 path override；README 说明了来源版本和修改原因 | 补充对应上游提交/issue、补丁差异、原生语音验收脚本及退出条件；SDK 升级时单独复验 |
| 依赖存在成组约束 | archive/xml、file_picker/share_plus/win32 已有兼容注释 | 建立依赖决策记录：为何固定、关联包、升级验证和复查日期；分组升级，避免长期只补单包 |

已有 `GenerationExecution`、`ToolCallRunner`、请求上下文、流式展示等抽离方向是合理的。优先在这些边界继续拆分，不要为了追求某种架构名称一次性迁移整个应用。

数据库升级建议采用 Drift 官方提供的 schema 导出和 `SchemaVerifier` 验证流程，并同时保留项目自己的数据完整性断言。[Drift 迁移测试文档](https://drift.simonbinder.eu/migrations/tests/)

搜索当前仍使用包含式 `LIKE` 并一次性返回匹配消息。建议先用合成的 1 万/10 万消息数据测量延迟与内存，再决定分页、结果上限和全文索引方案；中文检索需要明确分词策略，不能直接假设普通全文索引能解决所有问题。本次未作性能基准测量。

**四、建议建立的固定维护制度**

| 节奏 | 必做事项 | 完成标准 |
| --- | --- | --- |
| 每次 PR | 格式、静态分析、相关回归、完整基础测试；Python 与 Web 改动跑各自检查 | 必需作业全部通过；失败不能用“本机可运行”替代；每项跳过测试有原因与复核日期 |
| 数据/平台改动 PR | 迁移夹具、备份恢复、原生构建、取消与中断场景 | 跨升级保留用户数据；恢复不会自动重放收费或有副作用的操作 |
| 每周 | 依赖公告、分组更新 PR、未处理错误、临时兼容补丁复查 | 高风险公告有适用性判断、负责人和期限；审计接口失败必须算失败 |
| 每月 | 从干净环境构建；还原备份演练；清理服务暂存文件；核对 SDK/插件组合 | 记录恢复时间、数据校验和构建证据；不是仅检查备份文件存在 |
| 每次正式发布 | 从固定提交构建；旧版本覆盖安装；关键设备流程；签名/哈希；回退方案 | 产物可追溯到 SHA，原生改动与 OTA 基线匹配；文档标注未验收平台 |
| 每季度 | 大数据量性能、支持平台范围、旧 Gateway 使用量、插件补丁退出条件 | 依据实际使用删减维护范围，避免所有实验功能永久成为支持承诺 |

建议增加统一 `check` 入口，给出快速本地检查和完整发布检查两档。CI 对不同目录做必要分流，保留一个明确的必需汇总作业。Actions 使用最小权限、执行超时及可追溯的版本引用；生成 Drift 文件后检查工作树差异，避免生成物与源码悄悄分叉。

依赖更新与 PR 依赖审核可以由 Dependabot 和 dependency review 辅助，但功能可用性、权限及私有仓库限制需按实际 GitHub 设置确认。[GitHub 官方依赖管理说明](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/manage-your-dependency-security)

错误诊断方面已有显式字段和脱敏，是良好基础。建议再增加可关闭的本地结构化事件记录：请求/任务关联 ID、版本、阶段、耗时、错误类别、取消状态；不记录正文、密钥或截图。服务端补充可用性探针、任务耗时、存储空间与积压上传指标。外部错误上报应由用户选择，不必为维护引入强制云服务。

建议记录的指标是：构建成功率、回归失败与不稳定测试数、数据保存/恢复失败数、崩溃率、任务失败类别、取消完成延迟、单轮请求次数与费用。先建立真实基线，再设阈值；不要从当前通过的测试数量推导线上可靠性。

README 的环境要求目前写成 Flutter ≥3.12.0、Dart ≥3.12.0，而本轮及 CI 实际验证的是 Flutter 3.44.0 / Dart 3.12.0，且仍有占位 clone 地址。应写清可复现的 SDK 组合、各子项目定位、贡献/检查步骤和支持平台。现有资料较多，建议维护一个当前文档索引，将历史验收记录与当前操作说明分开。

**五、按成本排序的实施计划**

| 时间 | 工作包 | 交付与验收 |
| --- | --- | --- |
| 1–7 天 | F01 数据静默丢失、F02 上传恢复、F03 服务依赖更新；补 MCP 忽略规则 | 为两处复现建立期望正确行为的回归；隔离依赖测试及适用漏洞审计通过；运行数据不可误提交 |
| 1–2 周 | 明确 Web 原型去留；修类型检查；整理现有变更并提交完整 CI | 干净 checkout 可执行统一检查；Web 若保留，lint/typecheck/build/test/audit 均有门槛；78 个格式差异单独提交 |
| 2–4 周 | 发布追溯、历史 schema 与恢复演练、正式设备验收 | 一个固定提交可重建 Windows/Android 产物；当前支持版本的升级和恢复有证据；已知限制透明 |
| 30–60 天 | 设置页与设置持久化拆分；继续缩小 ChatController 职责；抽离文档核心 | 每次拆分保持既有行为与回归；减少跨层引用；新模块可独立测试 |
| 60–90 天 | 大数据性能、服务资源预算、旧功能退役和无障碍修复验证 | 形成量化基线；移除无用户/无负责人维护的实验负担；完成至少一次恢复与发布演练 |

对单人或小团队，建议为每个功能标注“正式支持、实验、兼容保留、归档”之一，并明确平台范围。持续维护成本首先来自承诺范围，其次才是代码行数。每个迭代预留固定维护容量，优先处理数据、安全与发布问题，不以新增功能数量替代质量进展。

**六、证据、复现方式与边界**

本轮日志与机器可读审计结果保存到 `output/maintenance-audit-2026-09-22/`（被 Git 忽略），包含 Flutter 测试/分析/覆盖率、Python 隔离测试/依赖审计、npm 审计、类型检查、原生构建与两项缺陷复现结果。为避免混入用户业务数据，复现只使用人工构造内容与临时数据库。

缺陷复现脚本保存在 `tmp/maintenance-audit-20260922/`，并随证据复制。Flutter 脚本需从本项目执行，Python 脚本需把 `server/` 加入 PYTHONPATH。

```powershell
flutter test --no-pub tmp/maintenance-audit-20260922/data_loss_probe_test.dart --reporter expanded
$env:PYTHONPATH = (Join-Path (Get-Location) 'server')
python tmp/maintenance-audit-20260922/upload_atomicity_probe.py
```

未执行：macOS/iOS/Linux 原生构建，真实设备覆盖升级与厂商后台策略，真实模型/生图/远程文档服务调用，当前正式 Windows 入口的屏幕阅读器人工验收，线上压力测试，Git 历史完整密钥扫描，以及远端发布与分支保护审计。历史文档中的 Android 模拟器及真实 Computer Use 验证被作为既有记录阅读，没有冒充本轮复验。

**本轮原生构建补充记录**

- Windows：原生 Debug 构建及可靠性集成测试通过。存在 NuGet 提示与 `webview_windows` CMake CMP0175 开发警告，本次没有阻断构建，应在工具链维护中跟进。
- Android：ARM64 Debug APK 构建通过，耗时约 242 秒。出现 AGP 8.9.2 与 Kotlin 2.1.20 将不再被后续 Flutter 支持的提示；提示建议的最低版本分别为 8.11.1 和 2.2.20，并列出了仍应用 Kotlin Gradle Plugin 的插件。升级时应一起验证 Gradle、JDK、Built-in Kotlin 与原生插件，不能以跳过依赖校验替代修复。本次没有执行发布签名构建或设备安装。
