# 后台接收回复

## 修复范围

Android 原先只用 `wakelock_plus` 防止屏幕休眠，并在后台生成结束时发送通知；没有接收期间的前台服务。屏幕保持唤醒不能替代后台进程与 CPU 的运行保护。

现在接受发送、重新生成等操作后，在任何设置读取、上传或模型请求的异步等待前申请启动 `GenerationService`。服务与 Flutter 在同一进程运行，以 `dataSync` 类型显示低优先级的「正在接收回复」通知，并持有有时限的 `PARTIAL_WAKE_LOCK`。Android 不再使用屏幕常亮实现这项保护，可以正常熄屏。

完成、用户停止、前置检查失败、异常退出、控制器销毁时均释放保护。原生侧还处理 Flutter 引擎清理、任务移除和 Android 15 的服务超时，不自动重启服务或重发模型请求。启动、停止命令串行执行，避免快速停止／重发留下旧服务或误释放新任务。

应用切入后台时刷新内存中的消息并安排一次本地保存；后台收到的正文和思考内容继续合并、定期保存。回到前台刷新同一条消息，保留原来的请求。Windows 保留原有防休眠方式，共享上述保存逻辑；本次没有增加 iOS 后台执行能力。

## 安装与边界

- 增加了原生 Android 服务和 manifest 权限，必须通过完整 APK 更新。已经发布的 v3.6.0 不包含这项修复；仅推送 Dart OTA 无法为旧安装包增加服务。后续正式包应重新建立 Shorebird 基线。
- 用于正常切换应用、回桌面及锁屏期间接收。强制停止、系统杀进程、断网和设备休眠策略仍可能中断普通 SSE；本次不承诺这些情况下自动恢复连接，不自动重复提交可能计费的请求。
- Android 15+ 对后台 `dataSync` 服务有时间配额；收到系统超时回调会及时停止服务并释放资源。需要离线恢复的任务应继续使用已有的服务端持久任务能力。

官方依据：[启动前台服务](https://developer.android.com/develop/background-work/services/fgs/launch)、[服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)、[服务超时](https://developer.android.com/develop/background-work/services/fgs/timeout)、[CPU 唤醒锁](https://developer.android.com/develop/background-work/background-tasks/awake/wakelock/set)。

## 验证

```powershell
flutter test test/generation_keep_alive_test.dart test/generation_execution_test.dart test/generation_stream_test.dart test/stream_answer_presenter_test.dart
flutter test test/chat_background_stream_test.dart test/widget_test.dart test/tools_navigation_test.dart
flutter analyze
```

Android 端使用独立、已启动的模拟器运行：

```powershell
python tool/test_background_generation.py --serial emulator-5566 --adb <adb.exe路径> --flutter <flutter.bat路径>
```

测试安装独立测试入口，使用设备本地 SSE 服务，不读取真实会话、使用真实凭据或调用真实模型。主机脚本只接受 `emulator-*` 设备，自动授予测试应用通知权限、回桌面、锁屏、检查服务与 CPU 唤醒锁，30 秒后解锁返回。测试要求后台实际收到至少 20 个增量且无流错误，随后验证前台服务已清理。日志和设备状态保存在 `tmp/background-stream/`。

模拟器验证不能替代各手机厂商的省电策略实测。

2026-09-15 验证结果：上述两组测试分别通过 23 项和 130 项；静态检查无问题；Android debug APK 编译通过。Android 15 / API 35 模拟器中，回桌面并锁屏约 30 秒，后台实际接收 31 个增量，返回前台继续使用同一连接；集成测试通过，结束后前台服务和 CPU 唤醒锁均已释放。
