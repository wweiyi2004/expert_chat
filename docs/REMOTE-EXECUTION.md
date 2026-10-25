# 独立执行端、远程任务与 Android 本机控制

## 独立执行端

`tool/remote_host.dart` 是不依赖 Flutter 界面生命周期的 Dart 程序，已实际通过 `dart compile exe`。关闭手机页面、断开连接不会结束电脑任务。宿主进程本身退出后不保证命令继续；重启将派发中任务标为 `unknown`，禁止重放。人需要检查实际文件、进程与外部系统，再在手机登记核验结果，或者提交新目标。

独立宿主任务与现有 Flutter 本机工作会话分别持有执行记录；没有把正在运行的旧会话迁移到宿主，也没有声称退出旧 Flutter 后旧会话自动续跑。该最小宿主以启动时固定目录作为文件 API 范围，不继承 Rust 工作区的额外目录/只读/拒绝规则，也不自动导入原工作区的批准模式。需要保留这些目录规则的项目继续使用原电脑工作区入口，不把同名项目视为已迁移授权。独立宿主默认请求批准，较高权限必须由电脑所有者预先允许，再由用户为任务明确选择。

```powershell
dart compile exe tool/remote_host.dart -o output/remote-host.exe
$env:EXPERT_REMOTE_MODEL_URL = 'https://your-provider.example/v1'
$env:EXPERT_REMOTE_MODEL = 'your-model'
$env:EXPERT_REMOTE_MODEL_KEY = '<在本机安全设置中提供，不要写进项目文件>'
$env:EXPERT_REMOTE_MODEL_FORMAT = 'openAiCompatible'
.\output\remote-host.exe "$env:LOCALAPPDATA\ExpertChatRemote\computer-a" 'D:\your-project' 47831
```

四个固定协议分别使用 `openAiCompatible`、`openAiResponses`、`anthropicMessages`、`geminiNative`。执行端直接复用现有协议适配器，保存原生工具续接项目。支持 `EXPERT_REMOTE_MAX_ROUNDS`（默认 20，受电脑轮次上限约束）及 `EXPERT_REMOTE_COMMAND_TIMEOUT`（1–3600 秒，默认 600）。未配置模型时仍可执行明确提交并批准的命令任务，但不会伪造 Agent 结果。请求模式的初次模型请求需要批准；较高模式由用户提交时明确选择，自动化需显式开启自动启动模型。命令派发遵守下面的任务权限快照。

默认只监听 `127.0.0.1`。配对密钥保存在私有数据目录的 `credential` 文件，30 天过期，不在控制台打印。手机“工具 → 远程电脑任务”填写地址和密钥，成功连接后加密保存在本机安全存储，可保存并选择多台电脑。配对不转移模型密钥、整个资料库或授权其他工作目录。`--rotate-pairing` 在启动时轮换密钥；认证后的 `POST /v1/pairing/revoke` 立即撤销旧密钥，但不停止已有任务。

空白、过短或格式损坏的密钥文件会阻止启动，不把损坏内容当成弱口令；电脑所有者可保留副本后显式用 `--rotate-pairing` 换钥，任务日志保持原样。错误验证按来源地址限速，合法密钥不会因为同地址的错误尝试而失去停止入口。

远程连接必须使用以下方式之一：

- HTTPS：在电脑通过 `EXPERT_REMOTE_TLS_CERT`、`EXPERT_REMOTE_TLS_KEY` 提供证书链与私钥，使用与证书匹配、手机系统信任的主机名。客户端正常验证证书，不接受任意自签证书。需要监听网络时在端口后填写绑定 IP，追加 `--allow-network`。
- 用户自己的加密 VPN / SSH 隧道：电脑显式追加 `--protected-tunnel`，手机勾选已建立受保护连接。普通 Wi-Fi/LAN 不等于加密隧道。没有 TLS 或显式受保护隧道时，宿主拒绝网络监听，手机也拒绝向普通 HTTP 网络地址发送密钥。

例如 TLS 网络监听：`remote-host.exe PRIVATE_DIR WORKSPACE 47831 192.168.1.20 --allow-network`。私有数据目录必须与项目目录分离，并与该项目的规范路径绑定，不能改用同一任务日志控制另一项目。证书也应保存在项目之外。命令以宿主账号权限执行，工作目录不是系统沙箱；用户应按所选模式审阅授权范围。可为不同项目独立启动宿主、使用不同数据目录与端口。脚本/服务管理器可以运行该 EXE，不需要打开 Flutter；本次未自动登记开机任务或修改用户系统服务。

