# TUI 实施日志

## 2026-10-26 · 阶段 0

- 用户确认 1A/2A/3A/4A/5A/6A，决策见 ARCHITECTURE.md。
- 开工 git status --short 为空；从 codex/v3.6.1-ui-directory 新建 feat/tui；没有已有脏文件需要隔离。
- 已阅读 AGENT-PROMPT、TUI-SPEC 全文、HTML 参考/宠物 JSON、执行端 README，检查控制器各模块及 work providers 的接入边界。执行端 README 过时，不用于当前能力断言。
- 现有 Flutter 全套基线已完成：1928 项全部通过，exit 0，输出 output/tui-build/flutter-baseline.log。尚未进行真实模型请求（0/30）。
- 协议与状态映射已写入 PROTOCOL.md / ARCHITECTURE.md；schema 和 14 组 fixtures 已建立并通过独立 JSON Schema/状态一致性验证。
- 尚未实现，不代表验收通过；所有平台/终端验证按实际结果记录。

## 范围说明

- 允许必要共享后端扩展来自本轮用户 4A；main.dart 和 native runner 的最小启动改动来自 2A。
- 后续需修改 next/Cargo.toml/Cargo.lock（crate+依赖）、session_policy/controller/approval/steering（新增能力）、测试和文档。保持现有设置默认、权限规则和独立会话不变。
- 本轮允许按任务文件逐项提交，不 push，不改写历史。子代理不自行提交，审查由 root 完成后提交。

## 验收进度

未开始：Rust build/test/clippy、Dart analyze/新增测试/回归、80/60/40×24 快照、7 步真实桥接端到端、单实例后台启动、demo 全状态、终端主题/ASCII/键位/宠物。

## 真实模型调用记录

11 次模型请求（deepseek-v4.1-flash，仅真实端到端冒烟），累计上限 30 次。已完成真实流程；之后的展示补齐使用假模型/真实临时工具测试和只读复核，不再消耗真实模型请求。

## 阶段 1 · 实施与首轮审查

- e418d96：架构、v1 协议与共享夹具提交。
- c412f3d：Windows 原生单实例桥接启用、后台启动、启动竞态处理。7 项隔离原生测试通过（包含 4 个客户端同时请求、隐藏窗口不被唤起、普通启动仍恢复窗口）。证据 output/tui-build/native/results.json。
- A1 gpt-6.1-sol：终端界面、键位、JSON 宠物、真实事件循环和快照；正在审查修订。
- A2 gpt-6.1-sol：DemoSource/BridgeSource、自动启动、脚本。真实 loopback 认证/重连/重复事件/丢失响应不重发/失败切换保持旧会话/握手超时等 7 项集成测试通过，另有请求 id 单测。两种脚本在仓库和安装目录布局均实测版本与错误退出码。
- B gpt-6.1-sol：同一 ProviderContainer 的 Dart bridge 与最小共享策略扩展；正在补充真实控制器/工具边界测试。
- 审查发现并已要求修正：首次注册工作区响应包裹结构不一致；任务 rootId 与 assistantId 混用；计划模式在批准等待中的收紧检查；会话切换时过期快照；每 250ms 重复启动原生进程；PowerShell 模块路径继承问题；多轮步骤归属；窄屏批准操作与危险状态常驻。
- root 独立 UI 审查测试首轮 4/5 通过，失败为真实浮点上下文百分比被整数读取隐藏；已退回修复。未将尚未通过的界面标为完成。
- 已建立 tool/build_tui_release.py：必须冻结、验证相同源清单后才能生成新的独立发布目录。尚未执行最终构建，也未替换运行中的旧软件。

## 阶段 2 · 冻结回归

