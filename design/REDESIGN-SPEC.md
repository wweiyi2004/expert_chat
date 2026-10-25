# Expert Chat 界面改版参照规范

版本：2026-10-25 · 基线：v3.8.1+4113，分支 `codex/v3.6.1-ui-directory`（含未提交改动）
状态：用户已确认的设计方向。本文是实现依据；原型只用来看交互和视觉，冲突时以本文为准。

## 0. 参照物

| 文件 | 用途 |
|---|---|
| `design/expert-chat-redesign.html` | 可点击原型。需要和 `design/palettes.js`、`design/branding/expert-chat-mark.svg` 放在一起打开。右上角切换电脑、手机和明暗模式 |
| `design/feature-inventory.md` | 现有约 210 项功能的清单，列出入口、文件、前置条件。**改版后每一项都必须还能用到** |
| `design/palettes.js` | 从 `lib/core/theme.dart` 提取的原有 14 套配色 |
| `docs/PROJECT-PLAN.md` | 产品主规划。改完后按惯例在里面追加一节，记录实施和验收情况 |

原型里的回复、执行结果、文件内容都是假数据。原型里点击后只弹一条提示的功能（附件、搜索、大纲、Git 提交图、执行位置的配置页等），**在软件里沿用现有实现**，不要按原型删掉或简化。

## 1. 不能改的东西

1. **聊天和工作是两种独立的会话。**
   - 顶栏切换"聊天 / 工作"时，**新开**一个对应类型的会话（`ChatSessions.switchConversationMode`）。
   - 不给已有会话改类型，不把项目和工具授权转到另一种会话。
   - 工作模式的底层行为（模型解析 `work: true`、关闭推理防护、响应超时、提问工具和角色工具、工作区工具）保持不变。
   - 全局"新对话"进入聊天，从工作区分组里新建进入工作。
2. **功能只改入口，不删。**
   - 以 `design/feature-inventory.md` 为准，除了第 6 节列出的死代码。
   - 低频功能可以收进二级位置，但要能找到。
3. **原有 14 套配色的色值不改。**只新增配色。`ColorThemePref` 按 `name` 存储（`wire => name`），新增枚举值不影响旧存档。
4. **工作台拖动规则不变**（`chat_page.dart` 的 `_PaneResizeHandle`）：
   - 默认宽 560。
   - 范围 340 ~ `clamp(可用宽度 − 430, 340, 900)`。
   - 拖动时退出放大状态；可用宽度 < 820 时不停靠，改为整页打开。
5. **数据兼容。**
   - `projectId` 等字段名不改，界面文案可以改。
   - 新增的偏好字段要进 `UiPrefs.toJson/fromJson`、完整备份和配置迁移；旧版本读到不认识的值时回落到默认值。
6. **不碰正在运行的版本。**构建输出放到新的独立目录。

## 2. 视觉规范

### 2.1 Token

能放进 `AppMetrics`（`lib/core/theme.dart`）的就放进去，组件里不要写散值。

| 类别 | 值 | 说明 |
|---|---|---|
| 间距 | 4 · 8 · 12 · 16 · 24 · 32 | 8 的倍数；分组之间用间距隔开，少用分割线 |
| 圆角 | 8（小）· 12（中）· 18（大） | 沿用现有 `cornerStyle` 的映射 |
| 动效时长 | 150ms 悬停和按下 · 200ms 状态切换 · 280ms 列表重排 | 退出比进入短 |
| 动效曲线 | `Cubic(0.2, 0, 0, 1)` | 统一 |
| 点按目标 | 手机 ≥ 44×44 逻辑像素 | 图标按钮、模式切换、列表行 |
| 字重 | 标题 600，正文 400，强调 500 | 层级靠字重和颜色，不靠一味放大字号 |
| 正文 | 14 / 行高 1.7（消息） | 和"阅读排版"设置联动 |

- `MediaQuery.disableAnimations` 为 true 时，所有循环动画停在静态帧，重排不做位移动画。
- 颜色比例按 60-30-10：大面积是 surface/panel，结构用 ink/line，主色只用在主操作、选中、链接和进度上。
- 状态色（执行中、完成、需要确认、失败）固定色相，和主色分开。

### 2.2 状态指示（侧栏、任务列表、回到对话共用）

| 状态 | 指示 | 颜色 |
|---|---|---|
| 执行中、子代理执行中 | 12px 圆环，2px 线宽，有缺口，0.8s 匀速旋转 | 运行色（琥珀） |
| 等你批准、等你回答 | 圆点，1.8s 呼吸（透明度 1 → 0.35，缩放 1 → 0.75） | 确认色（红） |
| 已完成未查看 | 静止圆点 | 主色 |
| 已完成 | ✓，出现时 300ms 弹出 | 完成色（青绿） |
| 失败 | 静止 ✕ | 确认色 |
| 已暂停、空闲 | 8px 灰点 | faint |