## 任务协议与恢复

所有 `/v1/` 路由需要 `Authorization: Bearer …`。主要接口：

| 路径 | 行为 |
| --- | --- |
| `GET /v1/tasks` | 固定工作目录的真实任务状态与结果，不返回模型内部请求历史 |
| `POST /v1/tasks` | `{id, goal, policy, roundLimit}` 提交模型任务，或 `{id, command}` 提交明确命令；同 ID 的目标、种类、初始权限/轮次配置必须一致 |
| `GET /v1/events?after=N` | 从严格递增 cursor 续传日志；超过保留窗口时返回 `historyTruncated` |
| `POST /v1/tasks/ID/approve` | `{version}` 必须匹配已持久化的递增步骤版本，拒绝旧页面批准新命令（不依赖时钟精度） |
| `POST /v1/tasks/ID/stop` | 停止模型连接或命令树；只有执行进程确认退出后才报告命令已停止 |
| `POST /v1/tasks/ID/budget` | `{version, additionalRounds}` 在等待轮次状态为同一任务追加并继续，不重放工具，也不重启已完成任务 |
| `POST /v1/tasks/ID/resolve` | 对 `unknown` 结果提交版本、核验说明和终态；不会执行或重放命令 |
| `GET /v1/artifact?download=1&path=RELATIVE_PATH` | 流式下载固定工作目录内文件，拒绝路径穿越及符号链接逃逸 |
| `GET /v1/files?path=RELATIVE_DIRECTORY` | 有界文件树，符号链接不在界面展开 |
| `GET /v1/git?view=status/log/branches/worktrees/diff` | 固定目录的真实 Git 状态、提交父关系文本图、分支、worktree 与未暂存差异；不接受任意 shell 参数 |
| `GET /v1/automation` / `POST /v1/automation` | 管理触发器和项目环境引用 |
| `POST /v1/webhooks/ID` | `{eventId}` 触发已登记规则，需要同样认证，不提供匿名 webhook |
| `GET /v1/tools` / `POST /v1/tools/math` | 发现并调用宿主的可信数学工作进程 |

派发前先持久写事件。写入失败不启动命令；同一步重复批准不会重复派发。不同 Agent 模型任务可并行运行。同一固定工作目录的已批准命令排队执行，避免同时写同一目录；队列重启后重新要求批准。其他项目宿主不受此队列限制。

JSONL 日志达到 8 MiB 后写版本化状态检查点并保留最近 1000 个事件，cursor 不重置；单次命令输出上限约 256 KiB，模型响应 256 KiB，工具参数 64 KiB，任务请求历史 512 KiB。最近 100 个终态保留详细历史，旧终态精简详细正文并保留提交身份。活动/未知任务不因历史限制删除。数据目录含命令、输出和任务历史，按本机私有资料保护。

日志或检查点损坏时保留原始字节并拒绝启动，不静默删除末尾事件、清空任务身份或重发操作。先复制私有目录并核验实际副作用，再恢复已检查的备份。根进程退出后若继承的输出管道仍不关闭，任务标为未知并要求检查子进程，不用过期 PID 杀进程；该工作目录的新命令等待未知副作用核验，独立 Agent 的模型请求不受全局数量限制。

工具子进程不继承宿主的 `EXPERT_REMOTE_*` 环境，包含已知宿主模型密钥/配对密钥值的环境别名也移除。已知密钥从命令输出、错误、事件和模型工具观察中脱敏，输出流在块边界保留有限尾部，避免密钥分两次输出时泄漏；直接把宿主密钥写进目标或自动化配置会拒绝提交。项目自己的环境引用与账号权限仍需要用户审阅。

模型可使用 `deliver_files` 明确登记最终文件，保存文件大小、修改时间与 SHA256。手机以流方式下载到应用文档目录并复核 SHA256，文件版本改变则拒绝交付旧版本；可从下载提示打开系统导出面板。二进制和大于 8 MiB 文件不全量载入请求 JSON。原有小文件 JSON 读取接口仍有 8 MiB 上限。

