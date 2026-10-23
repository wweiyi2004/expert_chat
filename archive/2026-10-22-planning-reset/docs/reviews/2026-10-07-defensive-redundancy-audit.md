# 过度防御性编程与代码冗余审查

审查日期：2026-10-07。基线提交：`a9100d50e0786e69a73f3915762cf7691cf358e5`。开始审查时工作区干净。本轮仅增加此报告和 `output/defensive-redundancy-2026-10-07/` 下的本地复现材料，没有修改业务源码。

结论：项目存在局部、明确的过度兜底和重复实现。其中最应优先处理的是“读取失败返回默认值，再把默认值写回存储”和“把失败伪装成可用结果”。这些问题已经影响数据保全与错误语义；代码去重应排在它们之后。

**范围与判定方法**

对 Git 跟踪的自有业务源码做异常处理、兼容分支、调用引用和跨文件重复片段扫描，再深入核对高风险路径及现有测试。扫描范围含 Flutter 的 308 个非生成文件、79,333 行，Python 服务的 22 个非测试文件、4,773 行，以及 Web 主体的 10 个文件、989 行。行数含空行和注释；不包含生成代码、第三方源码、Web examples/build 配置。原生平台代码未做逐函数审查；没有进行真实模型请求或设备端验收。

Flutter 源码文本扫描匹配到 363 处 `catch (...)`，其中 167 处使用 `catch (_)`，75 处为空或只有注释。这些数字只用于选择检查位置，不能直接当作过度防御的数量或冗余率。审查重点是错误是否被合理区分、原始数据是否保留、内部不变量是否被反复补救，以及相同规则是否存在多个维护入口。

| 编号 | 优先级 | 确认的问题 | 证据类型 |
| --- | --- | --- | --- |
| F01 | P1 | 技能目录局部损坏导致启动时覆盖整份配置 | 实际启动加载探针 |
| F02 | P1 | Gateway 配置损坏与配置缺失混淆，启动覆盖原值 | 实际启动加载探针 |
| F03 | P2 | 技能自动修复生成重复项，丢失用户提示词且不幂等 | 直接调用生产方法 |
| F04 | P2 | 课程创建吞掉配置或请求错误，保存占位课程 | 控制器与内存数据库探针 |
| F05 | P2 | 生产设置写入为测试环境吞异常，出现假成功 | Provider 故障注入探针 |
| F06 | P2 | 文档 worker 把内部程序错误映射为文档或资源错误 | worker 故障注入探针 |
| F07 | P3 | 长期记忆去重规则复制三份 | 源码与调用引用 |
| F08 | P3 | 两个 LLM Provider 重复实现通用错误处理和传输片段 | 跨文件重复扫描及人工比对 |
| F09 | P3 | 六份已无必要的 `firstOrNull` 兼容扩展 | 本机 SDK 源码与项目 SDK 约束 |
| F10 | P3 | SSH 公共接口和数据类型在平台实现中重复定义 | 跨文件重复扫描及人工比对 |
| F11 | P3 | 遗留转发方法只被测试使用，旧 Provider 别名无代码引用 | 全仓引用检索 |

P1 表示优先保护用户数据；P2 表示影响行为或诊断；P3 表示可以安排的维护性简化。

**F01：技能目录读取失败后覆盖原配置（P1）**

位置：`lib/data/chat_skill.dart:192–218`，`lib/data/settings_storage.dart:241–249`。

`ChatSkillCatalog.decode()` 把整份列表解码放在一个 `try` 内。某一条技能的字段类型错误，例如 `enabled` 是字符串，就会导致整份目录退回工厂值。随后 `SettingsStorage.load()` 比较编码结果并写回，把包含其他完整、自定义技能的原始 JSON 覆盖掉。无法解析的原值没有被保留。

复现：存储两条技能，第一条含有效自定义提示词，第二条含错误类型的 `enabled`。实际调用 `settingsControllerProvider.future` 后，自定义技能消失，SharedPreferences 中的整份目录变成工厂值。本地探针已确认。