把现有 `conversation_execution_indicator.dart` 的各个状态映射到上表。

**子代理状态胶囊**（`agent_cluster_card.dart`、`work_agents_panel.dart`）：
- 执行中：旋转半圈加"执行中"。
- 排队：虚线圈，4s 慢转，加"排队"。
- 完成：✓ 弹出加"完成"。
- 胶囊底色用对应状态色的浅色版。

## 3. 信息架构

### 3.1 电脑（宽度 ≥ 840）

```
┌ 侧栏 252 ─────────┬ 主区 ─────────────────────┬手柄┬ 工作台（仅工作会话）┐
│ 图标 Expert Chat  │ 标题   [聊天|工作]   ☰ ⋯ │ 10 │ 改动 | 运行 | 助手  │
│ 搜索  ✎新聊天     │                           │    │                     │
│ ─ 可滚动 ─        │   消息流                  │    │                     │
│ 工作              │                           │    │                     │
│   ▾ 执行位置分组  │ 轮次条（工作）            │    │                     │
│ 聊天              │ 输入框                    │    │                     │
│   ▾ 资料集分组    │                           │    │                     │
│ 创作 / 学习       │                           │    │                     │
│ ─ 固定 ─          │                           │    │                     │
│ ⟳ 自动化 · 资料库 · 设置 · [N 个操作等你批准]│ │                     │
└───────────────────┴───────────────────────────┴────┴─────────────────────┘
```

- **去掉最左边 64px 的窄导航栏**（`desktop_navigation_rail.dart`）。它的入口移到侧栏底部，或者按 §4.10–4.12 归到新位置。
- 侧栏收起后，主区左上角留"展开侧栏"和"新聊天"两个按钮，沿用现在导航栏收起时的行为。

### 3.2 手机（宽度 < 840）

- **不用底部页签。**打开就是对话；左上 ☰ 打开抽屉，抽屉里就是同一份侧栏（含固定底部）。
- 顶部一行：☰ · 居中的"聊天 | 工作" · ✎。下面一行：会话标题，加执行位置（工作）或资料集（聊天）芯片，点芯片可以切换。
- 弹层统一从底部弹出（bottom sheet）；工作台也是底部弹层，占屏幕约 78% 高度。

### 3.3 一级入口

`ShellTab.navigation` 改为：**对话 · 自动化 · 资料库 · 设置**。

- `tools` 不再是一级入口，它的内容按 §4.10–4.12 分流。
- 科研、学习、创作页面继续保留状态，作为二级页面打开。
- 学习、创作、科研三个开关继续控制对应入口和侧栏分区是否显示。

## 4. 逐块规范

每项按"现状 → 目标 → 验收"来写。

### 4.1 侧栏（`chat_workspace_sidebar.dart`）

- **分区**：
  - "工作""聊天"两个分区上下排列，同时显示，代替现在二选一的筛选。
  - 已开启的模式另外加"创作"（故事、角色大乱斗）和"学习"（导师会话）分区，没有会话的分组不显示。
  - 每个分组可以折叠，折叠状态要记住。
- **工作分区**：
  - 按执行位置分组：默认工作区、各本机项目、各 SSH 配置。
  - 分组标题前面放类型小标签（本机 / SSH），标题右侧 ＋ 在该位置新建工作会话。
  - 保留"只看进行中"的筛选，可以放在分区标题的菜单里。
- **聊天分区**：
  - 按资料集分组（就是原来的"资料项目"，界面上改名为"资料集"），另有"未引用资料集"一组。
  - ＋ 新建引用该资料集的聊天。
- **按最近活动排序，有新动静就往上移**：
  - 排序键取会话的 `updatedAt` 和最近一次执行检查点（`SessionExecutionCheckpoint`）时间中较大的那个。
  - 分组之间按组内最新的会话排，组内的会话也这样排。
  - 位置变化时做 280ms 的位移动画，靠 key 保持条目身份。
  - 鼠标停在侧栏里的时候先不重排，等指针离开再排，避免误点。
- **固定底部**：
  - 自动化（显示启用中的条数）、资料库、设置这三项固定，不随列表滚动，只有上方的列表区滚动。
  - 有待批准的操作时，下面再加一条"N 个操作等你批准 →"，点击跳到第一个待批准的会话。
- **当前会话**：
  - 在对话页时，当前会话用实心底色。
  - 离开对话页去自动化、资料库或设置时，**刚才那个会话保留一层浅底**，表示"从这里来"。
- 归档、重命名、批量多选、搜索（按聊天和工作分开显示结果）都保留。
- **顶部品牌**：图标用 `assets/branding/assistant.png`，它和 `design/branding/expert-chat-mark.svg` 是同一个角色，不为此新增 SVG 依赖；后面跟文字"Expert Chat"。

