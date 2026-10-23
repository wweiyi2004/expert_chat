# 架构与规划入口

更新日期：2026-10-22。当前主规划是 **V2 整体重构：共享 Rust Agent 核心 + Android 原生宿主 + 电脑宿主/CLI + Flutter 工作区**。

先以最小原型验证两端共用核心、原生工具回调、流式事件和取消，再决定扩大业务迁移。当前交付为规划文档；V2 工程与设备 Agent 尚未实现。

## 当前主规划

| 文档 | 内容 |
| --- | --- |
| [V2 架构](V2-ARCHITECTURE.md) | 六个一级模块、平台宿主、共享核心、目录、数据所有权与复用策略 |
| [V2 重建计划](../plans/AGENT-V2-REBUILD.md) | V0–V5：验证、核心闭环、手机操作、远程电脑、业务迁移和切换 |
| [V2 开发者工作区](V2-DEVELOPER-WORKSPACE.md) | 必做能力：MCP、Agent/Git 钩子、任务 worktree、文件状态树与分支提交图 |
| [任务与设备语义](TASK-AND-DEVICE-CONTRACTS.md) | 两种方案共用的任务身份、执行目标、取消、事件和恢复约定 |

与此前方案相比，共享 Rust 核心从后期可选项调整为先行验证的架构基础。Flutter 负责工作区交互；Kotlin 宿主持有 Android 核心实例并提供系统能力；电脑宿主独立运行同一套 Rust 核心。正式实现前先通过真机桥接与取消验证，不同时建设两套长期任务引擎。

## 当前实现基线

- 现有代码仍是 Flutter/Dart 主应用，已经包含四协议模型适配、工具循环、语音、学习、创作、资料、记忆和科研终端。
- Python 文档 MCP 继续是独立文档服务；旧 Gateway/AuthService 为兼容部署，React Web 工程为实验原型。
- 已有 MCP 接入基础；完整 Agent 钩子、任务 worktree 管理和 Git 图形工作区仍属 V2 规划。
- 当前应用标记 `3.6.1+4109`，SQLite schema 17，备份容器 ECBACKUP v1。
- 最近客户端基线为 1462 项测试通过，日志位于工作区 `output/protocol-auto/verified-client.log`。这些测试是迁移参考，不代表 Rust V2 已验证。
- [当前 HTML 框图](../project-map.html) 展示现有实现，不把规划中的 Android Agent 和电脑运行时标作已完成。

## 现有职责定位与增量备选

| 文档 | 在 V2 规划中的用途 |
| --- | --- |
| [模块地图](MODULE-MAP.md) | 查找已有职责、模块来源和混合边界 |
| [依赖规则](DEPENDENCY-RULES.md) | 参考数据所有权和避免过度设计的原则；V2 模块组织见主规划 |
| [旧目标目录](TARGET-STRUCTURE.md) | 增量迁移备选，不与 V2 目录方案并行落地 |
| [模块登记表](module-catalog.json) | 保留原有 23 项职责和来源路径，不作为 V2 package/crate 清单 |
| [增量实施计划](../plans/AGENT-EVOLUTION.md) | V0 无法通过或决定收窄改造范围时的备选 |
| [增量基线快照](INCREMENTAL-BASELINE.md) | 保存此前的设计依据、现状调查和文档验证记录 |

本轮更新仅调整规划与入口，未移动业务源码、创建 V2 运行工程或改变用户数据。下一项可实施工作是 V0 最小贯通验证。