建议：明确区分缺失、正常和损坏三种读取结果；损坏时保留原始值并提供可见的恢复状态。可独立解码各条技能以保留有效记录，但不能在启动时用部分结果或默认值覆盖原始存储。仅成功迁移或用户明确修复后写回。

**F02：Gateway 配置损坏被当作旧版迁移入口（P1）**

位置：`lib/data/settings_storage.dart:177–180`、`346–358`。

`readGateway()` 对缺失和解析失败都返回 `null`；`load()` 对所有 `null` 都执行旧配置迁移并保存结果。因此，一个字段损坏会使仍可恢复的服务地址、自定义 MCP 服务等配置被整体替换。

复现：写入含有效服务地址和错误类型 `enabled` 的 Gateway JSON，调用实际设置加载后，原 JSON 被重写，原服务地址不再存在。本地探针已确认。

建议：仅在新配置键确实不存在时走旧版迁移；存在但损坏时保留原始 JSON。这里可以借鉴同一文件 `readProfiles()` 的 `corrupt` 状态，而不需要再造一套全局配置框架。

**F03：技能自动修复自身破坏不变量（P2）**

位置：`lib/data/chat_skill.dart:274–315`，特别是 `287`、`295`、`302` 行。调用入口还包括 `lib/state/settings_controller.dart:511–518`。

生成有序列表时，`byId.remove(skill.id)` 已经移除了内置技能。后面的兜底分支仍从 `byId['general']` 读取用户的“通用”技能，并用 `byId.containsKey(general.id)` 判断是否应追加。此时这些判断对内置 general 恒为不存在。

复现：六条技能均设为非回退，并给 general 写入自定义提示词，然后调用 `sanitize()`：

- 技能数量从 6 变为 7。
- `general` 出现 2 次，启用的回退项也变成 2 个。
- 自定义 general 提示词被工厂提示词替换。
- 再次调用 `sanitize()` 会再次改变结果，方法不满足幂等性。

现有“恢复一个回退项”的测试使用的是缺少 general 的输入，工厂合并自动补上了启用的回退项，没有进入上述分支。正常编辑器限制也降低了触发机会，但存储解码与设置导入仍会经过此修复逻辑。

建议：在最终唯一列表中选择并就地更新 general，或保留完整的按 ID 索引，避免用已被消费的 Map 判断存在性。验证唯一 ID、恰好一个启用回退项、用户提示词保留，以及重复调用结果一致。

**F04：课程创建把失败保存成占位结果（P2）**

位置：`lib/state/study_controller.dart:143–185`、`587–588`，`lib/domain/study/course_tree.dart:161–181`，`lib/features/study/course_list_page.dart:48–70`。

`createCourseFromTopic()` 对整个 `_completeStructured()` 使用 `catch (_) { parsed = null; }`，随后无条件构造并保存 fallback 课程。这不仅覆盖结构化输出失败，也覆盖缺失 API Key、鉴权失败、网络错误以及内部程序错误。页面收到返回值后进入课程详情，原有“创建失败”提示不会执行。

复现：设置中没有 API Key，调用创建课程，方法仍正常返回，数据库中新增课程，唯一节点为“入门”。本地内存数据库探针已确认。

建议：配置和请求失败向上返回可识别错误。若产品确实需要保留手工课程草稿，应返回明确的草稿状态和失败原因，让界面区分自动生成成功与降级结果。针对结构化内容的有限重试可以保留。

**F05：测试环境兜底进入生产设置路径（P2）**

位置：`lib/state/settings_controller.dart:196–217`，相关位置 `lib/state/chat/streaming.dart:52–62`。

`setSearchMode()` 和 `setImageGenMode()` 先修改内存状态，再吞掉 SharedPreferences 读取或写入的所有异常，注释明确说明这样做是为 widget tests 没有覆盖 SharedPreferences。真实的初始化或存储异常也会被隐藏，调用方只能看到模式切换成功，重启后可能恢复旧值。同一控制器的多数其他设置方法会传播写入异常，语义不一致。