数学后端使用随程序提供的可信 `assets/math/toolkit.py`。独立 EXE 部署时把脚本放到旁边的 `assets/math/toolkit.py`，或通过本机 `EXPERT_REMOTE_MATH_SCRIPT` 显式指定；解释器通过 `EXPERT_REMOTE_MATH_PYTHON` 指定。不从工作目录发现脚本，不执行模型提供的 Python 源码。手机可把所选电脑作为数学工具后端；每轮绑定同一配对快照，不在执行过程中切换电脑。手机取消请求会停止等待；远端纯计算工作进程可继续到其 15 秒上限，不宣称跨设备取消已经终止远端进程。

## 命令权限与轮次续接

电脑通过 `EXPERT_REMOTE_ALLOWED_POLICIES=request,assisted,full` 明确允许可选模式；省略时只有请求批准。手机只展示电脑允许的模式。权限保存在每任务的初始快照中，不能由模型工具参数升级，也不能用同一提交 ID 更改。

- `request`：每个命令等待人工批准，适合默认使用。
- `assisted`：用电脑配置的审查模型检查目标、固定目录和准确命令；审查请求没有工具，最多 30 秒/512 输出 token，必须返回严格的 `verdict/reason` JSON。拒绝、不确定、格式错误、超时、工具请求和迟到结果都不会自动授权，仍等待人工决定。
- `full`：用户明确选择、且电脑所有者已允许时，记录派发边界后自动运行命令。它使用电脑账号权限，工作目录不是沙箱，不代表可以忽略项目限制或未知副作用。

审查默认跟随电脑模型，也可通过 `EXPERT_REMOTE_REVIEW_URL/MODEL/KEY/FORMAT` 指定；这些额外请求可能消耗该账号额度。记录模式、公开结论、命令哈希和被审查版本，不记录鉴权头。停止可取消审查连接，旧版本审查不能批准新命令。

每任务有模型轮次上限，达到后进入“等待追加轮次”，保留原始请求历史和已完成工具结果。手机可以为同一任务追加 +N 轮或停止；追加必须匹配当前版本，不能隐式重新启动已完成/失败/未知任务。`EXPERT_REMOTE_ROUND_CEILING` 默认 200（可配 1–1000）是电脑硬上限。

任务首次派发时绑定模型、固定协议和账户身份；配置改变后，旧任务不会自动向新配置转发历史或执行待处理命令。恢复原配置后才可继续，或者核验旧副作用后新建目标。轮次审查后的取消检查也会阻止迟到请求重新启动模型。

可选自动续轮默认关闭。电脑设置 `EXPERT_REMOTE_AUTO_BUDGET=true` 后，用户仍需为任务/规则显式勾选；达到轮次边界由无工具审查提出建议，代码限制每次追加量、总上限和审查次数。`EXPERT_REMOTE_BUDGET_EXTRA_ROUNDS` 默认 5，`EXPERT_REMOTE_BUDGET_REVIEWS` 默认 2（最多 5）。未知/未批准仍转人工，不让模型自行提高上限。

待核对提交的目标、设备、权限和初始预算先保存到手机安全存储，再发送请求。页面重建和重连沿用原提交标识/快照，不把后来改动的控件值当作对旧提交的修改。周期查询不会禁用停止；停止可优先取消慢查询，旧状态不能覆盖已确认的停止。

## 自动化与环境

手机远程任务页可添加、编辑、暂停并查看定时、文件、仓库和 webhook 规则，任务保留触发原因和 eventId。文件变化经过两次稳定观察后触发，仓库监视 HEAD，计划间隔至少 30 秒。webhook 依赖发送方提供稳定 eventId；提交身份来自规则与事件哈希，即使超过近期去重窗口，历史身份仍阻止重复执行。暂停不自动停止已经提交的任务。默认只排队；勾选自动启动模型后使用电脑已配置模型，命令按该规则显式保存的权限模式处理。选择电脑允许的完全访问后，规则可无人值守完成命令链；重启的未知操作仍不自动重放。

可保存项目依赖说明和启动命令，复用时排队为需要批准的明确命令。它们是可审阅的环境引用，不是容器镜像、进程沙箱或自动迁移整个开发环境。

## Android 本机控制

