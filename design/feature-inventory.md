# Expert Chat 功能清单

> 版本基线：v3.8.1+4113（分支 `codex/v3.6.1-ui-directory`，含未提交改动），整理于 2026-10-24。
> 来源：逐个阅读 `lib/features/**`、相关 `lib/domain/**`、`lib/data/**`。频率是按入口深度和主流程位置估计的，**没有使用数据**。
> 路径相对于 `lib/`。"手机"指窗口宽度 < 840（无导航栏），"电脑"指宽度 ≥ 840。

## 0. 摘要

- 用户能看到的功能约 **210 项**，分 9 个域：聊天、工作台、电脑工作区与项目、远程与设备、科研、学习、创作、资料库/媒体/记忆、设置与基础设施。
- **一级导航实际只有三项：会话 / 工具 / 设置**（`ShellTab.navigation`）。科研、学习、创作是挂在"工具"下的子页，靠开关决定是否显示。
- **高频核心**集中在：聊天输入框、消息操作、会话列表、聊天/工作切换、工作台（文件/任务/交付）、学习会话、故事会话、复习。其余大部分是低频配置或高级功能。
- 发现 **约 12 处重复入口**、**7 处死代码或隐藏功能**，详见第 11 节。这些是重新设计时最该先处理的。

## 1. 导航结构（现状）

**手机（< 840）**
- 没有底部导航栏。顶层是单个 Scaffold 加左侧抽屉。
- 抽屉就是会话侧边栏，里面有新对话/新工作、设置齿轮、会话列表。
- 右上"更多功能（⋯）"菜单列出：资料库、工具，以及已开启的科研、学习、创作。
- 工具页和设置页的 AppBar 左上有汉堡按钮，可以重新打开抽屉。
- 在设置页按返回会回到会话页。

**电脑（≥ 840）**
- 最左是 64px 宽的导航栏：会话（显示为 home 图标）、工具、已开启的科研/学习/创作；设置齿轮固定在底部。
- 导航栏右边是 264px 宽的项目/会话侧边栏，可以折叠。折叠后，导航栏上会多出"展开侧边栏"和"新对话"两个按钮。
- 最右是主内容区。在工作模式下，宽度 ≥ 820 时工作台停靠在右侧。

**设置内部**
- 总览页分三组：个性化（外观、能力）、服务与数据（模型、数据）、关于（更新卡片）。
- 点进某一类后都是一页长列表。

## 2. 聊天

