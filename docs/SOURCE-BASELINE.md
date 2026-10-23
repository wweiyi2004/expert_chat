# 本轮源码现状核对

日期：2026-10-22。依据为当前工作区实际源码；没有读取归档文档。此文件提供定位证据，不另立架构方案。

| 观察 | 源码入口 | 对重新规划的影响 |
| --- | --- | --- |
| 主应用是 Flutter/Dart，版本声明为 3.6.1+4109 | [pubspec.yaml](../pubspec.yaml) | 现有 UI 与业务资产值得评估复用 |
| 聊天控制器直接关联协议、工具、文档、媒体、学习与创作，并有八个分部 | [chat_controller.dart](../lib/state/chat_controller.dart) | 任务执行与工作区业务需要分开归属 |
| 已有不依赖 Widget/Riverpod 的执行生命周期对象 | [generation_execution.dart](../lib/domain/chat/generation_execution.dart) | 有可参考的预算、取消与执行状态语义，不能说已有能力全无价值 |
| 四协议适配与自动路由已存在 | [routing_llm_provider.dart](../lib/domain/llm/routing_llm_provider.dart) | 新核心必须明确兼容范围与回归样例 |
| 已有 HTTP 和 stdio MCP 接入 | [mcp_client.dart](../lib/domain/mcp/mcp_client.dart)、[stdio_transport_io.dart](../lib/domain/mcp/stdio_transport_io.dart) | 从现有调用场景建立兼容基线，不重复发明协议 |
| 已有电脑操作相关 MCP 策略 | [computer_use_policy.dart](../lib/domain/mcp/computer_use_policy.dart) | 局部电脑操作能力不等于独立的持久电脑 Agent |
| 业务覆盖聊天、资料、项目、记忆、学习、创作和科研 | [features](../lib/features)、[domain](../lib/domain) | 产品迁入需要逐项覆盖，不以一个 Agent 演示替代全部旧功能 |
| 科研已有 SSH、文件与 tmux 相关实现 | [research](../lib/domain/research) | 保留交互终端用途，与自主任务区分 |
| Android 原生目录有 Activity、生成服务、分享接收与上传目录适配 | [Android 源码](../android/app/src/main/kotlin/com/wweiyi/expert_chat)、[Manifest](../android/app/src/main/AndroidManifest.xml) | 当前主 Manifest 未注册跨 App 无障碍执行服务，需要新增并真机验证 |
| Python 文档 MCP 与文档处理实现独立存在 | [mcp_server](../server/mcp_server)、[document_core](../server/document_core) | 可继续作为工具服务接入 |
| Web 工程是独立研究原型 | [package.json](../remote_lab_ui/package.json) | 不将其自动纳入手机主应用技术栈 |

初次规划核对时尚无新的 Rust Agent 工程。后续已新增 [电脑工作区模块](../next/desktop/README.md)，提供 CLI、目录权限和 MCP 文件工具；共享模型引擎、任务 worktree 管理、完整 Git 图形界面与用户 Agent 钩子仍需建设。仓库里的开发脚本、Git 钩子或工作树本身不算应用功能。

初次核对只做源码与文档检查。新增电脑模块的验证由 `python scripts/check.py --scope desktop` 执行，不将旧 Flutter 测试结果计为新模块通过记录。既有未提交业务源码保持原状。