“工具 → Android 本机控制”引导用户在系统设置中启用无障碍服务；应用不自动启用真实设备权限。启用后还需显式开启本次控制，并允许通知以提供跨 App 的立即停止入口。通知正文和“立即停止”按钮都能停止新动作；系统设置可撤销服务。模型不能自行授权、开启或重启控制。

`device_observe` 返回活动应用、观察 revision、可见节点的 target/bounds/文字。`device_action` 支持节点点击、文本输入、滚动、返回、主屏幕、打开应用、坐标点击与截图，要求最新 revision，并绑定本轮会话租约。其他会话不能读取/操作租约中的界面；转交需用户停止后重新开启。动作串行执行、结果回读新观察，不把 Android 接受动作当作任务成功。密码节点文字和描述隐藏，密码字段不接受输入，失效/不可见节点拒绝操作。

Android 11+ 截图使用用户启用的无障碍服务 `takeScreenshot` 能力（[Android 官方 API](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)）；不绕过系统授权，不截取受保护画面。截图遵守同一会话租约和 revision，停止或窗口变化后丢弃旧回调。Android 低版本/安全窗口/撤销权限返回真实错误。该技术验证不代表商店发行政策已经通过。

截图最长边限制为 2048 像素、编码结果限制为 8 MiB。任务结束由控制器调用匹配 owner 的租约释放，不影响另一会话；下一个任务可在用户仍开启控制时重新取得观察租约。用户停止/系统中断/权限撤销则关闭控制，后续任务不能自行恢复。

截图随附原始完整屏幕尺寸、实际图像尺寸、每图像像素对应的物理坐标比例、显示 ID、旋转和观察 revision。`tapPoint` 接受物理屏幕坐标，不能直接套用缩略图坐标；优先使用节点 target。原生集成已将元数据与实际 PNG 头和完整屏幕大小逐项对比。

## 可复现验证

- `dart test test/remote_host_test.dart test/remote_model_protocol_test.dart test/remote_host_secrets_test.dart test/remote_host_policy_test.dart test/remote_workspace_test.dart`：真实本地进程、假模型 HTTP、四协议工具续接、重复批准、竞争队列、停止/迟到、重启未知边界、认证、密钥过期/撤销、webhook 去重、写盘失败、9 MiB 流式下载与路径穿越、分块密钥脱敏、损坏末尾拒绝、三模式、同任务续轮与固定时钟下的递增批准版本。
- `dart compile exe tool/remote_host.dart -o output/remote-host.exe`：确认无 `dart:ui` 依赖。
- `python tool/verify_remote_host_transport.py`：临时证书与工作区，验证实际 TLS、证书不信任拒绝、认证、断连完整 300 秒、同任务恢复和副作用只发生一次。需要开发环境 `cryptography`，不使用真实模型。
- `python tool/build_android_agent_fixtures.py`：构建两个独立自有演示 App，使用临时签名材料。
- `python tool/verify_android_agent.py`：仅允许名为 `ExpertChat_Verification_35` 的 `emulator-5580`；安装集成测试、授权该一次性模拟器、执行两应用任务、点击真实通知停止入口、校验撤销与截图证据。不会修改真实手机。

2026-10-24 已完成独立 EXE、四协议和 300 秒真实断连验证；Debug APK 已编译。原生集成验证结果与截图证据以实际最新执行结果为准，不以编译或代码存在替代真机验收。当前没有已连接的真实 Android 手机；真实厂商系统、电池策略与发行渠道仍需另行验证。

最终原生模拟器集成已通过两个自有 App 的“输入→保存→回读”、跨 App 切换、滚动、截图、失效观察拒绝、外部会话拒绝、匹配 owner 释放/下一任务接管，以及通知栏实际点击停止后动作拒绝和系统服务撤销。证据位于 `output/device-agent-evidence/`：前后 PNG、通知 PNG、实际点击 bounds 与 NMS 元数据。测试最初使用 `uiautomator dump` 获取通知树，会因为 Android UiAutomation 默认抑制其他无障碍服务而干扰被测服务；最终改用本服务的授权观察获取通知 bounds，由独立 `adb input tap` 点击，未关闭任何产品保护检查。

集成测试生成的 `app-debug.apk` 包含测试入口，不能当成最终产品 APK 交付；产品构建须明确使用 `flutter build apk --debug --target lib/main.dart` 或正式签名 Release 流程。