### 2.1 外壳与进入
| 功能 | 用户能做什么 | 入口（手机 / 电脑） | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 会话页 | 主聊天界面 | 手机：启动默认页；电脑：导航栏"首页"图标 | shell/app_shell.dart | — | 高 | 电脑导航栏上用 home 图标表示会话 |
| 侧边栏开合（电脑） | 收起或展开会话侧边栏 | 侧边栏头部按钮；收起后在导航栏展开 | shell/desktop_navigation_rail.dart | 电脑 | 中 | 新对话有两个入口 |
| 会话抽屉（手机） | 左侧滑出会话列表 | 标题栏抽屉按钮 | chat_page `_HistoryDrawer` | 手机 | 高 | app_shell 和 chat_page 各挂了一个抽屉 |
| 新会话快捷键 | 按 Ctrl/Cmd+N 新建会话 | 键盘 | chat_page | 需要硬件键盘 | 低 | 隐藏功能 |
| 外部分享进来 | 从其他 App 分享内容，自动开新会话并预填，不自动发送 | 系统分享菜单 | domain/share/shared_intake.dart | 仅 Android | 低 | 单个文件 ≤ 10MB |
| 后台完成通知 | App 在后台时，生成完成会弹通知 | 自动 | domain/notify/* | 非 Web | 中 | 没有设置开关 |
| 欢迎 / 空状态 | 显示"今天想完成什么？"；未配置模型时显示"配置模型以开始对话" | 空会话 | chat_page `_desktopWelcome` | — | 高 | 函数名叫 desktop，但手机上也用 |
| 错误恢复提示 | 出错时可以重试、去配置、关闭 | 消息列表顶部 | shared/recovery_notice.dart | 出错时 | 中 | — |

### 2.2 顶栏与模式
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 聊天 / 工作切换 | 在问答和多步执行之间切换当前会话 | 顶栏胶囊开关 | widgets/chat_work_mode_switch.dart | 生成中不能切；故事、多角色、学习会话里没有 | 高 | — |
| 项目 / 执行位置 | 选择默认工作区、本机项目或 SSH | 模式开关旁的 ▾、输入框上方、页脚路径条 | widgets/chat_workspace_options.dart | 工作模式 | 中 | **三个入口** |
| 工作台开合 | 在右侧停靠工作台，可拖宽或放大 | 顶栏"打开工作台"；窄屏时整页打开 | workbench/workspace_workbench_page.dart | 工作模式 | 中 | 另见 3.1 |
| 上下文用量环 | 查看上下文占比、丢弃条数、是否已摘要 | 顶栏小圆环 | widgets/context_usage_chip.dart | 开了上下文管理、聊天模式、宽度 ≥ 600 | 低 | 手机竖屏看不到；和页脚指标重复 |
| 大纲按钮 | 打开会话大纲侧栏 | 电脑顶栏 | widgets/conversation_outline_panel.dart | 宽度 ≥ 840 | 中 | 手机要从"会话操作"进 |
| 页内会话列表 | 聊天页内嵌一个可拖宽的会话列表 | 顶栏按钮 | chat_page `_historyOpen` | 非电脑外壳且宽度 ≥ 840 | — | **阈值冲突，可能永远看不到** |
| "新建"菜单 | 新建对话、导演故事或角色大乱斗 | 顶栏 + | chat_page | 仅故事、多角色、学习会话，宽度 ≥ 600 | 低 | 不受创作模式开关控制 |
| "更多"菜单 | 大纲、导出、整理记忆 | 顶栏 ⋯ | chat_page | 仅故事、多角色、学习会话 | 低 | 普通聊天要走"会话操作" |

### 2.3 输入框
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 发送 / 停止 / 麦克风 | 发送消息；生成中变成停止；输入框为空时是麦克风 | 右下圆按钮，或按 Enter | widgets/chat_composer.dart | — | 高 | — |
| + 工具托盘 | 打开附件和工具菜单 | 左下 + | widgets/composer_tool_tray.dart | — | 高 | — |
| 会话操作 | 底部面板：会话策略、大纲、导出、整理记忆 | + → 会话操作 | chat_page | 非故事、学习会话 | 中 | 普通聊天的大纲、导出、记忆**只有这一个入口** |
| 会话模型选择 | 选择模型、"自动"或路由组，可搜索 | 底栏模型按钮 | widgets/composer_model_picker.dart | 非故事、学习会话 | 高 | — |
| 深度思考与强度 | 开关深度思考并调节档位 | 底栏控件；故事、学习会话里是小标签 | widgets/reasoning_effort_control.dart | 需要模型支持 | 中 | 两套界面 |
| 工具权限快捷切换 | 在请求批准、帮我批准、完全访问之间切换 | 底栏盾牌图标 | widgets/session_policy_controls.dart | 工作模式 | 中 | 和会话策略是同一个设置的两个入口 |
| 文件按钮 | 聊天模式打开素材库，工作模式打开工作台文件 | 输入框上方"文件" | chat_page | 非故事、学习会话 | 中 | 同一个按钮，两种行为 |
| MCP 选择 | 勾选本会话可用的 MCP 服务 | 输入框上方"MCP"；或 + → 高级 | chat_page | 已发现 MCP 工具 | 低 | 两个入口 |
| 后台执行（长任务） | 把文档交给后台服务处理 | + → 高级 | domain/chat/long_task_runner.dart | 服务支持，且附件全是文档 | 低 | — |
| 改文档 | 用 MCP 文档工具编辑 xlsx、docx、pptx 等文件 | + → 改文档 | chat_page | 有文档 MCP 和可编辑附件 | 低 | — |
| 技能前缀 | 输入前缀后，本轮走该技能 | 直接打字 | domain/chat/chat_skill_router.dart | 设置里配了前缀 | 低 | **隐藏功能，没有补全** |
| 联网搜索开关（托盘） | — | — | chat_composer.dart | — | — | **死参数**：传了但没渲染 |

### 2.4 附件与图片
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 统一附件选择器 | 选最近、图片、文档、目录、素材库，可搜索、预览、多选 | + → 上传文件、上传图片、素材库 | widgets/attachment_picker.dart | 图片需要视觉能力 | 高 | 三个入口打开同一个选择器 |
| 浏览本机 / 选目录 | 调用系统选择器或上传整个目录 | 选择器底部 | domain/tools/upload_directory.dart | 需要平台支持 | 中 | — |
| 手机相册 | 选最近图片、切换相簿、跨相簿多选 | 选择器底部 | widgets/recent_photo_sheet.dart | 仅 Android 和 iOS | 中 | — |
| 图片勾选确认条 | 添加前确认要加的图片 | 输入框上方 | widgets/image_pick_confirm_bar.dart | — | 中 | — |
| 粘贴文件 / 图片 | 粘贴剪贴板里的文件或位图作为附件 | Ctrl/Cmd+V、右键菜单 | domain/clipboard/* | — | 中 | — |
| 附件芯片 | 查看、移除、下载附件 | 附件条、消息内 | widgets/attachment_chip.dart | — | 高 | 单个 10MB，总计 48MB |
| 大图查看 | 全屏看图，可保存、分享 | 点击图片 | widgets/image_viewer_page.dart | — | 中 | — |
| 独立生图模式 | 文生图，或带参考图生图 | + → 图片生成 | composer_tool_tray.dart | 已配生图 API | 中 | — |
| 回答配图 | 设为关闭、自动或始终 | + → 图片生成 → 回答配图 | composer_tool_tray.dart | 已配生图 API | 低 | 提示词会被强制改为 SFW |
| 重试生图确认 | 重试前提醒会重复扣费 | 思考面板 | chat_page | — | 低 | — |

### 2.5 消息
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 复制 | 复制单条消息 | 消息下方图标 | widgets/message_bubble.dart | — | 高 | 操作图标常驻显示 |
| 编辑用户消息 | 原地编辑后发送，产生新分支 | 用户消息下方 | message_bubble `_EditBox` | 不在生成中 | 中 | — |
| 重新生成 | 重答最后一条回复 | 最后一条回复下方 | message_bubble | 仅最后一条 | 中 | — |
| 分支切换 | 用 ‹ i/n › 在分支之间切换 | 消息下方 | domain/chat/conversation_tree.dart | 有分支时 | 中 | — |
| 记住这条 | 把消息存成长期记忆（全局或项目） | 消息下方书签图标 | chat_page `_rememberMessage` | 开了记忆 | 低 | — |
| 朗读 | 朗读回复，或停止朗读 | 回复下方喇叭图标 | domain/speech/* | 非 Web | 低 | 优先用云端 TTS |
| 多选复制 / 分享 | 长按或右键进入多选，复制 MD 或分享 | 手机长按，电脑右键 | domain/export/conversation_export.dart | — | 低 | **入口隐藏** |
| 选择文本 | 划选消息里的文字 | 直接拖选 | message_bubble | — | 中 | — |
| Markdown / 公式渲染 | 流式渲染 Markdown 和 LaTeX | 自动 | widgets/streaming_markdown.dart | — | 高 | — |
| 回到最新 | 一键滚到底部 | 浮动 ↓ 按钮 | chat_page | 离开底部时 | 中 | — |
| 文档长任务卡 | 查看后台进度，可重试、取消 | 回复上方 | message_bubble `_LongTaskCard` | 发起过长任务 | 低 | 重开 App 后自动恢复 |
| 下载生成文件 | 保存非图片附件 | 附件芯片 | message_bubble | — | 低 | — |

### 2.6 思考、引用、预览
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 思考 / 处理记录 | 展开查看思考内容和步骤时间线 | 回复上方折叠区 | widgets/thinking_panel.dart | 有推理或工具活动 | 高 | — |
| 用已有资料回答 | 中止检索，直接作答 | 思考面板 | thinking_panel | 有检索结果 | 低 | — |
| 停止任务 | 停止当前生成 | 思考面板 | thinking_panel | 生成中 | 中 | 和发送键重复 |
| 单步重试 / 命令详情 | 只重试一步；查看 stdout、stderr、退出码 | 步骤行 | widgets/command_activity_dialog.dart | — | 低 | — |
| 来源网页芯片 | 查看搜索或浏览过的网页 | 步骤下方 | thinking_panel | 有检索 | 中 | — |
| 思考翻译 | 把思考译成中文，以原文、中文或对照显示 | 展开思考后 | widgets/thinking_translation_host.dart, data/reasoning_translation.dart | 额外计费 | 低 | 工作模式的执行记录里也有 |
| 引用角标与来源栏 | 点 [n] 或"来源 · n"打开原网页 | 正文和底部 | widgets/citations_bar.dart | 回复带引用 | 中 | — |
| 世界书设定条 | 查看本轮注入了哪些设定 | 回复上方 | message_bubble | 故事模式 | 低 | — |
| 代码块复制 / 预览 | 复制代码；预览 HTML、SVG | 代码块右上 | widgets/previewable_code_block.dart | — | 中 | — |
| 整条消息预览 | 预览消息里的 HTML、SVG | 消息下方眼睛图标 | domain/html/html_snippet.dart | 消息含 HTML | 低 | 和代码块预览是两个入口 |
| HTML 预览页 | 预览与源码切换、改源码后运行、切到手机宽度、在浏览器打开 | 上面两个入口 | widgets/html_preview_page.dart | 禁止外部资源 | 低 | Windows 需要 WebView2 |

### 2.7 大纲、导出、会话策略
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 会话大纲跳转 | 列出提问和标题，点击跳转 | 手机：会话操作；电脑：顶栏 | domain/chat/conversation_outline.dart | — | 中 | — |
| 导出 Markdown | 把会话（含思考）导出为 .md | 会话操作 | domain/export/conversation_export.dart | 会话非空 | 低 | — |
| 整理候选记忆 | AI 提取候选记忆，确认后写入 | 会话操作 | memory/memory_candidate_review_sheet.dart | 开了记忆 | 低 | — |
| 允许联网检索 | 按会话开关网页检索 | 会话操作面板 | state/session_policy.dart | 默认开 | 中 | 这是实际生效的搜索开关 |
| 工具权限 / 评判模型 | 三种权限模式；"帮我批准"时可选评判模型 | 会话操作面板、盾牌图标 | session_policy_controls.dart | — | 中 | 聊天模式下也显示 |
| 工具轮次设置 | 设置初始轮数、增量、何时评估、是否自动续加 | 会话操作；工作台 | widgets/work_round_controls.dart | 工作模式 | 低 | — |
| 执行位置 / SSH | 选本机或 SSH，并填目录 | 会话操作面板 | session_policy_controls.dart | 工作模式 | 低 | — |

### 2.8 工作模式卡片与页脚
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 执行记录 | 查看步骤和用时，单步重试、停止 | 回复上方 | widgets/work_round_activity.dart | 工作模式 | 高 | 替代思考面板 |
| 提问卡 | 回答 AI 的确认问题（选项加补充） | 回复下方 | widgets/work_question_cards.dart | AI 发起提问 | 中 | 会标注来自哪个子代理 |
| 批准卡 | 批准一次或拒绝 | 最后一条回复下方 | widgets/work_approval_card.dart | 请求批准或帮我批准模式 | 中 | — |
| 交付文件 | 查看改动文件和增删行，可在工作台看、打开目录 | 回复下方 | widgets/work_delivery_files.dart | 工作模式 | 高 | 文件版本变了会提示过期 |
| 页脚指标 | 上下文、缓存、费用、执行状态、待生效设置 | 输入框上方 | widgets/work_session_footer.dart | 普通会话 | 中 | 和上下文环重复 |
| 模型单价 | 填写每百万 token 单价，用于估算费用 | 页脚"费用 · 设置单价" | widgets/model_pricing_dialog.dart | — | 低 | **不在设置页** |
| 轮次控制 / 补充任务 | 暂停、继续、+N 轮、停止、运行中追加要求 | 仅在工作台 | work_round_controls.dart | 运行中 | 低 | **聊天页没有入口** |

### 2.9 语音
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 语音输入 | 语音转文字，不自动发送 | 输入框为空时的麦克风 | controllers/chat_speech_controller.dart | 需要麦克风权限 | 中 | 系统识别边说边出字；MiMo 是录完后才识别 |
| 语音对话 | 连续对话：停顿后自动发送、朗读回复、可打断 | + → 语音对话 | controllers/voice_conversation_controller.dart | 非 Web | 低 | 面板会顶替输入框 |

### 2.10 会话列表
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 新对话 / 新工作 | 按当前筛选新建 | 抽屉、侧边栏、导航栏、工作模式顶栏 | chat_workspace_sidebar.dart | — | 高 | **至少三个入口** |
| 搜索会话 | 按标题或内容搜索，跳到命中的消息 | 手机常驻搜索框；电脑放大镜 | controllers/conversation_sidebar_controller.dart | — | 中 | — |
| 聊天 / 工作筛选 | 只看某一类会话 | 侧边栏分段按钮 | sidebar | — | 高 | 和顶栏模式切换在概念上重复 |
| 全部工作 / 正在进行 | 只看正在执行的工作会话 | 侧边栏 | sidebar | 工作筛选下 | 低 | — |
| 类型筛选 | 普通对话或全部类型 | 手机调节菜单 | sidebar | 手机 | 低 | 电脑上没有；`conversation_mode_filter.dart` **未使用** |
| 归档 | 归档、恢复会话，查看已归档 | 行菜单 | widgets/conversation_history_list.dart | — | 低 | — |
| 重命名 / 删除 | 行内重命名；删除需确认 | 行菜单 | conversation_history_list | — | 中 | — |
| 批量多选 | 批量归档、恢复、删除 | 手机长按；电脑"多选" | sidebar | — | 低 | — |
| 执行状态标记 | 等待输入、等待批准、执行中、失败、已完成未查看 | 会话行 | widgets/conversation_execution_indicator.dart | 工作会话 | 中 | — |
| 项目分组（电脑） | 按工作区或资料项目分组，可折叠、组内新建 | 电脑侧边栏 | sidebar `_desktopSidebar` | 电脑 | 中 | — |

## 3. 工作台

### 3.1 主体
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 工作台（多标签） | 打开文件、浏览器、终端、改动、任务、Agents、Services、日志等标签 | 手机全屏；电脑停靠右侧，可放大或收起 | workbench/workspace_workbench_page.dart | 工作会话 | 高 | **入口有四个**：顶栏、文件按钮、页脚指标、交付文件 |
| 开始页 / 新建标签 | 快速打开各类标签，可开多个同类实例 | 工作台没有标签时 | 同上 | — | 中 | — |
| 分栏视图 | 列表和详情两栏可拖动，双击复位 | Git、改动、Services、Agents | workbench/workbench_split_view.dart | — | 中 | 通用组件 |

### 3.2 文件与改动
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 工作区文件树 | 按树浏览目录，点击在标签中打开 | 工作台"工作区文件" | workbench/git/git_workspace_page.dart | 绑定了工作区 | 高 | 每个目录最多显示 1000 项 |
| 文件标签 | 查看、编辑、预览 md/html/svg，Ctrl+S 保存 | 文件树 | workbench/files/workspace_file_tab.dart | — | 高 | 磁盘版本变化时会弹合并对话框 |
| 交付文件标签 | 查看某一轮交付的文件 | 交付文件"在工作台查看" | workbench/files/delivered_file_tab.dart | — | 高 | — |
| 访问范围校验 | 打开或回退前校验工作区和版本 | 隐式 | workbench/files/work_file_access.dart | — | 中 | 只在出错时提示 |
| 工作改动（diff） | 撤销单个文件、回退一整轮、逐块回退、从快照重建 | 工作台"改动" | workbench/changes/work_changes_page.dart | 运行中不可撤销 | 中 | 命令产生的副作用不会回滚 |
| Git 改动 | 查看暂存区、未暂存的 diff | 文件页下拉菜单 | git_workspace_page.dart | 仅本机工作区 | 中 | 只读 |
| Git 提交关系图 | 查看最近 120 次提交，点开看 diff | 下拉菜单 | workbench/git/git_commit_graph.dart | 同上 | 低 | — |
| Git 工作树 | 查看工作树，新建分支和工作树 | 下拉菜单 | git_workspace_page.dart | 需要读写权限 | 低 | 建完要手动加为工作区 |

### 3.3 执行与运行时
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 交互终端 | 打开本机 PTY 或 SSH 终端 | 工作台"终端" | workbench/runtime/workspace_command_panel.dart | — | 中 | 窄屏有快捷键条 |
| 任务面板 | 查看任务状态和日志，可停止；轮次预算和批准卡也在这里 | 工作台"任务" | workbench/runtime/work_task_panel.dart | — | 高 | `WorkTaskStatusBar` **没有被调用** |
| 人工网页浏览器 | 内嵌 WebView 浏览网页或本地服务 | 浏览器 › 人工网页 | workbench/browser/workspace_browser*.dart | 仅部分平台 | 中 | 和受控浏览器不共享登录 |
| 受控浏览器 | 查看模型浏览器的截图，可人工接手并反馈给模型 | 浏览器 › 受控浏览器 | workbench/browser/controlled_browser_panel.dart | 需要 Playwright MCP | 低 | — |
| Agents / 代理集群 | 查看子代理任务树、用量和改动，可取消或追加任务 | 工作台"Agents" | workbench/agents/work_agents_panel.dart | — | 中 | — |
| 子代理限制 | 设置深度、子任务数、并发、轮数 | Agents 顶部 | 同上 | — | 低 | 这类配置散在多处，另见 9.2 |
| 子代理模型池 | 选择可用模型，并注明各自适合的任务 | Agents | workbench/agents/work_agent_model_pool.dart | — | 低 | 和设置里的角色库是分开的 |
| Services · 命令 / 构建 | 查看后台进程的日志和产物，可停止、重启 | Services | workbench/processes/work_processes_panel.dart | — | 中 | 日志保留 64,000 字符 |
| Services · 常驻服务 | 管理开发服务器等常驻进程 | Services | 同上 | — | 中 | — |
| 文件 Hooks | 文件变化时自动执行固定命令 | Services › 文件 Hooks | domain/workbench/processes/work_hook_runtime.dart | 仅本机工作区 | 低 | SSH 下未开放 |
| 工作日志 | 查看请求、工具、网络日志，可导出，可"核验并续接" | 工作台"日志" | workbench/logs/work_runtime_logs_panel.dart | — | 中 | 保留 7 天、200 条 |
| 任务记忆卡 | 编辑固定约束，损坏时可重建 | 日志页顶部 | workbench/logs/work_memory_card.dart | — | 低 | — |
| 子代理隔离工作树 | 子代理在独立的 worktree 里工作 | 隐式 | domain/desktop/agent_workspace_isolation.dart | — | 低 | 没有界面 |

## 4. 电脑工作区与项目
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 电脑工作区管理 | 添加目录，按子目录设置只读、读写或拒绝 | 工具页；侧边栏"管理项目工作区"；执行位置弹层 | workspaces/desktop_workspaces_page.dart | 仅 Windows（或有执行端） | 中 | **三个入口**；页面写着"终端命令尚未开放" |
| 项目管理 | 新建、编辑项目，写说明，关联最多 20 份资料 | 资料库 › 项目 | projects/projects_page.dart | — | 中 | "项目"一词有两种含义：资料项目和工作区，容易混 |
| 项目会话 | 继续对话、在项目内新建、把会话移入项目 | 项目详情 | projects_page.dart | — | 中 | — |
| 项目资料预览 | 预览资料提取出的文字，可复制 | 项目、附件选择器 | projects/project_document_page.dart | — | 低 | — |

## 5. 远程电脑与 Android 设备
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 配对电脑 | 用 HTTPS 或隧道地址加配对密钥配对，支持多台 | 工具页 › 远程电脑任务 | remote/remote_tasks_page.dart | 电脑上要运行 `tool/remote_host.dart` | 低 | — |
| 提交远程任务 | 设置目标、命令权限、轮次、续轮审查 | 远程任务页 | 同上 | 已配对 | 低 | — |
| 离线执行与事件续传 | 断线后继续运行，重连后续拉事件 | 隐式 | 同上 | — | 低 | — |
| 逐步审批与停止 | 批准某一步或停止 | 任务卡片 | 同上 | 请求批准模式 | 低 | — |
| 续轮与核验 | 追加轮次，登记核验依据 | 任务卡片 | 同上 | — | 低 | — |
| 成果下载 | 下载并校验 sha256 | 任务卡片 | 同上 | — | 低 | — |
| 远程自动化触发器 | 按定时、文件变更、仓库提交、Webhook 触发任务 | 远程任务页 › 自动化 | remote/remote_automation_panel.dart | 已连接 | 低 | **App 里唯一的自动化能力，只能用于远程** |
| 可复用项目环境 | 记录依赖和启动命令，排队启动 | 同一面板 | 同上 | — | 低 | — |
| 远程工作区浏览 | 浏览电脑上的文件和 Git | 远程任务页 | remote/remote_workspace_panel.dart | — | 低 | 只读 |
| 远程数学工具代理 | 数学工具交给电脑执行 | 隐式 | domain/remote/remote_tool_proxy.dart | 已配对 | 低 | — |
| Android 设备控制台 | 授权、观察界面、截图、停止 | 工具页 › Android 本机控制 | remote/device_agent_page.dart | 仅 Android，需要无障碍权限 | 低 | — |
| 手动节点操作 | 点击、返回、回到主屏、输入文字 | 同上 | 同上 | — | 低 | — |
| 模型操控设备 | 模型调用 `device_observe` 和 `device_action` | 隐式 | domain/remote/device_agent.dart | 工作模式且已授权 | 低 | — |

## 6. 科研工作区（SSH）
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 科研模式开关 | 显示或隐藏科研页，关闭时确认是否断开 SSH | 工具页 › 实验功能 | shell/tools_page.dart | 不支持 Web | 低 | 打开时有彩虹波纹动画 |
| SSH 连接管理 | 管理主机（密码或私钥）、测试连接 | 更多 › 连接管理 | research/research_terminal_page.dart | 科研模式 | 低 | — |
| 主机密钥信任 | 确认指纹，密钥变化时警告 | 连接时 | 同上 | — | 低 | — |
| 多 SSH 终端 | 多个终端标签 | 终端栏 | 同上 | 已连接 | 低 | — |
| tmux 会话 | 新建、切换、分离 tmux 会话 | 终端栏 | domain/research/tmux_service.dart | — | 低 | — |
| Ctrl+C 拦截 | 中断前先确认 | 终端保护 | domain/research/terminal_input_guard.dart | — | 低 | — |
| 远程文件与传输 | 浏览、上传、下载、编辑文件，管理传输队列 | 电脑右侧面板；手机底部面板 | research/research_files_panel.dart | — | 低 | — |
| 科研 AI 助手 | 生成命令或诊断输出，确认后写入终端 | 电脑右侧；手机快捷条 | domain/research/research_copilot_service.dart | — | 低 | 会脱敏 |
| 专注终端 | 终端全宽显示 | 按钮 | research_terminal_page.dart | 宽屏 | 低 | — |
| 新建工作会话 | 绑定本机或 SSH 目录，跳回会话页 | 菜单 | 同上 | — | 低 | — |
| 科研模式设置 | 跳到设置页 | 更多菜单 | 同上 | — | 低 | **设置页里没有科研专属项** |

## 7. 学习
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 学习模式开关 | 显示或隐藏学习模块 | 工具页 | shell/tools_page.dart | 默认开 | 低 | — |
| 学习空间 | 查看待复习数、课程、错题，进入各学习路径 | 手机：工具页或"更多功能"；电脑：导航栏 | study/study_hub_page.dart | — | 中 | — |
| 继续学习 | 回到今日复习、未学完的课程、最近导师会话 | 学习空间 | 同上 | 有进度时 | 中 | — |
| 学习计划 | 填科目、目标、每日时长、截止日，导入资料，生成计划 | 学习空间 | study/learning_plan_page.dart | 需要模型 | 中 | 资料上限 24000 字 |
| 计划详情 | 查看知识清单、备考计划、每日学习 | 计划卡片 | 同上 | — | 中 | — |
| 每日课程与评估 | 生成当日课程，AI 评估作答并调整计划 | 每日学习 | 同上 | — | 中 | — |
| 导出学习档案 | 导出为 Markdown | 计划详情 | 同上 | — | 低 | — |
| 导师 | 选主题和风格（苏格拉底、费曼或混合）开始学习会话 | 学习空间及多处"请导师讲" | study/tutor_setup_page.dart | — | 高 | **入口很多** |
| 学习会话操作条 | 本轮小结、出 3 题、生成复习卡 | 学习会话顶部 | study/study_session_actions.dart | 学习会话 | 高 | 学习会话里禁用搜索和生图 |
| 课程列表 | 查看、新建、删除课程 | 学习空间 | study/course_list_page.dart | — | 中 | 两个入口指向同一页 |
| 新建课程 | 输入主题和资料，生成课程大纲 | 课程列表 | domain/study/course_tree.dart | 需要模型 | 中 | 扫描件不做 OCR |
| 课程详情 | 树形查看章节，增删改节点 | 课程列表 | study/course_detail_page.dart | — | 中 | 按顺序解锁 |
| 知识点学习 | 看讲解，可换一种讲法，做 3 道检查题 | 课程详情 | study/course_node_player_page.dart | — | 中 | 错题自动进错题本 |
| 过关与掌握度 | 标记掌握度，生成复习卡 | 知识点完成后 | 同上 | — | 中 | — |
| 刷题设置 | 设主题、题量、难度、题型 | 学习空间；"出 3 题" | study/quiz_setup_page.dart | — | 中 | — |
| 刷题作答 | 逐题作答，AI 批改并解析 | 刷题 | study/quiz_player_page.dart | — | 中 | — |
| 生成失败详情 | 查看并复制原始返回 | 失败提示条 | study/study_generation_error.dart | — | 低 | — |
| 错题本 | 筛选、重做、标记已会、请导师讲、转成复习卡 | 学习空间 | study/wrong_book_page.dart | — | 中 | — |
| 卡片库 | 手动管理复习卡 | 学习空间 | study/card_library_page.dart | — | 低 | — |
| 复习（SRS） | 按 Again、Hard、Good、Easy 评分 | 学习空间 | study/review_session_page.dart, domain/study/srs_scheduler.dart | 有到期卡 | 高 | **评分按钮是英文** |

## 8. 创作
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 创作模式开关 | 显示或隐藏创作中心 | 工具页 | shell/tools_page.dart | 默认开 | 低 | — |
| 创作中心"开始"页 | 继续最近作品，开始新作品；分开始、角色、世界书三个标签 | 手机：工具页或"更多功能"；电脑：导航栏 | story/studio_page.dart | — | 中 | — |
| 导演故事 | 一句话描述情节，AI 选角、出大纲，进入第一场 | 创作中心；会话"新建"菜单 | story/director_story_setup_page.dart | 需要模型 | 中 | — |
| 引导问答 | 四步：类型、主线、约束、确认 | 导演故事页 | 同上 | — | 中 | 可以跳过 |
| 更多设置 | 文风（10 种）、约束、节拍数、总字数、严格审稿 | 导演故事页 | domain/story/director_prose_styles.dart | — | 低 | — |
| 方案预览 | 先生成方案，修改后再开始 | 导演故事页 | 同上 | — | 低 | 草稿自动保存 |
| 故事会话操作条 | 推进情节、续写、节拍进退、打开情节面板 | 故事会话顶部 | chat_page `_StorySessionBar` | 故事会话 | 高 | 指令支持 /重写 等前缀 |
| 情节面板 | 编辑大纲、指令、字数、世界书，预览约束 | 手机底部面板；宽屏常驻右侧 | story/story_panel.dart | — | 中 | — |
| 角色大乱斗设置 | 选 2 个以上角色，设场地和指令 | 创作中心；新建菜单 | story/ensemble_setup_page.dart | ≥ 2 张角色卡 | 低 | — |
| 大乱斗操作条 | 下一位发言，或自动 ×6 | 大乱斗会话顶部 | chat_page `_EnsembleSessionBar` | — | 低 | — |
| 角色库 | 浏览角色，开聊、编辑、导出、删除 | 创作中心 › 角色 | story/character_library_page.dart | — | 中 | 独立页面和"选角色开聊"模式**没有入口** |
| 角色卡编辑器 | 用向导或高级字段编辑角色 | + 按钮、卡片"编辑" | 同上 | — | 中 | — |
| 世界书 | 管理设定条目（关键词、优先级、常驻注入） | 创作中心 › 世界书；情节面板 | story/world_info_page.dart | — | 中 | 独立页面**没有入口** |
| AI 辅助创作 | 生成整张角色卡或条目，润色单个字段 | 编辑器内 | story/ai_assist_widgets.dart | 需要 Key | 中 | — |
| 导入导出 | 以 JSON 导入导出，兼容部分 SillyTavern 字段 | 创作中心右上 | story/studio_asset_actions.dart | — | 低 | — |

## 9. 资料库、媒体、记忆

### 9.1 资料库与媒体
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 资料库首页 | 进入项目、素材库、生图记录 | 手机"更多功能"；电脑侧边栏底部；设置 › 数据 | library/resources_page.dart | — | 中 | **三个入口，名字不统一**（资料库 / 资料） |
| 素材库 | 搜索、预览、管理图片和文件 | 资料库 | 同上 | — | 中 | — |
| 素材图片预览 | 查看缩略图和大图 | 素材库、附件选择器 | library/library_image_preview.dart | — | 中 | — |
| 生图版本记录 | 搜索生成过的图，查看系列，最多对比两张 | 资料库 | library/generation_history_page.dart | — | 低 | — |
| 参数与版本对比 | 查看参数差异，复制提示词 | 生图记录 | 同上 | — | 低 | — |
| 按原参数再生成 | 生成新版本，不覆盖旧图 | 参数页 | state/chat/media.dart | 需要生图服务 | 低 | 会弹费用确认 |

### 9.2 记忆
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 长期记忆开关 | 开启后相关记忆会随对话发送 | 设置 › 数据 | settings/widgets/memory_settings_card.dart | — | 低 | 设置首页把"记忆"写在"能力"的副标题里，实际在"数据"下 |
| 记忆管理页 | 管理全局和项目记忆，设置常驻或按需召回 | 设置 › 数据 › 管理记忆 | memory/memory_page.dart | — | 低 | — |
| 记住这条 / 候选整理 | 见 2.5 和 2.7 | — | — | — | — | — |
| 备份导出 | 导出记忆备份 | 记忆页右上 | domain/memory/memory_transfer.dart | — | 低 | — |
| 导入并安全合并 | 逐项审核新增、重复、冲突 | 记忆页右上 | memory/memory_import_review_sheet.dart | — | 低 | — |

## 10. 设置与基础设施

### 10.1 模型接入
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 首次模型设置向导 | 填服务商、地址、Key，测试后开始对话 | 会话页"配置模型" | settings/model_setup_page.dart | 未配置模型时 | 低（首次） | 不在设置页里 |
| 模型与服务 | 以模型为中心选择，拖动调整渠道优先级 | 设置 › 模型 | settings/model_services_panel.dart | — | 中 | 同一模型的渠道之间自动故障转移 |
| 预设服务 | 约 50 个服务商和套餐预设 | 设置 › 模型 | data/provider_profile.dart | — | 低 | 含本地服务和 Coding Plan |
| 服务编辑器 | Base URL、认证方式、5 种协议，扫描或手填模型 | 设置 › 模型 | settings/model_service_editor.dart | — | 低 | — |
| 管理全部服务 | 列出全部服务 | 折叠项 | 同上 | — | 低 | 和服务行菜单重复 |
| ChatGPT / Codex 登录 | 通过 OAuth 用订阅账号 | 订阅与账号 | domain/llm/auth/chatgpt_auth.dart | — | 低 | — |
| 其他订阅说明 | OpenCode、GLM、Kimi 等的接入说明 | 订阅与账号 | model_services_panel.dart | — | 低 | 只是说明，部分未接入 |
| Magpie 伴随服务 | 启停第三方订阅桥接进程 | 订阅与账号 | settings/widgets/magpie_companion_panel.dart | 仅电脑 | 低 | 手机上也显示，但不能用 |
| 路由组与 Auto 策略 | 设置组内顺序、Auto 范围、是否允许跨模型切换 | 设置 › 模型 | settings/widgets/model_route_groups_panel.dart | — | 低 | 高级功能 |
| 渠道健康与路由记录 | 查看实际请求和限流事件 | 设置 › 模型 | settings/widgets/model_route_diagnostics_panel.dart | — | 低 | 只存在内存里 |
| DeepSeek 余额 | 查看余额 | 设置 › 模型 | domain/llm/deepseek_balance_client.dart | 官方 DeepSeek 服务 | 低 | — |
| 用量统计 | 请求数、token 数、缓存命中率 | 设置 › 模型 | settings/widgets/model_settings_widgets.dart | — | 中 | — |
| 上下文管理 | 按模型设置输出上限、窗口大小、历史条数 | 设置 › 模型 | settings/widgets/model_context_settings.dart | — | 低 | — |
| 旧服务商组件 | — | 无入口 | model_settings_widgets.dart（ProfileSelector） | — | — | **死代码** |

### 10.2 回答方式、Agent 与角色
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 工作主代理指令 | 编辑工作模式的系统指令 | 设置 › 模型 | settings/widgets/agent_instructions_editor.dart | 只影响工作模式 | 低 | 放在"模型"分类下，位置不直观 |
| 子代理角色库 | 增删角色，设置何时选用、模型、指令 | 设置 › 模型 | settings/widgets/subagent_roles_editor.dart | 工作模式 | 低 | 默认 6 个角色；**模型池在工作台另配** |
| 角色演进 | 审阅代理提出的候选角色，试用、验收、回退 | 角色库内 | settings/widgets/role_evolution_panel.dart | — | 低 | 实验性 |
| 角色证据自动验收 | 设置验收模型和指令 | 角色演进内 | settings/widgets/role_validation_panel.dart | 默认关 | 低 | 嵌套很深 |
| Jev 技能自动路由 | 用第三方分类器给任务分类 | 设置 › 模型 | settings/widgets/jev_settings_card.dart | 需要 Jev Key | 低 | 会把消息片段发给第三方 |
| 自动聊天技能 | 管理任务类型（名称、前缀、提示词） | 设置 › 模型 | settings/widgets/chat_skills_editor.dart | — | 低 | 默认 6 类 |
| 提示词预设 | 新建、编辑、复制预设 | **无入口** | settings/prompt_presets_page.dart | — | — | **隐藏或未接入**：运行时不读取 |

### 10.3 能力：多媒体、搜索、预算、工具
| 功能 | 用户能做什么 | 入口 | 关键文件 | 前置条件 | 频率 | 备注 |
|---|---|---|---|---|---|---|
| 能力总览 | 查看识图、生图、语音、文件能力的状态 | 设置 › 能力 | settings/widgets/media_capabilities_overview.dart | — | 中 | — |
| 视觉理解服务 | 配置独立的识图服务 | 能力 › 多媒体 | settings/widgets/media_api_settings_card.dart | — | 低 | — |
| 图片生成服务 | 配置生图服务和尺寸 | 能力 › 多媒体 | 同上 | — | 低 | — |
| 云端语音识别 | MiMo ASR 一键预设 | 能力 › 多媒体 | 同上 | — | 低 | — |
| 云端语音合成 | 选音色、克隆音色、写风格指令 | 能力 › 多媒体 | 同上, data/custom_tts_voices.dart | — | 低 | — |
| 从服务导入多媒体配置 | 复用已有的地址和 Key | 多媒体卡片内 | settings/widgets/media_service_picker.dart | — | 低 | — |
| 朗读偏好 | 语速、自动语气、动漫风音色 | 能力 › 语音朗读 | settings_page.dart | — | 低 | — |
| 联网搜索 | 配置 Key、规划模型、轮数、结果数 | 能力 › 联网搜索 | domain/tools/search_*.dart | 需要 DeepSeek 官方 Key | 中 | 代码里有多个搜索后端，但**固定为 DeepSeek**，界面不能切换 |
| 模型响应等待 | 设置首次响应超时 | 能力 | settings/widgets/task_budget_editor.dart | 工作模式 | 低 | — |
| 任务执行预算 | 预设档位，或分别设时间、搜索、工具次数 | 能力 | 同上 | — | 低 | — |
| MCP Server（网关） | 连接自建网关，获取文档等能力 | 能力 | data/gateway_config.dart | 需要自建网关 | 低 | 网关登录（OIDC）**未接入界面** |
| 工具注册表与诊断 | 查看已发现的工具和错误 | 能力 › 自定义 MCP | settings/widgets/tool_registry_panel.dart | — | 低 | 放在 MCP 标题下，位置容易误解 |
| 数学工具 | 配置 SymPy 和 Python 环境 | 工具注册表 | domain/tools/math/* | 默认关 | 低 | — |
| 监督模型 | 设置任务监督的模型、次数、指令 | 能力 › MCP 区域 | settings/widgets/supervisor_settings_panel.dart | 默认关 | 低 | 实验性；**位置不直观** |
| 自定义 MCP（HTTP） | 添加 URL 和 Token，发现工具 | 能力 | settings/widgets/mcp_settings_widgets.dart | — | 低 | — |
| 本地 MCP（stdio） | 配置程序路径和参数 | 添加 MCP 对话框 | domain/mcp/stdio_transport_io.dart | 仅电脑 | 低 | — |
| Playwright 预设 | 一键配置浏览器 MCP | 添加 MCP 对话框 | domain/mcp/playwright_mcp_preset.dart | 需要 Node 18+ | 低 | — |
| Windows 电脑操作 | 配置 cua-driver | 添加 MCP 对话框 | domain/mcp/computer_use_policy.dart | 仅 Windows | 低 | 实验性 |
| 附件与文件解析 | 解析 pdf、docx、xlsx、pptx 等 | 会话附件 | domain/tools/file_parser.dart | — | 高 | 不在设置页 |
| 文档编辑与转换 | 模型修改 Office 文档 | 隐式 | domain/document/* | 需要网关 | 低 | — |
| "可选工具"入口 | 跳到工具页 | 能力页底部 | settings_page.dart | — | 低 | 和导航重复 |

### 10.4 外观
| 功能 | 用户能做什么 | 入口 | 关键文件 | 频率 | 备注 |
|---|---|---|---|---|---|
| 明暗模式 | 跟随系统、浅色、深色 | 设置 › 外观 | settings_page.dart | 中 | — |
| 配色方案 | 14 套，可实时预览 | 外观 | settings/widgets/appearance_settings_widgets.dart | 中 | — |
| 文字大小 | 5 档 | 外观 | settings_page.dart | 中 | — |
| 阅读排版 | 行距、段距、留白、工作回复样式、悬浮框尺寸 | 外观 | settings/widgets/reading_appearance_settings.dart | 低 | — |
| 更多外观 | 圆角、背景、密度、消息样式、Markdown 风格、宽度 | 外观 › 折叠项 | 同上 | 低 | — |

### 10.5 数据、更新、支持
| 功能 | 用户能做什么 | 入口 | 关键文件 | 频率 | 备注 |
|---|---|---|---|---|---|
| 完整备份与恢复 | 导出备份；导入前先预览，再导入为副本 | 设置 › 数据 | settings/backup_page.dart, data/full_backup_service.dart | 低 | 不含密钥；不超过 128MB |
| 导出 / 导入 API 配置 | 迁移服务商、Key 等配置 | 设置 › 数据 | data/settings_bundle.dart | 低 | 文件里含密钥 |
| 清除缓存 | 清理临时文件和图片缓存 | 设置 › 数据 | domain/cache/* | 低 | — |
| 关于与版本 | 查看版本号和补丁号 | 设置首页；数据页 | settings/widgets/about_update_tile.dart | 低 | 两处重复 |
| Shorebird 补丁 | 检查并下载代码补丁 | 关于卡片 | domain/update/shorebird_*.dart | 低 | — |
| 整包更新 | 下载安装，可断点续传 | 关于卡片 | domain/update/app_update.dart | 低 | — |
| 更新下载源 | 管理 GitHub、Gitee、自定义源 | 关于卡片 | settings/update_sources_page.dart | 低 | — |
| 帮助与反馈 | 生成诊断摘要，打开反馈页 | 设置 › 数据 | settings/support_page.dart | 低 | — |
| 启动失败页 | 显示初始化错误和诊断信息 | 自动 | shell/startup_error_app.dart | 低 | — |

## 11. 交叉问题（重新设计时优先处理）

### 11.1 重复入口
1. **新对话**：抽屉、侧边栏、导航栏（侧边栏收起时）、工作模式顶栏，共 3–4 处。
2. **工作台**：顶栏、"文件"按钮、页脚指标、交付文件，共 4 处。
3. **项目 / 执行位置**：模式开关旁 ▾、输入框上方、页脚路径条，共 3 处。
4. **电脑工作区管理**：工具页、侧边栏、执行位置弹层，共 3 处。
5. **资料库**：手机"更多功能"、电脑侧边栏、设置 › 数据，共 3 处，名字还不统一。
6. **工具权限**：盾牌图标和会话策略面板。
7. **MCP 选择**：输入框上方和 + → 高级。
8. **上下文用量**：顶栏圆环和页脚指标。
9. **停止**：发送键和思考面板。
10. **HTML 预览**：代码块和整条消息。
11. **关于与版本**：设置首页和数据页。
12. **"聊天 / 工作"概念**：顶栏切换和侧边栏筛选。

### 11.2 死代码 / 隐藏 / 到不了
1. 提示词预设页：有数据、会备份，但没有入口，运行时也不读取。
2. 托盘的联网搜索开关：参数传下去了，但没有渲染。
3. `ConversationModeFilter`：未被使用。
4. 聊天页内的会话列表：和外壳都用 840 作阈值，很可能永远不显示。
5. `WorkTaskStatusBar`：已定义，未调用。
6. 角色库、世界书的独立页面，以及"选角色开聊"模式：没有入口。
7. `ProfileSelector` / `ProfileEditPage`、网关 OIDC 登录：未接入界面。

### 11.3 位置或概念不一致
- **"项目"有两种含义**：资料项目（资料库下）和工作区项目（电脑目录）。侧边栏里两者混在一起分组。
- **Agent 相关配置分散在三处**：主代理指令和角色库在设置 › 模型；模型池和子代理限制在工作台 › Agents；任务预算和监督模型在设置 › 能力。
- **需要打开工作台才能用的控制**：轮次控制和补充任务只在工作台里，聊天页没有。
- **不在设置页的设置**：模型单价在页脚；首次模型向导在会话页。
- **只能用在远程任务上的自动化**：定时、Webhook 等触发器只服务远程任务，本机会话用不了。
- **其他**：
  - 复习评分按钮是英文。
  - 联网搜索后端被固定为 DeepSeek，界面不能切换。
  - 科研的"设置"入口跳到通用设置，那里没有科研专属项。

## 12. 按频率归类（供下一步排布入口）

- **高（主界面必须一眼可见）**：
  - 输入框：发送、模型选择、+ 托盘、附件
  - 消息：复制、Markdown 渲染、思考或执行记录
  - 会话：聊天 / 工作切换、新对话、会话列表
  - 工作模式：工作台文件、任务、交付文件
  - 学习与创作：导师会话、学习会话操作条、故事会话操作条、复习
- **中（一次点击可达）**：
  - 会话里的操作：思考强度、工具权限、编辑和重新生成、分支、大纲、搜索会话、项目分组、执行位置
  - 工作台：改动、Git、终端、Agents、Services、日志
  - 学习与创作：学习空间、课程、刷题、错题本、创作中心、角色库、世界书
  - 其他：资料库、用量统计、外观
- **低（放进设置、更多菜单或高级区）**：
  - 远程任务和 Android 控制、科研终端
  - 路由组和诊断、角色演进和验收、Jev、监督模型
  - MCP 细节、数学工具、备份、更新、诊断
  - 导出、归档和批量操作、思考翻译、HTML 预览