验收：
- 两个分区同时可见。
- 底部三项在列表滚动时位置不变。
- 在某个会话里发消息或批准后，它和所在分组移到最上面，有动画；打开减少动效后没有动画。

### 4.2 顶栏

- 居中放"聊天 | 工作"切换（沿用 `chat_work_mode_switch.dart` 和 §1.1 的新开会话语义）。
- 故事、大乱斗、学习会话不显示切换，改显示类型标签；故事会话旁边加"情节"按钮，打开现有的情节面板。
- 右侧：大纲（☰）、更多（⋯：导出 Markdown、整理候选记忆、归档等），工作台收起时再加"工作台"按钮。
- 普通聊天的大纲、导出、记忆整理目前只能从"会话操作"进入，顶栏要加上这些入口，"会话操作"里也保留。

### 4.3 输入框（`chat_composer.dart` 等）

- 左侧：＋ 托盘（原有全部项目不变）；然后是**执行位置芯片**（仅工作会话）或**资料集芯片**（仅聊天会话）；最后是**权限芯片**（仅工作会话，显示当前模式名）。
- 右侧：
  - 模型和思考合成一个芯片，写成"模型名 · 思考：标准"，不再单写"标准"。
  - 上下文用量圆环：点开显示上下文、丢弃条数、缓存命中、费用（合并原来页脚 `work_session_footer.dart` 的指标）。
  - 发送 / 停止 / 麦克风。
- 原来页脚里的"费用 · 设置单价"移到 设置 › 模型 › 用量与单价；圆环的弹层里留一个跳过去的链接。
- 补充任务模式：输入框边框变成运行色，上方写"补充任务 · 不会打断当前轮"，带取消按钮；发出去的内容进入现有的补充任务通道（`_WorkSteeringDialog` 用的那条），下一轮生效。

### 4.4 消息、交付文件、审批卡

- 默认消息样式下：用户消息用浅色气泡（panel 色），助手消息不加气泡框，去掉气泡下方的阴影线。用户在 外观 › 消息样式 里选的样式照常生效，不要覆盖。
- **交付文件每一行**（`work_delivery_files.dart`）：
  - 路径、+增 −删、**两个带文字的按钮**："在工作台预览"，以及"打开位置"（电脑上的本地文件；行为同现在的"打开所在目录"）。
  - 手机或远端文件没法打开位置，就把第二个按钮换成"复制位置"。
  - 现在这三个操作都已经有，只是只显示图标，这次改成文字按钮。
- **审批卡**：
  - 用确认色的浅底，边框是 30% 透明度的确认色，不用实心红框。
  - 内容：类型标签、标题、等宽字体的命令、说明，以及"批准这一次""拒绝"两个按钮。
  - 手机上，待批准的卡片吸附在输入框上方，两个按钮平分宽度；消息流里留一行"↓ 待批准的操作在输入框上方"。
  - "以后不再询问"的勾选框属于 P2（§4.7），P1 先不加。

### 4.5 轮次条（新增在聊天页，在输入框上方）

- 只在工作会话里、有轮次信息时显示。
- 内容：状态胶囊（执行中 / 已暂停 / 已完成）、"第 n / m 轮"、细进度条，以及几个按钮：
  - 执行中：在本轮结束后暂停、+N 轮（N 取会话策略的 `roundExtension`）、补充任务、停止。
  - 已暂停：继续、+N 轮、补充任务、停止。
  - 已完成：继续 +N 轮。
- 复用 `work_round_controls.dart` 的逻辑。工作台的"运行 › 任务"里保留只读状态。

### 4.6 工作台（`workspace_workbench_page.dart`）

现在有 8 类标签加一个开始页，改成 **3 个标签**。每个标签里用二级分段或芯片切换，原有能力全部保留：

| 标签 | 二级内容 | 来源 |
|---|---|---|
| **改动**（显示改动文件数） | 本轮改动（文件列表 + diff，撤销文件 / 回退本轮 / 逐块回退 / 快照重建）· 全部文件（文件树 + 文件标签，查看、编辑、预览、保存）· Git（未提交改动、提交关系图、worktree） | `work_changes_page.dart`、`workspace_file_tab.dart`、`delivered_file_tab.dart`、`git_workspace_page.dart`、`git_commit_graph.dart` |
| **运行**（显示运行中的服务数） | 任务（状态、日志、停止）· 终端（可以开多个，用芯片切换）· 浏览器（人工网页 / 受控浏览器）· Services（命令和构建、常驻服务、文件 Hooks）· 日志（含任务记忆卡） | `work_task_panel.dart`、`workspace_command_panel.dart`、`workspace_browser*.dart`、`controlled_browser_panel.dart`、`work_processes_panel.dart`、`work_runtime_logs_panel.dart`、`work_memory_card.dart` |
| **助手**（显示子代理数） | 主代理（模型、指令快捷编辑）· 子代理（集群树、状态胶囊、取消、追加任务）· 子代理可用模型 · 限制与预算（深度、并发、轮数、任务预算）· 例外规则（P2） | `work_agents_panel.dart`、`agent_cluster_card.dart`、`work_agent_model_pool.dart`、`agent_instructions_editor.dart`、`task_budget_editor.dart` |

