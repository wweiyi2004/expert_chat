# 目标目录与迁移映射

> 本文保留现有职责定位与增量方案参考。整体重构的当前目标以 [V2 架构](V2-ARCHITECTURE.md) 和 [V2 实施计划](../plans/AGENT-V2-REBUILD.md) 为准，不同时执行两份目录迁移方案。

这是分阶段迁移后的建议布局，不是当前目录实况。本轮未创建这些空源码目录，也未移动 Flutter、Python 或平台工程。

## 1. 保持 Flutter 根工程的阶段目标

```text
expert_chat/
├── lib/
│   ├── main.dart                         # 稳定启动入口
│   ├── app/                              # 装配、启动、导航、主题
│   ├── contracts/                        # task / tool / target / artifact
│   ├── modules/                          # 用户工作区，按业务归口
│   │   ├── conversation/
│   │   ├── workspace/                    # projects / library / memory
│   │   ├── learning/
│   │   ├── creation/
│   │   ├── research/
│   │   ├── settings/
│   │   └── tasks/                        # 未来独立任务中心
│   ├── runtime/
│   │   ├── agent/                        # Dart 过渡期运行模块
│   │   └── tools/                        # 注册、路由与执行契约
│   ├── capabilities/
│   │   ├── models/                       # 四协议访问与自动尝试
│   │   ├── search/
│   │   ├── documents/
│   │   ├── media/
│   │   ├── speech/
│   │   └── mcp/                          # 传输/发现/调用/资源
│   ├── adapters/
│   │   ├── android_agent/                # Dart ↔ Kotlin 设备操作桥
│   │   └── remote_agent/                 # 配对、任务提交、事件续传
│   ├── infrastructure/
│   │   ├── storage/                      # DB / 文件 / 安全存储 / 备份设施
│   │   └── platform/                     # 分享、通知、生命周期、更新等子模块
│   └── compatibility/
│       └── gateway/                      # 旧 Gateway 与旧长任务客户端
├── android/.../expert_chat/
│   ├── MainActivity.kt                   # 宿主与绑定
│   ├── agent/                            # 未来 Kotlin 观察、动作和服务
│   └── ...                               # 现有分享、上传、生成等原生能力
├── desktop_agent/                        # 未来先建立一个 Rust crate
│   ├── Cargo.toml
│   ├── src/
│   │   ├── bin/host.rs                   # 服务入口
│   │   ├── bin/cli.rs                    # 命令行入口，共用同一任务实现
│   │   ├── contracts/                    # 当前实际使用的外部任务语义
│   │   ├── models/                       # 模型适配，按接入需求增加
│   │   ├── runtime/                      # 电脑任务引擎
│   │   ├── executors/                    # 命令 / 文件 / Git / MCP
│   │   └── storage/                      # 任务状态与日志
│   └── tests/                            # 进程、断连、恢复及协议一致性
├── contracts/agent/                      # 未来跨语言协议与事件样例
├── server/
│   ├── mcp_server/                       # 当前文档 MCP
│   ├── document_core/                    # 当前文档核心与 worker
│   ├── gateway/                          # 旧部署兼容
│   ├── doc_edit/                         # 旧文档 REST
│   ├── authservice/                      # 旧身份服务
│   └── edge/                             # 可选反向代理
├── remote_lab_ui/                        # 实验 UI，维持独立身份
├── test/modules/ + test/runtime/         # 逐模块迁移的测试归属
├── integration_test/                     # 跨模块、原生与数据恢复验收
├── docs/architecture/                   # 本轮已建立：模块设计基线
└── docs/plans/                           # 本轮已建立：阶段计划
```

`contracts/agent/` 在 P3/P4 出现跨进程使用方时建立，作为实际通信协议的样例与版本来源；`lib/contracts/` 与 Rust 的对应模块保持相同语义。P1 使用最少的 Dart 输入输出类型，不提前生成全套跨语言绑定。

暂不把整个 Flutter 项目搬到 `apps/mobile/`。Android/iOS/桌面宿主、资源路径、CI、打包与签名均依赖当前根目录，整仓搬迁的收益低于先建立内部模块边界。未来若出现第二个正式客户端，再单独评估 apps/packages 级仓库调整。

## 2. 模块内部结构

