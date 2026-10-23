# 项目全面审查与修改建议

修复追踪：R01–R16 的实施与最终验证见 [2026-10-15 修复记录](2026-10-15-remediation.md)。下文保留审查时的问题与复现证据。

审查日期：2026-10-13。基线提交：`a9100d5`，以当时工作区的未提交修改为准。主 agent 与三个子 agent 分别检查工程入口/设置/检查流程、Flutter 核心逻辑、数据与 UI/Web、Python 服务。没有修改业务源码，也没有覆盖已有修改。

结论：最优先的工作是修复数据覆盖、文档内容损坏、上下文与流式状态错误。项目已有较完整的测试与检查入口，但现有测试未覆盖下列跨步骤行为。建议按实际契约做小范围修改，删除会伪造成功或掩盖失败的兜底，不增加通用防御框架。

**范围与验证边界**

检查覆盖 Flutter 状态/领域/持久化/主要 UI，现用 MCP 与文档核心，旧 Gateway 兼容接口，Web 原型及 CI/依赖配置；原生入口做了抽查。这是全项目分层审查，不代表逐行穷尽每个文件。没有进行真实模型、SSH、手机/桌面原生交互验收，没有执行在线依赖漏洞审计或生产部署。

| 检查 | 本轮结果 |
| --- | --- |
| 仓库策略检查 | 通过 |
| 客户端统一 quick 检查 | 格式检查失败，停在 `integration_test/upload_directory_test.dart` |
| 单独 `flutter analyze --no-pub` | 3 条 info：同一集成测试中的一个多余 import 和两处 print；没有 error/warning |
| `flutter test --no-pub --reporter expanded` | 1256 项通过 |
| Python pytest | 37 项及 3 个子测试通过；1 条第三方弃用 warning |
| Python Ruff | 通过 |
| Web typecheck / lint / build / test | 通过，2 项测试通过 |
| 本轮针对性复现 | 见各项与 `output/review-2026-10-13/`；部分测试断言正确行为，因此当前失败是缺陷证据 |

优先级：P1 优先修复数据损坏、不可逆覆盖或当前任务关键约束丢失；P2 修复有明确触发场景的功能错误。以下路径均相对仓库根目录，行号对应本次工作区。

**R01 · P1 · 学习记录读取失败后，被后续无关编辑删除**