复现：给 `sharedPrefsProvider` 注入抛出 `StateError` 的实现，调用 `setSearchMode()`，方法正常结束，内存模式已改变。本地探针已确认。

流式回复对用量缓存的读取也带有同类测试环境注释。缓存命中率允许缺失是合理的，但当前兜底把 Provider 初始化错误也视作缓存缺失；真实 `llmProvider` 本身还会读取同一个用量控制器，这个局部 catch 并不能统一解决初始化依赖。

建议：测试中显式提供 SharedPreferences 或用量仓库替身；生产写入统一报告持久化失败。对可选统计数据，通过正常的空值语义处理缺失，避免依赖捕获程序错误来初始化。

**F06：文档 worker 丢失内部错误的性质和原因（P2）**

位置：`server/document_core/runtime.py:90–120`。

内层 `except Exception` 将未知异常统一映射成 `invalid_document`；外层 `except BaseException` 又把剩余异常统一映射成 `resource_limit`。这段路径没有记录异常堆栈。因而内部 `AttributeError` 会被告知是用户文档有问题，其他中断也会被解释成资源限制，排错证据被抹掉。

复现：在隔离的直接 worker 调用中，把提取函数替换为抛出合成 `AttributeError` 的实现，得到 `invalid_document`；替换为合成 `KeyboardInterrupt`，得到 `resource_limit`。返回结果均不保留原始原因。探针仅在临时目录运行，没有处理用户文档。

建议：保留进程边界统一返回安全错误的职责。对预期解析失败、明确资源限制和未知内部异常分别处理；未知异常在服务端记录脱敏堆栈并返回 `internal_error`。父进程仍负责超时、强制结束和并发控制。这里需要修正错误分类与可观测性，而不是直接删除隔离边界的异常处理。

**F07：记忆内容去重规则有三份维护入口（P3）**

位置：`lib/data/memory_repository.dart:415–433`，`lib/domain/memory/memory_candidate_service.dart:448–466`，`lib/domain/memory/memory_transfer.dart:198–215`。

三处分别命名为 `_dedupeKey` 或 `_contentKey`，都执行小写转换、压缩连续空白和移除与汉字相邻的空格，其中两处注释直接要求与 repository 保持一致。当前规则相同，尚未发现分歧；今后改动一处会影响候选、导入和实际保存之间的重复判断一致性。

建议：抽出一个 domain 层的纯函数，供三条路径复用。保留各入口自己的权限、范围和敏感内容校验；相同校验发生在不同信任边界时，不应只为减行数删除。

**F08：两个 LLM Provider 大段复制通用基础处理（P3）**

位置：`lib/domain/llm/openai_compatible_provider.dart:362–452` 与 `lib/domain/llm/responses_api_provider.dart:680–767`；传输重复还见前者 `143–175` 与后者 `78–104`。

通用 HTTP 状态码映射、Dio 错误转换、有限大小错误体读取、JSON 消息提取和文本裁剪基本相同。精确片段扫描在去掉注释和空行后找到一个 49 行连续相同片段。两者 404 提示等协议细节仍有必要保留差异。

建议：先抽取无状态的错误体提取和通用网络错误转换，传入协议特定提示；再视收益复用字节流解码和超时设置。Chat Completions 与 Responses 的事件语义不同，适合继续保留各自的事件状态机。

**F09：六份过期 SDK 兼容扩展（P3）**

位置：

- `lib/state/chat_controller.dart:579`
- `lib/state/study_controller.dart:613`
- `lib/features/study/quiz_setup_page.dart:435`
- `lib/features/study/wrong_book_page.dart:246`
- `lib/features/study/course_node_player_page.dart:412`
- `lib/features/study/course_detail_page.dart:397`

