# 工作区与可靠性改造（2026-10-16）

本次修改在现有工作区上增量完成，保留主题、颜色偏好和已有数据格式；没有发布远程版本或创建 Gitee 仓库。

| 功能 | 行为与入口 |
| --- | --- |
| 整包更新 | 暂停、断网后保留 `.part` 与版本/HTTP 校验信息；重新下载时发送 Range/If-Range。服务器返回完整文件时重新写入，错误范围拒绝追加。SHA-256 与 APK/ZIP 格式检查通过后才生成可安装文件。 |
| 下载源 | 设置首页 → 关于 → 更新下载源。支持 HTTPS 模板、首选源、自动备用源切换。Gitee 仓库模板可推导 Release API，GitHub 元数据查询失败时尝试它。没有可信哈希时，跨源下载从头开始。 |
| 导航与设置 | 手机取消底部导航，侧边栏集中提供资料库、提示词、会话、工具与已启用的学习/创作/科研入口。底部保留新对话和设置入口；设置首页改为分组卡片，二级设置支持返回。 |
| 提示词 | 侧边栏或设置中的“提示词预设”支持新建、编辑、复制、删除、选用。聊天顶栏可快速切换；新预设影响之后的请求，进行中的流使用发送时的设置快照。自动技能路由仍可选。 |
| 学习 | 学习空间 → 备考与每日学习。输入目标、日期、每天时间、零基础/复习模式，可导入 PDF/DOCX/TXT/Markdown 材料。生成带来源与验收标准的知识清单和独立计划；手动开始每日课程，提交实际答案后保存反馈，后续课程优先复习薄弱项。支持历史记录和 Markdown 学习档案导出。 |
| 科研 | 现有 SSH/tmux 终端接入 SFTP：目录浏览、筛选、新建文件夹、文本读取/编辑、上传下载及传输列表。宽屏可在文件面板与科研助手之间切换，也可专注终端；手机通过文件抽屉操作。终端可显式进入文件面板目录。 |
| 后台 | 页面可见性只调整呈现与保存节奏，不重建或取消模型流。Android 继续使用已有前台服务；Windows 新增托盘，关闭窗口隐藏，托盘可恢复/退出。生成时请求系统保持运行，不强制点亮屏幕。 |
| 思考与输入 | 思考提供五行自动跟随预览，可展开独立滚动的完整过程；用户上翻时停止抢滚动。工具步骤沿时间线显示。输入区上方输入文字，下方排列思考、搜索、附件、语音和发送；手机语音对话也可从“+”进入。 |
| 图标 | 原创猫耳助手，沿用既有青绿、暖白与金色品牌色；SVG 为源文件，各平台图标与应用内头像统一生成。 |

## 保存与兼容

- 预设存储为 `promptPresetsV1`，包含独立 ID、名称、提示词、ownerId、updatedAt 与选中 ID。旧的自定义提示词保留为“原有提示词”。这是账号同步的数据准备，目前没有新增登录或云同步服务。
- 学习档案存储为 `learningPlansV1`，保存材料、知识清单、计划、每日课程、实际答案与评估记录。生成课程不写入掌握证据；后续反馈按提交时间解释。损坏数据保留，阻止直接覆盖。
- 以上两项纳入完整备份的偏好选项；提示词同时纳入 API 设置导入导出。恢复完整备份后刷新相应控制器。
- 更新源保存在 `updateSourcesV1`，首选源保存在 `updatePreferredSourceV1`。未填入实际发布地址时只使用原有 GitHub 发布源。
- 文件传输任务独立于文件面板生命周期，最多同时三个任务。切换 SSH 连接会取消旧连接传输；不会把旧目录返回值或未保存编辑写到新主机。
- 远程编辑限 1 MB UTF-8 文本，保存前复查原内容，使用临时文件与 rename 写回。已有远程文件的上传默认拒绝覆盖。

## 验证方式

```powershell
flutter analyze --no-pub lib test
flutter test --no-pub --reporter expanded
flutter test --no-pub --dart-define=RENDER_WORKSPACE=true test/workspace_visual_test.dart
flutter test --no-pub --dart-define=RENDER_MOBILE=true test/chat_responsive_layout_test.dart
flutter build windows --debug --no-pub
flutter build apk --debug --no-pub
node scripts/render_branding.cjs
```

测试覆盖下载中断续传、200/206/416、跨源校验、错误文件拒绝安装、预设与流上下文隔离、学习档案重载、真实作答反馈、传输取消、过期目录请求、侧边栏导航、系统返回与窄屏布局。渲染图片使用合成测试数据，位于 `output/workspace-*.png`。

本机验证结果：

| 检查 | 结果 |
| --- | --- |
| Flutter 静态检查（lib、test） | No issues found |
| 全量 Flutter 测试 | 1400 项通过 |
| 追加 Gitee 元数据故障切换测试 | 1 项通过 |
| Windows Debug 构建 | 成功，`build/windows/x64/runner/Debug/expert_chat.exe`（运行时需保留同目录 DLL 与 data） |
| Android Debug 构建 | 成功，`build/app/outputs/flutter-apk/app-debug.apk` |

上述为本地调试构建；未执行远程发布或安装到用户设备。

构建与模拟测试不能代替实际 SSH/SFTP 服务器、Android 厂商电池策略和安装覆盖升级的验收。系统强制停止进程、网络物理断开或系统后台时限到期仍可能终止本地流；应用内导航不会主动中止它。当前科研改造保留单 SSH 连接与多个 tmux 会话，未实现 FileTerm 的全部协议或并行多主机功能。

## 参考与素材

- [Good Learning](https://github.com/yoli-mi/good-learning-skill)：参考知识清单与计划分离、逐日课程、真实作答驱动复习的工作流。本应用使用原生 Dart 数据与界面实现，未直接打包其脚本。
- [FileTerm](https://github.com/St0ff3l/fileterm)：参考终端、文件面板与传输中心共同组成工作区的布局和职责划分，SSH/SFTP 使用现有 dartssh2 连接实现。
- [Gitee Release API](https://gitee.com/sdk/gitee5j/blob/main/docs/RepositoriesApi.md)：Gitee 发布信息查询入口。
- 图标源文件：`design/branding/expert-chat-mark.svg`。通过 `scripts/render_branding.cjs` 和仓库已有 sharp 依赖生成位图及 ICO，不依赖外部生成服务。
