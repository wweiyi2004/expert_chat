**依赖与兼容决策 · 2026-09-22**

维护人：项目维护者。下次统一复核：2026-10-22；出现安全公告时提前处理。

| 组合 | 当前决策与退出条件 |
| --- | --- |
| Flutter / Dart | 固定 Flutter 3.44.0 / Dart 3.12.0；SDK 升级需同时跑完整测试、数据库迁移、Windows 与 Android 原生构建，Windows 语义树按专门验收项处理 |
| Android 构建 | AGP 调整到 8.11.1，Kotlin 到 2.2.20；保留既有 Gradle 9.1.0 和兼容标志。部分第三方插件仍使用 KGP，不能在它们迁移前宣称 Built-in Kotlin 全部迁移完成 |
| Python 文档栈 | FastAPI、Starlette、MCP、pypdf、multipart 成组更新，锁定传递依赖与哈希；以隔离 Python 3.12、源码测试、资源预算及打包后 HTTP 流程验证兼容 |
| Web / React / Worker | Next 16.3.5、React/RSC 19.3.0、Vite 8.3.0、vinext 1.0.0-beta.11；原型仍为实验。构建产物包含 Cloudflare 专有导入，测试使用真实 workerd/Miniflare 环境，不能直接当 Node 模块运行 |
| Web esbuild override | 将传递 esbuild 统一到修复分支（至少 0.28.1），避免旧 @esbuild-kit 的漏洞；已验证 Drizzle 配置加载/生成入口和 Worker 构建。上游解除旧范围后移除 override |
| Web fflate override | 升级到 0.8.x 修复分支，覆盖旧字体处理依赖的 0.7.x 约束；上游升级后移除。任何涉及字体/压缩的变化需重新验证实际产物 |
| archive / xml / Office 解析 | Flutter 端存在已有版本组合限制，未因“存在新版”而盲目跨版本升级；检查当前安全公告，同时保留输入/展开资源限制 |
| file_picker / share_plus / win32 | 作为一组验证升级，避免单包升级破坏桌面插件解析。优先跟踪修复公告和平台迁移，不能无限期只靠旧注释固定版本 |
| speech_to_text_windows 本地补丁 | 来源 1.0.1，当前补丁负责 SAPI 事件订阅、语言枚举及 JSON 转义；上游等效修复经中文实机识别验证后删除 override。见 third_party 下的补丁说明 |

参考：[AGP 8.11 官方兼容信息](https://developer.android.com/build/releases/agp-8-11-0-release-notes)、[Flutter Built-in Kotlin 迁移条件](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)。不隐藏插件警告，不通过关闭依赖校验取得发布“通过”。