- 开始页去掉，改成各标签自己的空状态，空状态里给出常用的打开按钮。
- 工作台头部：标题、执行位置名，以及三个按钮：放大工作台 / 恢复分栏、收起工作台。
- 拖动规则见 §1.4，另外补三点：
  - 双击手柄恢复到 560。
  - 手柄设成 `Semantics` 分隔条，可以聚焦；← / → 每次 16（按住 Shift 为 64），Home / End 到最窄 / 最宽。
  - 宽度存进 `UiPrefs`，加一个 `workbenchWidth` 字段，旧数据缺这个字段时取 560。
- 手柄外观：10px 宽，中间 1px 线，上面有一个 4×38 的握把；悬停或拖动时整条变成主色浅底，线和握把变成主色。

验收：
- 原来 8 类标签里的每个功能，都能在新的 3 个标签里找到。
- 拖动、放大、收起、宽度记忆、键盘调宽都能用。
- 原有的 `chat_responsive_layout_test.dart` 等测试继续通过。

### 4.7 权限

- **P1**：保持现在的会话级三种模式（`WorkApprovalMode`：请求批准、帮我批准、完全访问），只改入口和样式。入口是输入框的权限芯片，点开是三个选项卡片，每张有一句说明。
- **P2，新功能，需要后端支持**：按工具设置例外规则。
  - 审批卡上加"在「位置名」里 · 工具类别 · 以后不再询问"。勾选后批准，就生成一条规则 `{工具类别, 执行位置或全部, 自动}`。
  - 工具类别：读取文件、写入文件、运行命令、联网、Git 提交、操作手机。
  - 规则可以在"工作台 › 助手 › 例外规则"和"设置 › 助手与技能 › 例外规则"里查看和移除。
  - 判定顺序：命中例外规则时自动执行；否则按会话模式处理。
  - 规则数据进完整备份。
  - 必须有单元测试覆盖判定逻辑。

### 4.8 执行位置（仅工作会话）

- **P1**：
  - 在一个选择器里，按类型列出现在已经能用的位置：默认工作区、本机项目（`desktop_workspaces_page.dart` 的工作区）、SSH 配置（`SessionPolicy.sshProfileId` 和 `remoteRoot`）。
  - 每项显示名称、路径和读写权限摘要。
  - 底部放"添加执行位置"，按类型跳到现有的配置页。
- **远程电脑**和 **Android 本机**目前不是会话的执行位置：远程任务有自己的页面，手机控制靠授权后由模型调用工具。P1 在选择器里把它们列为"在专用页面中使用"的入口，不假装能选。
- **P2**：把已配对的远程电脑、本机 Android 做成真正的会话执行位置，需要后端设计，先出方案给用户确认。

### 4.9 回到对话（新增）

- **电脑**：在自动化、资料库、设置这几个页面的顶栏右侧放一个"回到对话"胶囊，内容是 ← + 状态指示（§2.2）+ 会话标题 + 状态文字。
  - 状态文字示例："expert_chat · 等你批准 1 项"、"执行中 · 第 4 / 12 轮"、"已暂停"、"有新回复"、"已完成"。
  - 点击回到刚才的会话。
  - 没有弹层、焦点也不在输入控件里时，按 Esc 也能回去。
- **手机**：这些页面（包括设置的子页面）底部固定一条迷你条：状态指示 + 标题和状态 + "回到对话"按钮。
- 还有其他任务在执行、等批准或有新回复时，旁边显示"另有 N 个任务 ▾"，点开是任务列表，可以直接跳过去。
- 不管当前会话是什么类型，都显示这个入口（用户已确认）；普通聊天只显示标题。

### 4.10 自动化页（新的一级入口）

- **P1**：汇总现在已有的两类自动化，每条注明来源：
  - 远程电脑上的触发器：定时、文件变更、仓库提交、Webhook，来自 `remote_automation_panel.dart`。
  - 本机工作区的文件 Hooks，来自 `work_hook_runtime.dart`。
  - 每条显示：名称、要做什么、触发方式芯片、执行位置芯片、权限芯片、上次运行情况、"立即运行"、启用开关。
  - "新建"按来源打开现有的编辑器。
  - 远程电脑没连上时，那一组显示"未连接"，提供重连入口。
  - 远程任务页（配对、提交、审批、成果）保留，从 设置 › 连接 › 远程电脑 和这一页都能进。