这些文件各自定义了一份 `Iterable.firstOrNull`。本机 SDK 的 `C:/src/flutter/bin/cache/dart-sdk/lib/collection/iterable.dart` 已在 `@Since("3.0")` 的 `IterableExtensions` 中提供同样能力，并由 `dart:core` 导出；项目 SDK 下限为 Dart 3.12。`study_controller.dart` 中“older SDK”的注释已经没有适用环境。

建议：移除这六份私有扩展，使用 SDK 方法。这是本轮最明确、最容易安排的小范围冗余清理。

**F10：SSH 公共契约复制在两个平台实现中（P3）**

位置：`lib/domain/research/research_ssh_client_io.dart:10–69`，`lib/domain/research/research_ssh_client_stub.dart:6–68`。

异常类型、主机指纹模型、回调 typedef 和抽象 `ResearchSshClient` 接口几乎逐行相同。条件导出的 native/stub 实现本身是必要的平台边界，但公共接口可以只有一个定义。

建议：将公共契约放入无平台依赖的独立文件，两种实现导入相同契约，并通过现有入口重新导出。继续保留各平台 factory 和实现，避免不必要的跨平台依赖。

**F11：只被测试使用的旧转发层与无代码引用别名（P3）**

位置：`lib/domain/chat/tool_loop_policy.dart:23–34`，`lib/domain/llm/llm_request_policy.dart:62–67`，`lib/features/shell/shell_tab.dart:101–104`。

`ToolLoopPolicy.allowToolsThisRound()` 只是转发给 `LlmRequestPolicy`，参数 `workMode` 完全不参与计算。业务调用已经走 `LlmRequestPolicy.forRound()`，全仓仅 `test/tool_loop_policy_test.dart` 还调用旧转发方法。这使得测试维护着业务已不用的入口。

`shellTabIndexProvider` 是 `shellTabProvider` 的弃用别名，代码与测试均无引用，剩余提及来自历史设计文档。

建议：将轮次许可断言落到实际使用的 request policy，删除旧转发方法和多余参数；在确认没有仓库外调用方后移除旧别名。其他仍被使用的 ToolLoopPolicy 常量和轮次计算继续保留。

**已核对、应保留的保护措施**

- `lib/domain/tools/file_parser.dart` 与 `server/document_core/limits.py` 的输入、展开大小和数量上限，以及 `runtime.py` 的超时、内存和并发限制，分别保护不同进程边界。
- `lib/domain/tools/search_tool_executor.dart` 的本轮 URL 白名单与 SearchProvider 的网络访问校验承担不同职责。
- `lib/domain/tools/upload_directory_io.dart` 的真实路径解析和根目录约束应保留；字符串路径检查不能替代符号链接解析。
- `GenerationExecution`、`GenerationStream` 以及 UI 的取消/生命周期判断保护不同异步边界，不能仅凭重复出现 `isCancelled` 或 `mounted` 就合并删除。
- `ConversationPersistence` 写入串行化、损坏字段原值保留、完整备份的版本和哈希校验，以及中断恢复均有明确数据完整性目的。
- 通知、应用退出和临时文件清理的部分 best-effort catch 可以合理存在；主业务失败的可见性和清理失败的处理应分别决定。
- 本机文档记录的 Windows 引擎崩溃保护有复核条件。旧 Gateway/AuthService 在维护约定中仍属兼容保留；平台 stub、旧数据迁移和已知服务商协议差异也不能只因“兼容”字样判为冗余。

**验证结果与证据**

| 检查 | 结果 |
| --- | --- |
| `flutter test --no-pub test output/defensive-redundancy-2026-10-07/audit_probes_test.dart --reporter expanded` | 1,241 项通过：现有测试 1,237 项，加本次 4 项当前行为探针 |
| `dart output/defensive-redundancy-2026-10-07/probe_catalog.dart` | 直接确认 F01 解码回退和 F03 重复项、提示词丢失、不幂等 |
| Python worker 合成故障探针 | 确认 F06 两类错误映射；资源限制函数仅在该探针中替换，生产源码未变 |
| `uv run --project server --frozen --no-sync pytest -c server/pyproject.toml server/gateway server/mcp_server server/document_core -q` | 37 项通过、3 个子测试通过；1 条第三方 AnyIO/Starlette 弃用提示 |
| `npm run typecheck --prefix remote_lab_ui` | 通过 |
| `npm run lint --prefix remote_lab_ui` | 通过 |
| `flutter analyze --no-pub` | 退出码 1，共 3 条 info，均在 `integration_test/upload_directory_test.dart`：1 条不必要导入、2 条 `avoid_print`；没有将其算作业务缺陷 |
| `python scripts/check_repository.py`、`git diff --check` | 通过 |