每个产品模块按需要拥有以下区域，不强制建立没有实现的目录：

```text
modules/learning/
├── api/                # 公开入口、跨模块事件和输入输出
├── domain/             # 学习领域规则与实体
├── application/        # 用例、状态协调与模块控制器
├── data/               # 学习仓库及存储适配
└── presentation/       # 学习页面与交互
```

分层在模块内部使用；仓库导航先回答“我要改哪个能力/业务”，再回答“这个模块里的界面、应用逻辑还是存储”。模型适配、MCP 连接、Rust 执行器不需要套用同一套 UI 目录模板。

## 3. 当前目录如何归口

| 当前来源 | 目标归口 | 迁移方式 |
| --- | --- | --- |
| `core/`、`features/shell/` | `app/` | 收敛启动与装配；主题和布局仍是应用级能力 |
| `features/chat/`、会话控制器、对话树/导出 | `modules/conversation/` | 先建立任务接口，随后迁移会话所有者内的实现 |
| `state/chat/` 中任务编排、预算、工具循环 | `runtime/agent/` 与 `runtime/tools/` | 以职责迁移，不整体复制 controller 形成第二个大控制器 |
| `features/projects/library/memory` 及相关仓库 | `modules/workspace/` | 归口到三个内部子域，保持资产和作用域规则 |
| `features/study/`、`domain/study/`、学习数据与控制器 | `modules/learning/` | 传统学习库和每日档案归同一业务模块，保留各自存储兼容 |
| `features/story/`、`domain/story/`、角色/世界数据 | `modules/creation/` | 对外提供上下文贡献和结果提交接口 |
| `features/research/`、科研状态与 SSH/tmux/SFTP | `modules/research/` | 保持交互终端完整性，未来以明确接口复用连接能力 |
| `features/settings/`、设置聚合 | `modules/settings/` | 模块配置接口先行，避免把全局 SettingsState 原样扩成新的总模块 |
| `domain/llm/` | `capabilities/models/` | `long_task_gateway_client.dart` 例外，归旧 Gateway 兼容模块 |
| `domain/tools/` | 各 `capabilities/*/` 与 `runtime/tools/` | 先按搜索、文档/本地文件、图像、工具路由分清所有者 |
| `domain/mcp/` | `capabilities/mcp/`，部分注册策略归 runtime/tools | 传输与模型可见工具策略分开，动态发现经公开目录接口进入任务 |
| `domain/context/` 与模式提示词组装 | 通用预算归运行/模型能力；模式贡献归业务模块 | 由产品侧组合任务快照，运行模块不反向导入学习/故事 |
| `data/db`、文件/安全 Store、备份设施 | `infrastructure/storage/` | 业务仓库回所属模块；共用数据库与恢复协调仍集中管理 |
| `domain/notify/share/clipboard/cache/update/support/html` | `infrastructure/platform/` 内对应子能力 | 保持可见子边界，不形成没有所有者的 utils 集合 |
| Gateway 客户端、旧长任务配置与 runner | `compatibility/gateway/` | 路径迁移与旧任务格式兼容分开验收 |

## 4. 目录迁移顺序

1. 先发布模块 ID、公开接口、任务/工具契约与过渡例外；落实 P1 行为边界。
2. 先迁相对独立的模型访问、学习、创作、科研模块，验证它们的公开依赖。
3. 迁移工作资料与设置，收敛跨业务配置、存储和上下文贡献。
4. 最后归口会话与任务运行的交界；它们的切换由已验证接口完成。
5. 迁移测试与文档引用，更新构建和仓库依赖检查。每批均可独立回退。

目录迁移不改变网络协议、数据库 schema、备份容器和用户文件位置。若某个模块确实需要这些行为变化，另设变更批次和验收记录。生成代码与 migration fixtures 只按工具要求同步，不能靠移动文件假定迁移已通过。

## 5. 模块拆分为 package/crate 的条件

文件夹级模块先建立所有权与依赖约束。只有模块拥有稳定 API、独立测试，并存在实际的独立发布或跨端复用需求时，才拆为 Dart package 或更多 Rust crate。电脑 Agent 首期用一个 crate 提供服务和 CLI 两个入口；现有学习、创作页面无需仅因目录重组就变成多个 package。