- **P2**：本机的定时、Webhook 触发器，可以作用在任何执行位置上，触发后新建一个**工作**会话来执行。

### 4.11 资料库（`resources_page.dart`）

- 标签：**资料集**（原"项目"，只改文案）· 素材 · 生图记录 · 学习 · 创作。
- 资料集卡片：名称、文件数，以及"在新聊天中引用"按钮（新建一个聊天会话，并引用这个资料集）。
- "学习"标签：今日待复习、进行中课程、错题数，以及"开始今日复习""找导师""进入学习空间"三个按钮。都进入现有页面，导师按钮新建一个学习会话。
- "创作"标签：导演故事、角色库、世界书、角色大乱斗，都进入现有页面。
- 学习、创作开关关掉时，对应标签隐藏。
- 现在资料库有三个入口，名字也不统一；改完后统一叫"资料库"，只从侧栏底部进入。设置里原来的"资料"入口去掉。

### 4.12 设置（`settings_page.dart`）

改成 4 类。电脑上左侧是分类列表，右侧是内容；手机上先显示分类列表，再进详情页。

| 新分类 | 放进来的内容（现在的位置） |
|---|---|
| **模型** | 模型与服务、预设服务、服务编辑器、订阅与账号（ChatGPT 登录、OpenCode 说明、Magpie）、默认模型、路由组与 Auto 策略、渠道健康、DeepSeek 余额、用量统计、上下文管理、**模型单价**（从会话页脚移过来）、首次模型向导（也从这里进入） |
| **助手与技能** | 工作主代理指令、子代理角色库、角色演进、角色证据验收、聊天任务类型（自动聊天技能）、Jev 技能路由、监督模型（从"能力 › MCP 区"移过来）、任务执行预算、模型响应等待、例外规则（P2）、提示词预设（P2 并入任务类型，见 §6） |
| **连接** | 执行位置（本机工作区及目录权限、SSH 主机及科研终端入口、远程电脑配对及远程任务页、Android 本机控制）、MCP 服务器（HTTP、本地 stdio、Playwright 预设、Windows 电脑操作）、工具注册表与依赖诊断、数学工具、文档网关、多媒体服务（识图、生图、语音识别、语音合成）、联网搜索 |
| **外观与数据** | 配色（§4.13）、明暗模式、文字大小、阅读排版、更多外观、朗读偏好、**功能模块开关**（学习、创作、科研，从工具页移过来）、长期记忆、完整备份与恢复、API 配置迁移、清除缓存、关于与更新、更新下载源、帮助与反馈 |

- 设置首页把"关于"显示两次的情况去掉，只保留一处。
- **科研终端**页面（`research_terminal_page.dart`）保留，从 设置 › 连接 › SSH 主机 › 打开科研终端 进入；工作会话的执行位置是 SSH 时，工作台 › 运行 › 终端里也给一个"在科研终端中打开"的入口。

### 4.13 配色

- **P1**：新增 8 套"艺术配色"，色值见附录 A，直接加到 `ColorThemePref`（加 label、描述）和 `_Palette.of` 里。
  - 设置里分两组显示："艺术配色（中国传统色、和田三造《配色辞典》）"和"原有配色（14 套）"。
  - 每个色样显示 3 到 4 个来源色块，加名称和来源。
- 默认配色保持现在的 `minimal`，不替用户切换。
- 验收：写一个测试，遍历全部配色 × 明暗两种模式，检查 `onSurface/surface`、`onSurfaceVariant/surface`、`onPrimary/primary`、`primary/surface`、`secondary/surface` 的对比度。前四项 ≥ 4.5:1，`onSurfaceVariant` ≥ 4.5:1。
  - 原有的"日辉"（`solar`）在浅色模式下 `onSurface/surface` 只有约 4.1:1，这个测试会报出来。处理方法：在测试里把它列为已知例外并注明原因，**不要擅自改原有色值**，在 PROJECT-PLAN 里记一条，交给用户决定。
- **P2**：自定义配色。
  - 用户选 4 个颜色：主色、纸色、墨色、辅色。
  - 其余颜色在 OKLCH 色彩空间里推算，规则见原型 `expert-chat-redesign.html` 中"配色引擎"一段（函数 `fromArt` / `fit` / `semantic`）：底色和面板只带极少的纸色色相，文字沿亮度方向调整到对比度达标，超出 sRGB 色域时只降饱和度。
  - 需要：一个 Dart 版的 OKLCH 工具和单元测试、`UiPrefs` 新字段、完整备份和配置迁移兼容。

### 4.14 图标

- 品牌形象沿用 `design/branding/expert-chat-mark.svg`（猫耳助手）。
- 目前 Android 的启动图标 `android/app/src/main/res/mipmap-*/ic_launcher.png` 还是 **Flutter 默认图标**，要用这个 SVG 生成：
  - Android 自适应图标：前景是角色，背景是青色渐变或纯色。
  - Windows `.ico`：多尺寸。
