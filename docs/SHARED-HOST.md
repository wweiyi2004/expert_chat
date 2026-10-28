# GUI / TUI 共同宿主

实施状态：代码改造及 Windows x64 自动化验收已完成。实机输入法/鼠标目测因 computer-use 管道不可用未完成；详细结果见主规划第 23.11 节及交付包 VALIDATION.md。

## 进程与共同资料

Windows GUI 与 Rust TUI 连接独立 Dart Host。Host 持有既有 ChatController 的任务循环、预算、工具、批准、子代理、验收及恢复逻辑；GUI 的控制器负责状态投影和明确命令。关闭客户端不会关闭主任务。没有客户端、活动任务、SSH 连接或已绑定监控时，默认空闲 600 秒退出；`--idle-seconds 0` 禁用空闲退出。

本轮保留**纯 Dart Riverpod** 作为内部服务容器，复用原控制器和 mixin，以免新旧循环分叉。Host 不加载 Flutter 引擎、Widget 或 Flutter Riverpod。此决定调整了原计划“核心不依赖 Provider”的目标：TaskCore、计划记录和执行策略仍是独立模型，运行时服务容器暂不重写。

共同数据库仍为 Documents 下的 `expert_chat.sqlite`，schema 17。偏好和 DPAPI 凭据仍使用应用支持目录原格式。GUI 的资料库、学习与创作业务通过 Host 的 Drift 连接读写；没有第二个 SQLite 文件连接者。每个 GUI 数据连接拥有自己的事务代理，连接中断会回滚其未完成事务；新连接不重放原 SQL 写入。表更新通知在各客户端之间传递。

`owner.lock` 保护资料目录。生产 Host 同时持有旧版 GUI 的 v1 单实例互斥量；新版 GUI 使用 v2 界面互斥量。新 Host 不强行接管旧版运行中的资料。首次迁移前保存数据库、WAL、偏好、旧 JSON 会话和加密凭据的副本；旧 AES / Credential Manager 数据导入 DPAPI 后保留原始来源，以迁移标记防止已删除的旧密钥复活。

`EXPERT_HOST_DATA_DIR` 和 `EXPERT_HOST_DISCOVERY` 用于独立测试资料目录；测试目录不导入生产凭据。任务工具权限继续由原工作区授权和批准策略管理，工作目录不是操作系统沙箱。

数据库 schema 仍为 17 不代表旧 GUI 能理解新增检查点停止标记。回退旧程序时，先导出新资料并退出新版的 GUI、TUI 与 Host，再从迁移前副本恢复数据库及其配套 WAL、偏好与凭据；不能直接让旧版本继续解释新版检查点位置。迁移后的新资料须另外保留，不能用恢复旧副本代替它们的备份。

## 平台能力归属

| 能力 | 执行位置与兼容方式 |
| --- | --- |
| 对话、工作模式、模型循环、上下文、批准、预算、子代理、验收 | Host 复用原逻辑；两端共享任务身份 |
| SQLite、偏好、凭据、会话恢复、任务日志 | Host 单一持有；GUI 使用代理；未知写入结果不自动重发 |
| SSH、SFTP、科研终端、tmux、远程工作区 | Host 保持 SSH；GUI 投影状态和有界终端输出；操作绑定连接 generation |
| GUI 交互终端标签、手动文件传输 | Host 执行，归属发起客户端；该客户端断开时取消标签/传输，不断开共同 SSH 与 Agent 任务 |
| OAuth 浏览器交互、主机指纹确认 | Host 发起带客户端作用域的 GUI 动作，明确回执；断连不默认为批准 |
| PDF 文本、图像缩放 | 独立媒体 worker；输入 15 MiB、内存 512 MiB、15 秒看门狗，异常不记录文档正文 |
| DOCX / XLSX / PPTX 文本解析 | 既有纯 Dart 解析器，保留原文件与解压边界 |
| 语音、剪贴板、WebView、系统分享、界面通知 | GUI 平台适配；不阻止 TUI 的普通任务启动 |
| 学习/创作界面及其辅助生成 | 保留 GUI 工作流，共同存储、模型由 Host 代理；客户端辅助模型流随客户端断开取消 |
| Android Device Agent | 手机进程内的 EmbeddedRuntime 复用同一 ChatController/工具核心；Flutter 页面借用执行容器，Kotlin 提供设备通道；Windows Host 不伪装移动设备能力 |
| 既有 `tool/remote_host.dart` | 保留独立部署与授权语义；不会自动迁移活动远程任务 |

## Android 执行边界

Android 使用 `EmbeddedRuntime` 创建存储和唯一的执行容器，页面通过 `EmbeddedRuntimeScope` 访问该容器。切换页面或重建界面不会重新创建模型循环；暂停/隐藏时通知核心保存流式检查点，继续使用原请求。应用视图从引擎分离或根执行作用域关闭时，先结束本机任务、取消等待的计划并刷写记录，再释放容器和数据库。系统直接杀死进程仍依赖已保存的检查点恢复，不承诺无限后台运行。

