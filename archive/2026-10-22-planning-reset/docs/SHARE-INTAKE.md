# 分享接收（Android）

从浏览器、相册、文件管理器等 App 选择"分享 → Expert Chat"后，应用打开一个新对话，把分享的文字填入输入框，图片和文件加为附件。**不会自动发送**，确认后由用户点发送。

## 支持的内容

| 分享内容 | 处理方式 |
| --- | --- |
| 文字、链接（`EXTRA_TEXT`，含标题 `EXTRA_SUBJECT`） | 填入输入框；标题不在正文里时放在第一行 |
| 图片 `image/*` | 当前模型能看图时加为附件，否则跳过并提示 |
| PDF、DOCX、XLSX、PPTX、TXT、MD、CSV、JSON | 按普通附件解析，与"上传文件"一致 |

- 一次最多 8 个文件，每个不超过 10 MB，和手动添加附件的上限相同。超出的在复制前跳过，并提示跳过了几个及原因。
- 不同类型的文件混合分享时（例如图片加 PDF），部分 App 会把类型标为 `*/*`，这时系统分享列表里可能不出现 Expert Chat，改为分类型分享即可。
- 仅 Android。iOS 需要单独的 Share Extension，目前没有实现。

## 流程

1. `SharedIntake.kt` 在 `onCreate`（冷启动）或 `onNewIntent`（应用已打开）收到分享。它在后台线程把每个 `content://` 流复制到 `cacheDir/shared_intake/`，取原文件名；没有扩展名时按 MIME 类型补上。每次新的分享会先清空这个目录。
2. 原生端只保存一份待处理内容，并发送 `shareAvailable` 信号。Dart 端 `SharedIntake.take()` 通过 `expert_chat/share` 通道调用 `takeShare` 取走并清空。冷启动时 Dart 在第一帧后主动取一次，所以 Dart 还没准备好时到达的分享不会丢失。复制还没完成时，`takeShare` 会等复制结束再返回。
3. `AppShell._openShared` 等会话数据加载完，新建对话并切到聊天页，再写入 `pendingSharedPayloadProvider`。
4. `ChatPage` 在下一帧才填充。切换对话的监听会清空输入框和附件，太早填会被一起清掉。填充完成后清空 provider，同一个分享只处理一次。
5. 文件通过 `FileIngestSource(path:)` 进入 `_ingestFileSources`，和剪贴板粘贴走同一条路径，大小、数量、解析、存入素材库的规则都一致。

从最近任务里重新打开时（`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`），以及 Activity 重建时，不会重复导入同一个分享。

## 验证

- `test/shared_intake_test.dart` 覆盖以下情况：
  - 解析分享数据，跳过不合法的文件项；
  - 冷启动分享和收到信号后主动取走；
  - 非 Android 平台上不执行任何操作；
  - 填入新对话、不自动发送、不保留旧草稿；
  - 从缓存路径添加文档附件；
  - 模型不能看图时跳过图片，并提示原生端跳过的文件。
- 真机验收：
  - 浏览器分享链接；
  - 相册分享单张和多张图片；
  - 文件管理器分享 PDF/DOCX；
  - 分享一个超过 10 MB 的文件；
  - 应用未启动和已在后台两种情况各试一次。
