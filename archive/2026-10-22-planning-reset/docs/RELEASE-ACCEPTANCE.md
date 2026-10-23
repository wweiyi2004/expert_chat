# 商业发布验收记录（2026-09-07）

结论：尚未达到完整发布验收通过。以下为当前工作区的实测结果，不代表已发布安装包，也不代表所有服务商、设备和系统版本均兼容。

## 结果

| 项目 | 实测结果 | 发布限制 |
| --- | --- | --- |
| 真实聊天服务 | 普通响应、错误密钥拒绝、本地停止等待、鉴权失败后正确配置重试，4 项通过 | 未证明远端任务取消，也未进行持续负载测试 |
| 真实生图服务 | 首次出现 FormatException；单次重试生成 1254×1254 PNG，完成解码与人工查看 | 首次异常没有足够响应证据定位根因；不能把重试成功视为稳定性通过 |
| 当前配置的远程文档服务 | 代理返回 HTTP 502，绕过代理直连超时 | 编辑下载、缺失文档拒绝、上传中止均未通过远程验收，需恢复服务后重跑 |
| 隔离的本机文档服务 | 实际 HTTP 调用：工具发现、分块上传、编辑与资源下载、缺失 ID 拒绝、失败后重试、上传中止、两次文档清理，共 8 项通过 | 只证明本机客户端与文档引擎链路，不替代远程服务验收；测试资源已清理 |
| Windows 原生无障碍 | 独立测试入口启用原生语义，执行 10 轮流式输出和设置页往返，MSAA 能读取测试标记和发送按钮 | 正式入口的语义禁用保护仍保留；UIA 只读取到窗口外壳，未完成 Narrator 人工操作验收 |
| Android 真机 | 当前无连接设备、无已安装模拟器 | 覆盖升级、前后台切换、系统结束进程后的恢复未验收；后续需独立测试应用标识和构造数据 |

## 本轮修复与自动检查

- MCP HTTP 5xx 现在提供“文档服务暂时不可用”的处理建议，不把代理错误正文直接展示给用户；统一错误分类增加服务不可用。
- 针对 HTTP 502 增加回归，验证状态分类、中文指引及代理内部信息不会泄漏。
- Flutter 完整测试：924 项通过、1 项跳过；静态分析无问题。
- Windows 原生检查使用外部 MSAA/UIA 探针；Dart 侧要求外部报告存在且读取到控件，避免仅仅“不崩溃”就误报无障碍成功。

## 证据位置与使用限制

本机生成物位于被 Git 忽略的 `output/acceptance/`：

- `service-results.json`：首轮真实 API 结果。其中 `document_missing_id` 的旧断言过宽，把传输异常当作预期拒绝，该条结果作废。修正后以 `service-results-document.json` 为准，远程文档检查失败。
- `service-results-image.json`、`live-image.png`：唯一一次生图重试的成功结果。两次请求总计，不从此样本估算成功率。
- `local-mcp-results.json`：隔离本机文档服务的 8 项结果，剩余文档与上传集合均为空。
- `uia-probe-result.json`、`uia-dart-result.json`：原生可访问节点与流式页面测试结果。MSAA 与 UIA 分别报告，不能混称。
- `tmp/acceptance-full-test.log`、`tmp/acceptance-analyze.log`：完整回归与静态分析日志。

真实 API 检查只读取当前应用的连接配置和安全存储中的对应密钥，在内存中发起固定的合成请求；不读取聊天记录、不修改应用配置。报告不保存密钥，仍含服务地址等机器信息，因此不纳入版本库。文档清理只处理本次创建并记录的资源 ID。

## 复验入口

Windows 无障碍（使用模拟模型和内存数据，不访问真实 API）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_windows_accessibility_acceptance.ps1
```

真实服务测试默认跳过。显式开启后会调用当前已配置的服务，可能产生费用；可按 `chat`、`image`、`document` 分别执行，避免无关重跑。示例仅复验文档服务：

```powershell
flutter test --no-pub integration_test/connection_inventory_test.dart -d windows --dart-define=EXPERT_CHAT_READ_CONNECTIONS=true --dart-define=EXPERT_CHAT_RUN_LIVE=true --dart-define=EXPERT_CHAT_LIVE_SCOPE=document --dart-define=ACCEPTANCE_REPORT_DIR=E:/wweiyi/Project/Software/expert_chat/output/acceptance
```

独立文档验收工具为 `tool/mcp_acceptance.dart`，要求通过进程环境提供 `EXPERT_CHAT_MCP_URL`、`EXPERT_CHAT_MCP_TOKEN`，可用 `EXPERT_CHAT_ACCEPTANCE_REPORT` 指定报告位置；执行 `dart run tool/mcp_acceptance.dart`。本轮使用随机回环端口、随机测试令牌和隔离数据目录，结束后关闭测试服务。

## 仍需关闭的验收项

1. 恢复远程文档服务，重跑创建、编辑、下载、预期失败、重试与清理。
2. 收集生图格式异常的脱敏响应证据，确认原因和处理行为，再按实际使用负载验证稳定性。
3. 连接 Android 测试设备，验证安装升级、后台与进程恢复。
4. 验证 Windows 正式入口的引擎兼容方案及实际屏幕阅读器操作，再决定解除语义保护。独立测试通过不足以证明历史崩溃消失。