- 用什么工具生成都可以；如果要加开发依赖（比如 `flutter_launcher_icons`），先跟用户说明。

## 5. 分阶段实施与验收

每个阶段结束都要：
- `flutter analyze` 没有新问题，`flutter test` 全部通过（目前有 221 个测试文件）；新改的界面补 widget 测试。
- 在手机 360 / 390 宽、电脑 1280 / 1440 宽下，浅色和深色各截一次图，检查有没有溢出、截断或重叠。
- 在 `docs/PROJECT-PLAN.md` 追加一节：做了什么、怎么验证的、还剩什么。

| 阶段 | 内容 | 行为变化 |
|---|---|---|
| **P0 视觉** | §2 的 token 和状态指示、子代理胶囊、交付文件改成文字按钮、审批卡样式、8 套艺术配色和对比度测试、启动图标 | 不改流程 |
| **P1 布局与导航** | 去掉窄导航栏，一级入口改为 4 个；侧栏分区、固定底部、按最近活动排序加动画；顶栏；输入框重组和页脚合并；轮次条；工作台改 3 个标签、宽度记忆、键盘调宽；回到对话；自动化页（汇总现有两类）；资料库标签；设置改 4 类；执行位置选择器（现有的几种） | 只改入口，不改能力 |
| **P2 新能力** | 按工具的例外规则；本机自动化触发器；远程电脑和 Android 做成会话执行位置；自定义配色；提示词预设并入任务类型 | 新的后端逻辑。**每项开工前先给用户出方案** |

## 6. 清理清单

删之前先 `grep` 确认没有引用；涉及用户数据的，不删数据。

| 项目 | 处理 |
|---|---|
| `chat_composer.dart` 的 `onToggleSearch` 参数（传下去了但没渲染） | 删掉参数；实际生效的联网开关在会话策略里 |
| `widgets/conversation_mode_filter.dart`（没有引用） | 删 |
| `chat_page.dart` 的页内会话列表 `_historyOpen`（阈值和外壳冲突，不会出现） | 删 |
| `WorkTaskStatusBar`（定义了但没调用） | 删，或者用到 §4.5 的轮次条里 |
| 角色库、世界书的独立页面，以及"选角色开聊"模式（没有入口） | 删独立页面的壳，保留 `*Body` 组件 |
| `model_settings_widgets.dart` 的 `ProfileSelector` / `ProfileEditPage`（没有引用） | 删 |
| `desktop_navigation_rail.dart` | P1 去掉窄导航栏后删 |
| 提示词预设页（没有入口，运行时也不读，但会存储和备份） | **不删数据**。P2 迁移进"聊天任务类型"；迁移之前先保持原样 |
| 网关 OIDC 登录 `signInGateway()`（界面没接上） | 不动，在 PROJECT-PLAN 里记为未完成 |

## 附录 A：8 套艺术配色

色值由原型的配色引擎推算：浅色和深色两套，文字和底色的对比度都已校正。
- `seed` 用的是浅色模式下的显示主色，已经校正到在底色上 ≥ 4.5:1。
- `accent` 是可以当文字用的辅色：在浅色底上 ≥ 4.5:1，白字放在它上面也 ≥ 4.5:1。这是因为 `secondary` 会被用作文字色（`workspace_file_tab.dart` 的语法高亮、`voice_conversation_panel.dart`），而且 `onSecondary` 固定是白色。
- 深色模式按 `theme.dart` 现有的 `lerp(seed, white, .35)` 规则生成主色，8 套都已验算：主色在深色底上 ≥ 5:1，`onPrimary` 在主色上 ≥ 5:1。