位置：[study_repository.dart:166](../../lib/data/study_repository.dart#L166)、同文件 181、236–240 行。

`_loadFromDb()` 吞掉单行解析错误，随后 `_syncEntities()` 把未出现在已加载列表中的 ID 全部删除。复现：插入一条不可解析的课程，正常新增一张学习卡片后，原课程行被真正删除。用户没有执行删除课程操作。

建议：停止“吞错读取后全量同步”的组合。最小修正是更新过程中读取失败即报告失败、保留原行；若要继续允许其他实体编辑，则只持久化实际变更实体。不要再用空列表兜底。补充“坏课程 + 正常卡片编辑”的回归。

证据：`data_ui_regression_test.dart`、`data-ui-regression.log`。

**R02 · P1 · 启动加载会用默认配置覆盖损坏的原始配置**

位置：`lib/data/settings_storage.dart:177–180,241–249,346–358`；`lib/data/chat_skill.dart:192–218`。

技能目录任一条字段类型错误，会使整份目录退回工厂值；启动代码随即把工厂值写回。Gateway 解码把“键不存在”和“存在但损坏”都返回 null，启动又把两者都当作旧版迁移。实测正常自定义提示词与合成服务地址均从原存储消失。

建议：仅在键不存在或成功迁移时写入；存在但解码失败时保留原值并报告配置错误。可以复用同文件 `readProfiles()` 已有的损坏状态表示，无需新增通用恢复框架。该问题是 10 月 7 日报告 F01/F02，当前仍在，本轮再次独立复现。

证据：`settings_probe_test.dart`、`settings-probe.log`。

**R03 · P1 · DOCX 替换会重复超链接文字、破坏未命中内容的格式**

位置：`server/document_core/operations.py:332–335`。

替换先读取包含超链接的 `p.text`，却只清空 `p.runs`，再把整段新文字塞进首 run。合成段落 `old ` + 超链接 `LINK`，替换后从 `old LINK` 变成 `new LINKLINK`；混合粗体/斜体也被统一成首 run 格式。现用 MCP 与旧 REST 都调用此核心。源文件未被直接覆盖，但生成结果已经损坏。

建议：按命中范围修改 run/XML 文本，保留未命中节点、格式和超链接。回归覆盖单 run、跨 run、超链接与混合格式；不能用整段重写作为“稳妥兜底”。

**R04 · P1 · 工具结果过大时，本轮用户问题被当成历史丢弃**

位置：`lib/domain/context/context_window_manager.dart:206–221`。

历史数量阶段尝试保留 user，但 token packing 阶段只留下超大的最新 assistant/tool 单元，然后 break。实测输入预算 1024 tokens、用户问题约 450 字符、工具结果 8000 字符时，最终角色是 `[system, assistant, tool]`，本轮 user 消失，末尾验收条件也没有出现在摘要中。

建议：先为最近的真实用户任务分配预算，再裁剪工具结果；不要把工具图片观察的 user 角色消息当成真实用户任务。测试应断言任务约束保留，而不仅检查总 token 数与 tool_call_id 成对。

证据：`client-context-responses-repro.dart/.txt`。

**R05 · P2 · 上下文裁剪丢失 Responses 协议状态**

位置：`lib/domain/context/context_window_manager.dart:443–451`；消费处 `lib/domain/llm/responses_api_provider.dart:250–254`。

重建 `LlmRequestMessage` 时漏传 `responseOutputItems`。实际复现裁剪前的 reasoning/encrypted state 与 function_call 两个 item 全部归零，下一次请求由原始 item 回传变为简化消息重建。代码自身的消息契约要求这些 item 原样回传。

建议：裁剪只修改允许裁剪的文本，保留协议字段；同时让预算计量覆盖实际发送的 items。不要通过丢弃状态让预算“通过”。

证据：`client-context-responses-repro.dart/.txt`。

**R06 · P2 · Responses 未完成或失败被报告为正常结束**

位置：`lib/domain/llm/responses_api_provider.dart:148–162,176–193,225–227`。

正常收到 `response.incomplete(max_output_tokens)` 后，最终仍固定发送 `finishReason: stop`。另外，代码主动兼容无尾空行的 SSE，但 EOF flush 只调用 `_handleEvent()`，遗漏主循环处理 `response.failed` 的抛错逻辑。假 HTTP adapter 实测两种输入都得到 stop、没有异常。

建议：主循环和 EOF flush 共用一套事件/终态处理；failed 传播错误，incomplete 保留截断原因，完成事件才标记正常完成。这里应合并重复处理逻辑，不应再添一套 fallback。

证据：`client-context-responses-repro.dart/.txt`。

**R07 · P2 · 图片 file_id 缓存跨账户复用**

位置：`lib/domain/llm/openai_compatible_files_client.dart:102–104`；对象生命周期见 `lib/core/providers.dart:178–185`。

缓存键只有图片内容 hash，client 在切换模型账户后仍复用。合成两个账户上传相同图片，实际只有一次上传，两次都得到账户 A 的 file_id；B 后续引用的不是自己的文件。重试同一图片继续命中缓存。

建议：缓存按规范化 endpoint、账户/凭据作用域和内容 hash 区分。凭据作用域用摘要或已有账户标识，不记录明文密钥。

证据：`client-file-cache-repro.dart/.txt`；未调用真实账户。

**R08 · P2 · 成功导出的备份无法由同版本恢复**

位置：`lib/data/full_backup_service.dart:62–74,153–154`。

导出限制 128 MB；预览/恢复另设总记录数 100000 的限制。用一条正常会话和 100000 条父子消息成功导出 39,867,410 字节后，同版本预览直接报记录超限。

建议：把备份导入、导出的既有协议限制统一，保证成功生成的文件满足恢复条件。若保留记录数上限，导出时明确拒绝；不要生成一个显示成功却不可恢复的文件。回归增加导出→预览/恢复的往返断言。

证据：`data_ui_regression_test.dart`、`data-ui-regression.log`。

**R09 · P2 · 连续短答题显示上一题答案**

位置：`lib/features/study/quiz_player_page.dart:147–150`。

TextField 没有题目 key/controller，连续两道短答题复用同一个输入状态。实测切下一题仍显示 `answer one`，但答案 Map 中新题为空，直接提交会提示“请先作答”。

建议：最小修正是为输入框设置 `ValueKey(_item.id)`，使生命周期与题目一致；如后续支持往返切题，再明确绑定按题保存的答案。

证据：`data_ui_regression_test.dart`、`data-ui-regression.log`。

**R10 · P2 · 批改服务输出错误被存成用户答错**

位置：`lib/state/study_controller.dart:443–453`；`lib/features/study/quiz_player_page.dart:55–60`。

结构化批改失败时返回 `correct:false, score:0`，UI 随即将其写入错题本。错误说明虽然提到不能自动批改，但业务状态已经把用户答案判错。本项依据明确的静态调用链，未单独做模型故障注入。

建议：让批改失败进入页面已有的“批改失败”分支，保持题目未批改；不要返回伪造分数。若需要人工判分，应是明确的产品状态。

**R11 · P2 · 表格 set_range 不能用 null 清空单元格**

位置：`server/document_core/operations.py:303`。

A1 原值为 `old`，执行 `values:[[null]]` 后仍为 `old`，接口却成功返回。`ws.cell(..., value=None)` 没有赋值；相邻 `set_cells` 路径可以正常清空。

建议：取 cell 后显式赋 `.value = _cell_py(value)`，统一两种编辑操作的语义。一个针对旧值→null 的回归即可。

**R12 · P2 · 编辑输出扩展名与真实格式不一致**

位置：`server/document_core/operations.py:119,195–206`。

TXT 编辑指定 `output_filename: result.pdf`，实测成功生成 PDF 文件名、`text/plain` MIME、TXT 字节；持久化后再次 inspect 按 PDF 解析并报 `PdfStreamError`。

建议：编辑输出复用转换路径已有的 `_sanitize_output_filename()`，按实际源格式统一扩展名。编辑不是格式转换，不需新增探测/重试兜底。

**R13 · P2 · MCP 拒绝合法的清空文本操作**

位置：`server/mcp_server/app/main.py:281–283`。

契约允许 `set_text.text=""`，核心也生成合法空文本文件，但 `_store_output()` 因 `size<=0` 删除结果并报错。替换操作删除全部文本同样受影响。临时上传 `abc` 后清空已实测。

建议：允许合法零字节文本输出，保留真实大小上限；格式有效性由文档核心负责。删除这个错误的存储限制即可，不添加替代内容。

**R14 · P2 · 旧 Gateway 后台任务重试命中原失败任务**

位置：`lib/domain/chat/long_task_runner.dart:176,439`；`server/gateway/app/main.py:1431–1438`。

客户端 retry 清空 taskId，但 create 仍使用相同 assistantId 作为 clientRequestId；服务端按此 ID 无条件返回原任务。合成 DB 实测 create→failed→相同 ID create 得到同一 taskId 与 failed 状态。

建议：每次用户明确重试分配新 attempt 请求 ID；同一次尝试的网络重发仍保留原 ID。不要取消服务端原有幂等机制。此项仅影响仍使用旧 Gateway 长任务的配置，不是当前文档 MCP 主链路问题。

**R15 · P2 · tmux 切换命令被送入前台程序输入**

位置：`lib/domain/research/tmux_service.dart:119–121`；`lib/state/research_terminal_controller.dart:671–675`。

当前会话正在运行训练进程、编辑器或 REPL 时，切换会话把命令字符串写入 PTY，而不是通过独立控制请求执行。控制器却马上更新 currentTmuxName，显示与实际连接不一致。此项根据静态调用链确认，没有连接真实 SSH 验收。

建议：经 SSH exec 定位当前连接对应的 tmux client 执行切换，成功后更新状态；分离也应针对当前 client，避免现有 session 级分离影响其他客户端。不要通过延时、重发按键或盲目写命令解决。

**R16 · P2 · 技能自动修复生成重复 general，丢失自定义提示词**

位置：`lib/data/chat_skill.dart:287–303`。

排序时已经从 byId 移除了内置技能，后面恢复 fallback 却再次用该 Map 查 general、判断是否追加。六项均关闭 fallback 时，实测得到七项、两个 general、自定义 general 提示词丢失。

建议：在最终唯一列表中就地选定 fallback，避免读已消费的 Map；断言 ID 唯一、提示词保留和 sanitize 幂等。此项是旧报告 F03，本轮已重新复现。

证据：`settings_probe_test.dart`、`settings-probe.log`。

**工程整理与已有审查的衔接**

- 先修复 `integration_test/upload_directory_test.dart` 的格式与 3 条 lint；当前统一检查会在运行测试前失败。它们是工程检查问题，不是上述业务缺陷的原因。
- 当前未提交修改已抽出记忆去重、LLM HTTP 错误、SSH 公共契约，并删除部分旧别名/扩展；10 月 7 日报告 F07–F11 不应原样作为新的待办重复提出。
- 旧报告中课程生成失败保存占位课程、为 widget test 在生产设置写入路径吞异常、worker 将未知程序错误归为文档/资源错误的逻辑仍在：分别见 `lib/state/study_controller.dart:143` 附近、`lib/state/settings_controller.dart:196–217`、`server/document_core/runtime.py:112–119`。建议继续清理这些假成功/错误分类路径，复用现有 UI 错误处理和日志。
- Web README 明确定位为演示原型，本轮不把没有真实 SSH 后端列作正式产品缺陷。它的 2 项测试也不能替代 Flutter 主客户端或真实终端验收。
- 保留有明确职责的边界：备份事务与版本校验、路径约束、取消生命周期、资源限制、同一次请求幂等。此次发现的问题多数来自错误的默认值、重复状态处理或不完整的身份作用域，不宜通过增加 try/catch、自动重试、默认数据修复。

**建议实施顺序**

1. 数据完整性：R01、R02、R03；同时解决 R08 的备份往返不一致。
2. 聊天正确性：R04–R07，围绕真实请求消息与终态验证。
3. 学习与文档功能：R09–R13、R16，均可独立小提交。
4. 使用相应功能时修复 R14/R15，再清理旧报告尚存的错误兜底。

每个修复保留一个能击中触发条件的回归即可；无需为简单 getter、平台 stub 或重复实现细节增加成套测试。

**本轮证据目录**

`output/review-2026-10-13/` 保存现有测试日志、合成复现及其输出。其中 `server_probes.py` 与 `server-probes.log` 对应 R03、R11–R14；服务端检查结果见 `server-pytest.log`、`server-ruff.log`。该目录是本地检查产物，受仓库忽略规则管理；本文件记录持久审查结论。所有复现仅使用人工合成数据与本地替身，没有发送真实聊天、文档或密钥。