- 第一轮全量 analyze 找到 chat/tools.dart 三处新增分支缺大括号；已修复，保留 attempt1-flutter-analyze.log 与当时源清单。
- 第二轮：全量 Flutter analyze 无问题；Flutter 1949 项通过；Rust workspace build/test 通过。workspace Clippy -D warnings 发现原有 next/desktop/src/files.rs 的 needless_late_init。为满足本任务要求的全 workspace 检查，只将 recovery_path 改为 if 表达式赋值，不改变文件发布行为；这是超出原始允许目录的最小必要修正。
- 完成凭据轮换缓存即时失效（含并发/元数据等待期间轮换），5 项针对性测试通过。Git 元数据禁用 fsmonitor/可选锁，避免跨授权根向父仓库发现；子目录文件补全沿用真实授权工具，路径逃逸拒绝。
- root 实际 Windows ConPTY 启动 demo，Ctrl+G 进入改动视图、q 返回、/quit 恢复终端并 exit 0。未把这次无色环境验证写成真实浅色/深色终端截图验证。
- 10000 条消息、120×36 TestBackend、20 次 release 渲染：median 42.25ms、P95 43.42ms；不包含网络、终端绘制 I/O 或冷启动。另已实现无变化空闲不重绘。
- WSL 中有 Ubuntu/tmux，但未安装 Linux Rust 工具链；Windows ConPTY 已测，物理 tmux/SSH 键位暂记无法自动验证。
- 正在修正 CLI 相对目录及冒号提示词的参数判断，防止无效参数启动 GUI。随后重新冻结检查，不将上一轮检查冒充新代码验证。

## 阶段 2 · 真实集成证据

- 第一个独立包：output/releases/tui-20261026-025935/ExpertChat-TUI。冻结清单 SHA256 e638c714510156487613e1c7f23309192f01908a12b7a37147807e292ccef577。完整 Flutter 1949 pass、Rust 59 pass、workspace Clippy0、native 单实例7 pass 后构建。构建目录为自有缓存，不覆盖运行包。
- 真实新 GUI PID62856，注册主 HWND4788692 后台隐藏，响应正常，GUI 进程计数1。注意 Process.MainWindowHandle 可能指向无标题辅助窗口；主窗口可见性使用原生单实例注册属性查得，不能用辅助窗口误判。
- tool/tui_live_smoke.py --run 完成新临时工作区、新 `[TUI测试]` 会话、真实文件读写与命令批准、运行中补充/撤回、显式停止/继续、断连/重连保留待批准操作、文件与差异一致、验收 accepted、GUI定位同一会话。证据 output/tui-build/live-smoke.json。工作区 E:/wweiyi/tmp/expert-tui-live-2qum45kq；会话910f0e97-93c4-4b4b-847a-e7b33ae90cd3。共11次请求，未更改全局模型设置，未使用完全访问。
- 集成审查补齐：原 live snapshot 的批准 diff/步骤增删字段为空。新增纯 evidence 适配器，仅用 hash 验证的已观察内容生成期望版本预览与每次写入统计，不新增磁盘访问、不冒充当前磁盘事实。完整差异可 Ctrl+G 查看；所有全屏视图继续显示权限。6项 evidence +6项 native 工作流通过，Rust独立审查11项通过。
- 增加 `/bridge off` 明确关闭通信服务，后台任务保留；成功 ACK 后 TUI 才退出。后续 `expert` 可在同一 GUI 实例重新开启。最后重建独立包并进行只读真实回执复核，不重复付费冒烟。

## 最终交付完成

- 代码提交 baa4ac1；最终源1159文件 SHA256 `5b08e5463f7cea8980c351a3a8cc6681f94a5fe990acd213586db79217bdad75`。
- 全量 analyze0；Flutter 1956通过；Rust 67通过；Clippy0；最终包内原生/桥接7通过；单实例7通过；42份终端快照。
- 最终包 `E:\wweiyi\Project\Software\expert_chat\output\releases\tui-20261026-045848\ExpertChat-TUI-windows.zip`，SHA256 `4e33b461d878d0e807c9339fac24d8430682f60975351e22bcd81ed2cd18c1b7`，66文件逐项核验。
- `expert` 已可用；已打开实际TUI，GUI后台单实例。具体PID和路径见 output/tui-build/final-running.json。
- 真实模型请求共11/30，之后只读验证增加0。
- [完整验收与限制](../../output/tui-build/FINAL-REPORT.md)，[启动与关闭说明](E:/wweiyi/Project/Software/expert_chat/output/releases/tui-20261026-045848/README.md)。
- 不需要手动处理补丁；未推送。物理tmux/SSH/剪贴板等未验证项已逐项说明，不标为通过。