| 枚举名 | label | description | seed | accent | lightSurface | lightPanel | lightInput | lightBorder | lightInk | darkSurface | darkPanel | darkInput | darkBorder | darkInk |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `dailan` | 黛蓝·月白 | 靛青墨蓝 | #1179AD | #617581 | #F7FBFC | #EEF5F6 | #E7EEF0 | #D6DEE0 | #1A2435 | #111419 | #161A20 | #1D2229 | #2B313A | #DFEAEC |
| `yanzhi` | 胭脂·象牙 | 胭脂象牙 | #9C2A33 | #876C75 | #FBFAF8 | #F4F3F0 | #EEEDE9 | #DEDCD8 | #331E1A | #191211 | #201716 | #291F1D | #392D2B | #EBE8DF |
| `zhuqing` | 竹青·缟素 | 竹青素纸 | #627B4C | #61776E | #FBFAF7 | #F5F3EF | #EFEDE8 | #DEDCD7 | #1D2629 | #0E1518 | #121B1E | #192327 | #273237 | #EBE8DF |
| `jiangzi` | 绛紫·藕荷 | 绛紫藕荷 | #8C4356 | #88639D | #FEF8FA | #FAF1F4 | #F4EAED | #E5D9DD | #252133 | #141319 | #1A181F | #222029 | #312F39 | #EFE5E8 |
| `wadaSienna` | 赭石·石板 | 赭石石板 | #AE5224 | #9C6734 | #F5FCF9 | #EBF7F1 | #E3F1EA | #D1E1DA | #17272D | #0E1518 | #131B1E | #192327 | #273237 | #E1EBE6 |
| `wadaSulphur` | 深海·硫黄 | 深海硫黄 | #064F6E | #A2640C | #FCFAF3 | #F6F4E8 | #F0EDE0 | #E0DDCD | #112732 | #0F1518 | #131B1F | #1A2328 | #283238 | #EAE8DF |
| `wadaCossack` | 哥萨克绿 | 橄榄苔绿 | #437742 | #60738D | #FCFAF3 | #F6F4E8 | #F0EDE0 | #E0DDCD | #1A2819 | #111510 | #161B15 | #1D241D | #2B332B | #EAE8DF |
| `wadaViolet` | 紫罗兰·尼罗蓝 | 紫罗兰青 | #6450A1 | #00807A | #F5FCFC | #EAF6F6 | #E3F0F0 | #D1E0E0 | #331E19 | #191210 | #201715 | #291F1D | #392D2B | #DFEAEB |

来源色：

| 名称 | 来源 | 来源色（取自公开数据集） |
|---|---|---|
| 黛蓝 · 月白 | 中国传统色 | 靛青 #177CB0、月白 #D6ECF0、黛蓝 #425066 |
| 胭脂 · 象牙 | 中国传统色 | 胭脂 #9D2933、象牙白 #FFFBF0、紫檀 #4C221B |
| 竹青 · 缟素 | 中国传统色 | 竹青 #789262、缟 #F2ECDE、鸦青 #424C50 |
| 绛紫 · 藕荷 | 中国传统色 | 绛紫 #8C4356、藕荷 #E4C6D0、黛 #4A4266 |
| 赭石 · 石板 | 和田三造 · 组合 263 | Burnt Sienna #AE5224、Turquoise Green #B5DECC、Slate Color #34454C、Pinkish Cinnamon #EEB480 |
| 深海 · 硫黄 | 和田三造 · 组合 151 | Vandar Poel's Blue #064F6E、Sulpher Yellow #F5ECC2、Yellow Orange #F99D1B |
| 哥萨克绿 | 和田三造 · 组合 135 | Cossack Green #437742、Sulpher Yellow #F5ECC2、Salvia Blue #97ACC8 |
| 紫罗兰 · 尼罗蓝 | 和田三造 · 组合 345 | Blue Violet #6450A1、Nile Blue #BCE4E5、Hay's Russet #793327、Venice Green #62C6BF |

可直接粘贴的 Dart（与上表一致）：

