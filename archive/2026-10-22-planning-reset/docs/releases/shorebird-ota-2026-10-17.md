# Shorebird 热更新发布（2026-10-17）

已发布到 stable，2026-10-17 23:08（北京时间）完成实际下发核验。

| 平台 | 已安装基座 | 补丁 | Patch ID | 架构 |
| --- | --- | --- | --- | --- |
| Android | 3.7.0+4110 | #1 | 727135 | arm、aarch64、x86_64 |
| Windows | 3.6.1+4109 | #1 | 727155 | x86_64 |

本次为代码补丁，无需重装或安装 3.7.1 新基座。客户端检查代码补丁，下载后完全退出并重新打开应用生效。应用主版本号继续显示原基座版本，补丁号为 #1。

更新包含 DeepSeek 默认 Search / Fetch、模型与识图能力更新、输入框上方三个开关、合并语音与发送、新会话按钮移位、设置返回及草稿保留、提示词关系说明和聊天 / 工作引导。

兼容措施：Android 复用基座已有图标字形，生成的图标字体与基座逐字节一致；Windows 保留 3.6.1 原生文件与资源，缺少新头像时使用已有图标回退。Windows 安装图标、原生托盘功能不通过此补丁新增。Windows 资源中 README 与许可证的换行已对齐基座，许可证正文保持相同。未使用 allow-native-diffs 或 allow-asset-diffs。

源码：Android 59c31aec1234e5aa4527d4e29d3926d684ee5bf7；Windows 361c8aa29857108961fc5f10301afd9c46702968。Flutter 分别沿用基座 3.44.0 与 3.44.7。

验证：两个补丁的云端 channel 均为 stable、未回滚；四个平台/架构更新检查均返回 patch_available=true、patch.number=1。原有完整测试基线 1,413 项通过；本次主工作区及旧 Windows 资源环境的界面兼容回归各 11 项通过。验证可下发，不代表已替用户设备完成安装。

证据：output/shorebird-ota-20261017/ 下的 plan.json、android-patches.json、windows-patches.json、delivery-verification.json、font-verification.json、windows-asset-verification.json。
