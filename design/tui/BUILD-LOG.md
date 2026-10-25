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