```dart
// lib/core/theme.dart  _Palette.of 里追加（色值与上表一致）
    ColorThemePref.dailan => const _Palette(
      seed: Color(0xFF1179AD),
      accent: Color(0xFF617581),
      lightSurface: Color(0xFFF7FBFC),
      lightPanel: Color(0xFFEEF5F6),
      lightInput: Color(0xFFE7EEF0),
      lightBorder: Color(0xFFD6DEE0),
      lightInk: Color(0xFF1A2435),
      darkSurface: Color(0xFF111419),
      darkPanel: Color(0xFF161A20),
      darkInput: Color(0xFF1D2229),
      darkBorder: Color(0xFF2B313A),
      darkInk: Color(0xFFDFEAEC),
    ),
    ColorThemePref.yanzhi => const _Palette(
      seed: Color(0xFF9C2A33),
      accent: Color(0xFF876C75),
      lightSurface: Color(0xFFFBFAF8),
      lightPanel: Color(0xFFF4F3F0),
      lightInput: Color(0xFFEEEDE9),
      lightBorder: Color(0xFFDEDCD8),
      lightInk: Color(0xFF331E1A),
      darkSurface: Color(0xFF191211),
      darkPanel: Color(0xFF201716),
      darkInput: Color(0xFF291F1D),
      darkBorder: Color(0xFF392D2B),
      darkInk: Color(0xFFEBE8DF),
    ),
    ColorThemePref.zhuqing => const _Palette(
      seed: Color(0xFF627B4C),
      accent: Color(0xFF61776E),
      lightSurface: Color(0xFFFBFAF7),
      lightPanel: Color(0xFFF5F3EF),
      lightInput: Color(0xFFEFEDE8),
      lightBorder: Color(0xFFDEDCD7),
      lightInk: Color(0xFF1D2629),
      darkSurface: Color(0xFF0E1518),
      darkPanel: Color(0xFF121B1E),
      darkInput: Color(0xFF192327),
      darkBorder: Color(0xFF273237),
      darkInk: Color(0xFFEBE8DF),
    ),
    ColorThemePref.jiangzi => const _Palette(
      seed: Color(0xFF8C4356),
      accent: Color(0xFF88639D),
      lightSurface: Color(0xFFFEF8FA),
      lightPanel: Color(0xFFFAF1F4),
      lightInput: Color(0xFFF4EAED),
      lightBorder: Color(0xFFE5D9DD),
      lightInk: Color(0xFF252133),
      darkSurface: Color(0xFF141319),
      darkPanel: Color(0xFF1A181F),
      darkInput: Color(0xFF222029),
      darkBorder: Color(0xFF312F39),
      darkInk: Color(0xFFEFE5E8),
    ),
    ColorThemePref.wadaSienna => const _Palette(
      seed: Color(0xFFAE5224),
      accent: Color(0xFF9C6734),
      lightSurface: Color(0xFFF5FCF9),
      lightPanel: Color(0xFFEBF7F1),
      lightInput: Color(0xFFE3F1EA),
      lightBorder: Color(0xFFD1E1DA),
      lightInk: Color(0xFF17272D),
      darkSurface: Color(0xFF0E1518),
      darkPanel: Color(0xFF131B1E),
      darkInput: Color(0xFF192327),
      darkBorder: Color(0xFF273237),
      darkInk: Color(0xFFE1EBE6),
    ),
    ColorThemePref.wadaSulphur => const _Palette(
      seed: Color(0xFF064F6E),
      accent: Color(0xFFA2640C),
      lightSurface: Color(0xFFFCFAF3),
      lightPanel: Color(0xFFF6F4E8),
      lightInput: Color(0xFFF0EDE0),
      lightBorder: Color(0xFFE0DDCD),
      lightInk: Color(0xFF112732),
      darkSurface: Color(0xFF0F1518),
      darkPanel: Color(0xFF131B1F),
      darkInput: Color(0xFF1A2328),
      darkBorder: Color(0xFF283238),
      darkInk: Color(0xFFEAE8DF),
    ),
    ColorThemePref.wadaCossack => const _Palette(
      seed: Color(0xFF437742),
      accent: Color(0xFF60738D),
      lightSurface: Color(0xFFFCFAF3),
      lightPanel: Color(0xFFF6F4E8),
      lightInput: Color(0xFFF0EDE0),
      lightBorder: Color(0xFFE0DDCD),
      lightInk: Color(0xFF1A2819),
      darkSurface: Color(0xFF111510),
      darkPanel: Color(0xFF161B15),
      darkInput: Color(0xFF1D241D),
      darkBorder: Color(0xFF2B332B),
      darkInk: Color(0xFFEAE8DF),
    ),
    ColorThemePref.wadaViolet => const _Palette(
      seed: Color(0xFF6450A1),
      accent: Color(0xFF00807A),
      lightSurface: Color(0xFFF5FCFC),
      lightPanel: Color(0xFFEAF6F6),
      lightInput: Color(0xFFE3F0F0),
      lightBorder: Color(0xFFD1E0E0),
      lightInk: Color(0xFF331E19),
      darkSurface: Color(0xFF191210),
      darkPanel: Color(0xFF201715),
      darkInput: Color(0xFF291F1D),
      darkBorder: Color(0xFF392D2B),
      darkInk: Color(0xFFDFEAEB),
    ),
```

## 附录 B：原型和实际软件的差异

| 原型里的样子 | 实际软件里应该怎么做 |
|---|---|
| 侧栏"学习"分区里有"刷题"会话 | 刷题在软件里是独立页面（`quiz_player_page.dart`），不是会话。侧栏的学习分区只列 `ConversationMode.study`（导师）会话 |
| 回复、步骤、diff、终端输出、子代理任务 | 都是假数据。实际数据来自现有的运行时和状态 |
| "附件、搜索、大纲、Git 状态、提交图、日志、新建终端、浏览器、打开位置、导出、导入"等按钮只弹提示 | 软件里沿用现有实现 |
| 自动化页里的 4 条示例，可以选"本机 / 默认工作区"作为执行位置 | P1 只汇总现有的远程触发器和本机文件 Hooks；本机定时和 Webhook 是 P2 |
| 执行位置可以直接选"家里台式机""这台手机" | P1 不能选，只放入口跳到专用页面，见 §4.8 |
| 审批卡上有"以后不再询问"，工作台助手标签里有例外规则 | P2，见 §4.7 |
| 自定义配色（4 个颜色） | P2，见 §4.13 |
| 原型的状态色和次级文字按 OKLCH 推算 | P0 / P1 先用 `ColorScheme` 现有的生成方式，用对比度测试兜底 |
| 发消息后的轮次、子代理状态变化是脚本模拟的 | 用真实的执行状态驱动 |
