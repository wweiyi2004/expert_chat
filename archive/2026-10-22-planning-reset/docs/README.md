# Expert Chat 文档导航

## 产品与模块规划

- [架构入口](architecture/README.md)：区分当前实现、V2 主规划与增量备选。
- [V2 共享核心架构](architecture/V2-ARCHITECTURE.md)：六个一级模块、Android/电脑宿主、数据和迁移边界。
- [V2 重建计划](plans/AGENT-V2-REBUILD.md)：V0–V5 的技术验证、交付与切换条件。
- [V2 开发者工作区](architecture/V2-DEVELOPER-WORKSPACE.md)：MCP、钩子、worktree、Git 文件树与分支提交图的规划与验收。
- [现有模块地图](architecture/MODULE-MAP.md)、[依赖规则参考](architecture/DEPENDENCY-RULES.md)、[增量备选目录](architecture/TARGET-STRUCTURE.md)。
- [任务与设备协作](architecture/TASK-AND-DEVICE-CONTRACTS.md)：本机任务、Android 操作与远程电脑任务的责任边界。
- [增量演进备选](plans/AGENT-EVOLUTION.md)：保留原 P0–P6，供收窄改造范围时参考。
- [当前实现 HTML 框图](project-map.html)：浏览已实现模块与源码入口。

整体重构以独立 V2 验证为主规划，先验证共享 Rust 核心后扩大迁移；旧项目作为功能与数据基线。未来目录和能力明确标注为目标，当前没有完成 Android 跨 App 执行器或 Rust 电脑 Agent。

## 当前产品能力

| 范围 | 说明 |
| --- | --- |
| 模型与协议 | [自动协议尝试](API-PROTOCOLS.md)、[Gemini](GEMINI.md)、[模型与搜索提示词](DEEPSEEK-AND-PROMPTS.md)、[Jev 技能路由](JEV-ROUTING.md) |
| 会话与请求 | [请求策略](LLM-REQUEST-POLICY.md)、[上下文准备](REQUEST-CONTEXT-PREPARATION.md)、[生成生命周期](GENERATION-STREAM-LIFECYCLE.md)、[流式呈现](STREAM-ANSWER-PRESENTATION.md) |
| 工具与产物 | [搜索](SEARCH-TOOL-EXECUTION.md)、[文档](DOCUMENT-TOOL-EXECUTION.md)、[视觉](VISION-TOOL-EXECUTION.md)、[生图](IMAGE-GENERATION-PIPELINE.md)、[Windows 电脑操作](COMPUTER-USE.md) |
| 资料与数据 | [项目与资料浏览](WORKSPACE-BROWSING.md)、[备份兼容](BACKUP-COMPATIBILITY-AND-SUPPORT.md)、[数据可靠性](RELIABILITY.md) |
| 手机交互 | [手机布局](MOBILE-LAYOUT.md)、[附件选择](ATTACHMENT-PICKER.md)、[分享接收](SHARE-INTAKE.md)、[语音生命周期](CHAT-SPEECH-LIFECYCLE.md)、[后台生成](BACKGROUND-GENERATION.md) |
| 运行与维护 | [配置与恢复](ONBOARDING-AND-RECOVERY.md)、[维护制度](MAINTENANCE.md)、[发布验收](RELEASE-ACCEPTANCE.md)、[依赖决策](DEPENDENCY-DECISIONS.md)、[Shorebird](SHOREBIRD.md) |

## 服务与实验工程

- [当前文档 MCP 服务](../server/mcp_server/README.md)：单用户文档主链路。
- [旧 Gateway](../server/gateway/README.md)、[旧文档 REST](../server/doc_edit/README.md)、[旧认证服务](../server/authservice/README.md)：兼容已有部署。
- [科研 Web 实验原型](../remote_lab_ui/README.md)：独立 React/Vinext 参考界面。

## 历史与变更记录

- [既有系统逻辑与历史演进](system-architecture-and-logic.md)：保留 2026-09-01 基线及旧部署说明；新的模块演进以架构目录为入口。
- [历史已同意功能路线图](ROADMAP-agreed-features.md)：已完成的早期文档/生图工作；后续任务见新计划。
- [2026-10-16 工作区改造](WORKSPACE-UPGRADE-2026-10-16.md)：带日期的变更快照。
- `releases/` 保存发布说明，`reviews/` 保存审查与修复记录；它们记录当时状态，不代替当前模块状态表。

新增文档放置约定：模块边界与决策进入 `architecture/`，未执行工作进入 `plans/`，发布证据进入 `releases/`，审查记录进入 `reviews/`。已有专题说明保留稳定路径，通过本索引归类。
