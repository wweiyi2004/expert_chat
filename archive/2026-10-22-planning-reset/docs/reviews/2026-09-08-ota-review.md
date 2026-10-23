# 代码审查与修复 · 2026-09-08

本轮重点审查近期改动的页面导航、可选工具、图片选择、素材管理，以及 OTA 基座兼容性。以下问题均先补充失败用例，修复后回归通过。审查不等同于 Android 真机或所有外部服务的验收。

## 已修复

### P2：来源页面移除后，延迟导航访问失效的 WidgetRef

`openShellTab` 在下一帧才读取页面的 `WidgetRef`。来源页面在该帧前被移除时，Riverpod 报出访问已卸载组件的错误，跳转无法完成。

- 调度前捕获导航控制器，回调不再依赖已移除页面的引用。
- 控制器已销毁时忽略迟到的切换，避免容器退出期间写入状态。
- 回归：移除发起导航的组件后，跳转仍能完成且没有框架异常。

### P2：选图权限默认包含视频，与图片入口的实际用途不一致

相册查询只取图片，但权限请求沿用插件的 `RequestType.common`（图片与视频）。应用的 Android 权限声明只请求图片，权限范围不一致，可能造成多余授权或访问状态判断异常。

- 显式请求 `RequestType.image`，不请求媒体位置。
- 回归：检查发送给原生插件的权限参数；请求类型由 3 修正为 1。
- 本轮没有修改 Android Manifest，实际机型上的权限交互仍需真机验证。

### P2：小屏手机弹出键盘后，素材错误提示超出可用高度

素材搜索时发生读取错误，完整错误卡片原先位于弹层的固定区域。在 360×640 屏幕、键盘占 300 像素的情况下出现布局溢出。

- 将错误提示放入剩余可用区域，支持滚动查看和重试。
- 已有素材和选中状态保留，读取恢复后继续选择。
- 回归：键盘展开时模拟分类读取失败，确认无溢出、重试入口可达且能恢复列表。

## 验证

- 定向回归：16 项通过。
- 使用 Shorebird 基座对应的 Flutter 3.44.7 执行完整测试：933 项通过、1 项跳过。
- 同版本静态分析：无问题。
- 失败复现日志：`tmp/ota-review-repro.log`、`tmp/ota-review-layout-repro.log`。
- 修复日志：`tmp/ota-review-fixed.log`、`tmp/ota-full-tests.log`、`tmp/ota-analyze.log`。

## OTA 图标兼容性

Android 基座的 Material Icons 字体包含 202 个字形。新增界面引用了其中没有的 `apps`、`apps_outlined`、`create_new_folder_outlined`、`help_outline`、`history`、`radio_button_checked` 六种图标，已分别替换为基座已有的工具、文件夹、说明、历史与选中图标，按钮用途和文字保留。

图标调整后再跑完整测试仍为 933 项通过、1 项跳过，静态分析无问题；日志为 `tmp/ota-full-tests-final.log`、`tmp/ota-analyze-final.log`。基座字体 SHA256 为 `6382e1dd2769ec4e9a126071024f0eea5acd577fb3921434556df10bc7ee4d01`。

## 发布约束

目标是现有 Android 与 Windows `3.5.0+4107` Shorebird 基座，正式通道 `stable`。发布前执行 `--dry-run`，确认原生与资源兼容；不跳过不兼容检查。流程依据 [Shorebird 补丁文档](https://docs.shorebird.dev/code-push/patch/)。实际发布结果另记在本轮发布记录中。