## 2026-10-26 全面审计后的修复轮（进行中）

- 撤回上一节「全部完成」判断：审计识别47项缺陷/缺口，见 REPAIR-TRACKER.json（固定审计基线742b4c2）。本轮用户明确要求分子代理逐项修复，工作区开工干净，延续 feat/tui。
- 分工：交互代理负责 app.rs/main.rs 与交互测试；布局代理负责 ui.rs/布局模块与快照测试；后端代理负责 Dart bridge 与必要共享控制器/重试状态扩展；root 负责 source.rs/config.rs/协议协调/链接与终端集成、验证构建交付。代理间不得直接改对方文件；必要接口先协调。
- 允许的现有核心最小修改理由：补齐实际上下文整理、重试公开状态、工具轮次/中断元数据，使共享后端提供真实而非演示的数据；不另建代理循环、不放宽权限。
- 验收以每项反例回归为准；既有测试45项TUI、28项bridge、7项原生控制器仅作基线。每项都记录修复与证据，尚未修复不标通过。
- 真实模型请求此前11/30，本轮目前0；优先隔离假模型验证，保留累计上限。

- 协议修复约定已批准：context.compact、可选session.retry、thinking_elapsed_ms、真实round_id与stopped、request.error(scope=snapshot)。必要新增lib/data/models.dart的SearchActivity兼容元数据、lib/domain/llm/work_request_retry.dart共享有界重试包装与主/子模型请求调用点；只在尚未产出任何结果的临时请求失败时尝试，不对工具重试，不与已有渠道fallback叠加。

- 第一轮全量回归1968通过/3失败：新重试资格检查读取凭据，破坏已有Fake provider隔离并阻塞桌面工具、提示词更新和任务继续。已改为纯配置元数据判断，原失败测试33项独立全过，新增2项零凭据读取回归；不改原测试时限/断言。修复后的全量检查重新运行。
- 主审补齐同连接慢请求不阻塞ping/stop，迟到session.open显式superseded，Rust过滤旧会话读响应；结果未知按原Command解除在途锁并保留可恢复草稿、不自动重发。
- 47项已逐项映射实现/反例证据，最终发行验收尚在进行。布局不再篡改正文字符：CJK宽度在Paragraph自身区域保留真实字符格；模型重试计真实attempt，保留既有并发和时间预算。

## 真实发布候选验收补充（尚未最终交付）

- 候选 tui-20261026-111025 完整Flutter1973/Rust135/单实例7/包内原生7均过，但真实模型冒烟在停止后恢复失败：根任务运行身份未保存。消耗4请求，连同前轮11次累计15/30，测试任务已停止。当前候选不能标完成。
- 只读发现Windows legacy shared_preferences文件0字节；运行GUI缓存仍完整。root仅对该新[TUI测试]会话同值权限保存，成功恢复1,235,534字节有效JSON，并在原私有appdata目录备份。未输出配置正文。
- 必要额外修复授权范围：新data/atomic_windows_preferences条件平台适配、lib/main.dart在加载SharedPreferences前最小接入、把现有platform_interface依赖由dev移入生产（版本不变）、共享journal同快照限次重试与持久化revision归属。保留所有guard、不在失败时执行工具，不改pub缓存，不删用户备份。真实原始锁因未证实，但隔离Windows独占锁已复现插件setString false；文件失败保原文必须用原子替换验证。

- LIVE-01修复落地：Windows应用级原子prefs写入（同目录temp+flush+MoveFileExW，失败保旧文件），保留原键/prefix/filter/显式mock；原Windows包2.4.1与接口2.4.2仅改direct依赖分类、无版本升级。journal最多3次50/150ms退避并返回本次持久化receipt，guard仍fail-closed。原子文件7项、真实磁盘Drift+atomic prefs原生10项及其他组合94项均过；等待重新全量和新包真实恢复流程验收。

## 审计修复最终交付

