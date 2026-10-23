**Windows 语义树兼容记录**

维护人：项目维护者。登记：2026-09-22。复核日期：2026-10-22，以及每次 Flutter SDK 升级时。

当前固定 Flutter 3.44.0。正式入口保留 Windows 语义树关闭保护，原因是既有原生崩溃记录指向 `AccessibilityBridge::CreateRemoveReparentedNodesUpdate` 的空父节点路径。本轮检索没有取得可以确认修复此问题的具体上游版本或 issue，不能把不存在的修复证据写进发布说明。

因此 Windows 屏幕阅读器完整支持仍属于未完成验收项，不能标注为“无障碍已修复”。其他平台不受这一保护影响。

可以构建使用正式入口、启用语义树的专门测试版本：

```powershell
flutter build windows --debug --dart-define=EXPERT_CHAT_WINDOWS_SEMANTICS=true
```

该开关仅用于在隔离测试账户/数据中验证；默认构建仍保留保护。已有自动化探针可通过 `scripts/run_windows_accessibility_acceptance.ps1` 检查测试入口的 MSAA/UIA 结果，但它不替代正式入口或 Narrator 人工验收。

移除保护的验收条件：记录确定的引擎修复提交/版本或可复核的根因修复；在正式入口使用 Narrator 完成聊天、停止、历史切换、设置修改；在长回复、连续工具步骤和中英文输入法组合下重复操作；保存崩溃/探针/人工验收结果。未经这些证据，不仅凭“没有观察到崩溃”关闭此兼容项。