本次探针断言的是当前问题行为确实发生，探针通过表示问题已复现，不表示问题已修复。现有回归全部通过也说明这些特定输入与语义缺陷目前没有被正确的预期行为断言覆盖。

本地材料：`output/defensive-redundancy-2026-10-07/flutter-tests.log`、`audit_probes_test.dart`、`probe_catalog.dart`、`probe_worker.py`、`catalog-probe.jsonl`、`worker-probe.jsonl`。探针使用合成配置、临时目录和内存数据库，不访问用户存储或真实模型服务。

**建议处理顺序**

1. 修复 F01/F02 的原始配置保留，阻止启动时破坏可恢复数据。
2. 修复 F03 的唯一性和幂等性，并为真实失败输入建立正确的回归断言。
3. 统一 F04/F05/F06 的错误传播、降级状态和服务端诊断语义。
4. 分小批完成 F07–F11 的纯去重清理，每批运行相应回归；避免将协议修改、数据迁移和组件拆分混在一起。

大型 UI 文件确有进一步划分职责的空间，但文件长度本身不能证明冗余。本轮没有发现需要推倒现有架构或引入通用防御框架的依据。

**后续执行：冗余代码清理（2026-10-07）**

用户授权删除冗余后，已完成以下清理：

| 审查项 | 实际变更 |
| --- | --- |
| F07 | 三份记忆去重规则合并为 `lib/domain/memory/memory_content_key.dart`，保存、候选与导入均调用同一函数 |
| F08 | 两个 Provider 的 HTTP 错误转换、有限错误体读取及文本裁剪合并为 `lib/domain/llm/llm_http_errors.dart`；各协议原有 404 文案继续由调用方提供 |
| F09 | 删除全部六份私有 `firstOrNull` 扩展，使用 Dart SDK 实现 |
| F10 | SSH 公共接口、异常和回调类型合并为 `lib/domain/research/research_ssh_contract.dart`；原平台模块重新导出公共类型，原入口继续可用 |
| F11 | 删除无业务调用的 `ToolLoopPolicy.allowToolsThisRound()` 与无代码引用的 `shellTabIndexProvider`；原轮次测试改为验证实际使用的 `LlmRequestPolicy` |

本次清理在计入三个新增共享源码文件后，业务源码净减少 **249 行**，行数包含空行和注释，不含测试及本报告。协议事件状态机和小段传输代码仍分别维护，配置、迁移、预算及取消行为未作调整。F01–F06 的功能问题仍保留在待修复列表中。

新增 19 项 HTTP 错误回归检查，覆盖两个 Provider 的状态码提示差异、64 KiB 读取上限、错误流中断、不同错误体格式、网络错误分类和 Unicode 字素裁剪。验证结果：

- `flutter test --no-pub --reporter expanded`：**1,256 项通过**，含原有 1,237 项和新增 19 项。
- `dart analyze lib test`：无问题。
- SSH 公共入口的合成探针通过 `dart compile js` 编译，并由 Node 执行得到 `SSH_WEB_CONTRACT_OK`，验证 Web 条件导出与公共类型兼容。
- 本次变更 Dart 文件格式检查、仓库策略检查与 `git diff --check` 通过。

全量测试日志及 Web 探针位于 `output/redundancy-cleanup-2026-10-07/`。没有提交、推送或发布代码，也没有运行真实 SSH 连接或模型请求。