- 47项审计问题已实现并逐项回归；真实验收追加LIVE-01已修复，配置已从缓存恢复、私有备份，发行程序原子替换与0键丢失实测通过。原失败测试任务在新版成功停止/恢复、重连、批准、队列撤回、真实文件和差异一致、最终accepted。
- 最终Flutter1980、Rust135、静态分析/Clippy、包内真实磁盘原生10、单实例7通过；真实模型累计24/30。没有继续调用模型。
- 最终包 E:\wweiyi\Project\Software\expert_chat\output\releases\tui-20261026-114432；ZIP SHA256 cec7a994cdab85a6f9a74a614eba86e2c1660ae632cc0bc6699b1b7c40747294；冻结1171文件，源SHA256 bdd59b956d56087fbc4fee9ef7d81147db7a944866553b090a645842a466cc77。运行包和ZIP保持封存。
- expert入口已切换并打开Windows Terminal，新GUI PID50924、TUI PID6572，GUI单实例。仅本地提交，不push。最终报告 output/tui-repair/FINAL-REPORT.html。
- 用户随后要求不再追加测试；立即停止扩测，仅收尾提交。未把未实机覆盖的tmux/SSH/所有字体/真实用户剪贴板标为已验证。

## 用户11项交互与功能完善（进行中）

- 用户新要求优先于旧TUI-SPEC：启动信息框、居中可选最近会话并确认、右下提示、原生设置/提供商/MCP、附件分类、AI自动短标题、自定义皮肤。只做必要编译与目标分析，不跑全量测试、不调用真实模型作测试，改完自动打开。
- 交互/UI/后端三代理分工；root负责皮肤配置、协议、集成构建与重开。必要共享扩展：提供商启用字段、MCP环境与HTTP头兼容消费、已选附件导入处理与按客户端会话暂存、后台会话命名；密钥保持安全存储，读取只给存在标记，省略敏感字段保存时保留原值。新stdio配置保存不自动启动，扫描单独确认。

- 本轮11项已实现并打开：原生settings/provider/MCP/ASR、来源分组、原始RGB宠物、可靠换行备选、分类附件及导入取消、启动信息卡与右下提示、居中会话选择确认、命令说明整行高亮、自动短标题、Markdown及skin自定义。原有GUI共享功能保留。
- 仅cargo check、必要目标分析及Windows/Rust release编译；本轮未运行测试套件、未作真实模型测试。Windows包 E:\wweiyi\Project\Software\expert_chat\output\releases\tui-20261026-152118，SHA256 b183b6e0cc3680ef4492209d7082232fd30f138232693dd04d8c516ec2f10ff5。expert入口已切换，新GUI35912，api-nexus目录新TUI已打开，保持1 GUI/1 TUI。
- 音频走已配置ASR；视频为前60秒最多3帧的明确受限解析，不冒称完整音视频理解。详见output/tui-refine/README.txt及代理实现记录。

## 弹窗、回复顺序、粘贴复制与空会话体验

- 按用户追加要求：设置及选择器改居中弹窗，保留关闭/返回、字段点击与滚轮，背景不可误操作；思考和合并后的工具步骤放在正文前，每条回复只一个步骤折叠入口。
- 附件默认Ctrl+V直接读取复制的文件/截图；/attach不带参数也读剪贴板，不再弹文件选择器。支持鼠标拖选Ctrl+C及/copy [all]，选区冻结原文本，复制不误中断任务。
- 新增session.ensure及client-owned空草稿生命周期，首发等待明确工作区绑定，未发消息退出/切换清理；有内容会话及既有历史不删除。仅必要编译/目标分析，不跑测试/模型。

- 本轮追加长文字展示：普通输入按可用宽度换行，长输入含终端逐字粘贴自动折叠为[char +N]，方向键可展开，保留原文发送；Alt+V提供终端拦截Ctrl+V时的直接剪贴板入口。
- 编译完成并打开 E:\wweiyi\Project\Software\expert_chat\output\releases\tui-20261026-163514；GUI3104，expert入口已切换，保持单实例。后加的字数标签仅重编Rust，复用同一份已编译GUI，未运行测试套件/真实模型测试。