这仍是手机进程内的宿主，不是 Windows 可执行文件移植，也没有新增第二个 Android 后台执行进程。通知/前台保活、无障碍观察与操作、截图、分享和系统选择器由原生适配提供。设备控制必须由用户在手机开启，模型只能使用当前已开放的工具；停止或撤权后不再派发新操作。

本机手机任务不显示 Windows 文件服务和本机终端入口；连接 SSH 后使用其远程文件/命令能力。独立远程电脑任务仍通过原有远程工作台使用，不将其远程生命周期混同于本机任务。

## 请求与恢复

公共 TUI 仅持有桥接 token；GUI 另持独立 token。原始偏好、凭据、SQL 与内部 RPC 需要 GUI 能力。公共快照继续脱敏。

Host 在副作用开始前刷入操作回执日志，只存带盐摘要、时间和状态，不存原始参数或返回值。当前进程可复用同一请求结果；重启或结果缓存淘汰后，旧请求返回 `unknown_result`，阻止自动重复执行。回执不是数据库、文件系统与外部命令之间的分布式事务；崩溃窗口仍需核对真实结果。

GUI 状态使用已确认游标的会话增量以及运行状态分段版本。重连重建基线；配置仅在版本变化时发送。TUI 无变化时降低快照频率，仍定期校准外部状态。断线提示与执行状态、任务验收分别显示。

Host 汇总各客户端正在查看的会话，可见会话的正文与思考一起按最多 80 ms 的合并等待发布；未被任何客户端查看的任务继续按后台节奏保存。界面选择不改变任务身份，也不会让另一客户端正在看的会话被错误地当成后台。

备份在 Host 内执行，复核用户预览的文件摘要。维护期间拒绝新任务与 GUI SQL 操作，并等待已开始的客户端事务结束。导入采用原有新增副本/恢复日志机制；计划批准、执行目标和验收授权不随备份恢复。

## 计划、任务与检查点

计划模式允许只读调研，`work_set_plan` 提交版本化方案；也兼容模型直接输出方案正文。审批暂停保留同一任务身份和累计预算。用户评论或修改方案产生新版本，旧批准失效；批准不扩张工作区或工具权限。普通工作任务的计划只作进度记录，不额外强制审批。步骤报告完成与实际工具证据、最终验收分别呈现。

GUI 使用计划面板与任务总览；TUI 使用 `/plan`、`/tasks`。`/plan approve 版本` 必须先查看该版本；`/plan comment 版本 意见` 提交评论。

每条用户消息之前是一个会话检查点。`/rewind` 或 GUI 检查点入口先展示范围，再选择：

- `conversation`：只回退会话位置，保留历史消息和分支。
- `files`：只回退有记录的文本文件，逐项核验当前 SHA 与原目标。
- `both`：回退文件后恢复会话；文件冲突时保留会话位置并报告未完成项。
- `branch`：从该位置建立新会话分支，原会话和文件保持原状态。

命令、二进制文件、外部服务与设备副作用不属于可保证撤销的文本快照。文件回退可能部分完成，结果明确列出已完成和未完成项；不会宣称全系统已还原。

TUI `/find`、`/next`、`/prev`、`/jump user|failure` 与 `/latest` 支持阅读定位。上翻使用消息锚点。`Alt+E` 编辑现有草稿，`/editor` 打开外部编辑器；`VISUAL` / `EDITOR` 被解析为程序和字面参数，不通过 shell 展开。GUI 编辑器应设置等待参数，如 `code --wait`；编辑结果只回到草稿。

## 构建与待验收

`bin/expert_host.dart` 是 CLI bundle 入口；`tool/build_desktop_host.ps1` 使用 `dart build cli` 保留 `host/bin` 与 `host/lib` 的原生库相对位置。Windows CMake 同时包含 GUI、TUI、Rust 文件服务、Host 和媒体 worker。完整发行包需保留：

```text
expert_chat.exe
expert-tui.exe
expert-desktop.exe
host/bin/expert-host.exe
host/lib/…
expert-media-worker/expert-media-worker.exe
expert-media-worker/_internal/…
data/flutter_assets/…
```

Dart CLI bundle 会包含构建 hook 产生的代码资源，参见 [Dart 构建文档](https://dart.dev/tools/dart-build)。不能只复制 Host EXE。

本轮按用户要求，先集中完成代码，再统一执行静态检查、Rust/Flutter 回归、真实独立进程与双客户端测试。`tool/host_e2e.py` 只使用临时资料和回环假模型；付费模型请求为零。最终通过情况与未覆盖范围须以主规划后续验收记录为准。
