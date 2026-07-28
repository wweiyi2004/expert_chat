# 应用更新与 OTA

本项目同时支持两种更新：

| 类型 | 入口 | 用户体验 |
|------|------|----------|
| **整包** | GitHub Releases | 应用内下载；Android 调起安装器，Windows 保存 zip 并打开目录 |
| **代码补丁 OTA** | Shorebird | 后台/手动下 Dart 补丁，**下次冷启动**生效，无需重装 |

应用内入口：**设置 → 关于与更新**。

启动时会：

1. 检查 GitHub 是否有更新版本（可「跳过此版本」）  
2. 检查并下载 Shorebird 补丁；若已就绪则提示重启  

## 整包发布命名（资产匹配）

GitHub Release 资产建议：

```text
expert-chat-android-arm64-vX.Y.Z.apk      # 推荐：近 5 年手机（arm64）
expert-chat-android-armeabi-v7a-vX.Y.Z.apk
expert-chat-android-universal-vX.Y.Z.apk  # 不确定架构时
expert-chat-android-x86_64-vX.Y.Z.apk
expert-chat-windows-x64-vX.Y.Z.zip
```

应用内选包逻辑：

1. 按设备 ABI 优先匹配 arm64 / v7a / x86_64 文件名  
2. **仅当 ABI 未命中时**回退 `universal`  
3. **不会**再回退到「任意 .apk」（避免把 arm64 包推给 v7a 设备）

当前侧载列车可只发 **arm64 + Windows**；非 arm64 用户需 universal 或对应 ABI 包。Shorebird 基座须用 `shorebird release` 构建，与普通 `flutter build` 不通用。

## Android 正式签名

Android release 构建采用 fail-closed：缺少正式签名配置时，
`assembleRelease` / `bundleRelease` / `packageRelease` 会直接失败，不会回退到 debug 证书。

1. 复制 `android/key.properties.example` 为 `android/key.properties`
2. 填写 keystore 密码、别名和文件路径
3. 将 `.jks` 安全备份；`key.properties` 与 keystore 均不可提交到 Git

首次对外发布后必须持续使用同一签名证书，否则在野安装无法覆盖升级。

## Shorebird 前置条件

1. 安装 CLI：

   ```powershell
   irm https://raw.githubusercontent.com/shorebirdtech/install/main/install.ps1 | iex
   ```

2. 注册并登录：https://console.shorebird.dev  

   ```powershell
   shorebird login
   ```

3. Windows 建议开启 Git 长路径：

   ```powershell
   git config --system core.longpaths true
   ```

## 初始化（只需一次）

```powershell
cd E:\wweiyi\Project\Software\expert_chat
shorebird init --display-name "Expert Chat"
```

会生成 `shorebird.yaml`（含 `app_id`）。**请提交到 Git。**

## 发布基座包（用户必须先装这个）

普通 `flutter build` **不能**收补丁。必须用：

```powershell
# Android（APK，侧载 / 内测）— 建议同时打 ABI 分包
shorebird release android --artifact apk -- --build-name=1.5.1 --build-number=7

# Windows
shorebird release windows -- --build-name=1.5.1 --build-number=7
```

把生成的安装包挂到 GitHub Release（与整包检查同一通道）。

## 推送代码补丁（免重装）

只改 **Dart** 后：

```powershell
shorebird patch android
shorebird patch windows
```

注意：

- **不能**只靠补丁：原生插件变更、**新增/替换 assets（字体等）**、Flutter 引擎大版本  
- 补丁绑定「当时的 release 版本号」；升 `1.5.0 → 1.5.1` 要先再 `shorebird release`  

## 应用内行为摘要

| 操作 | 行为 |
|------|------|
| 检查代码补丁 | 查 + 下载；提示冷启动 |
| 检查整包更新 | 比版本 → 应用内下载 → Android 安装 / Windows 打开目录 |
| 跳过此版本 | 仅启动弹窗；设置里手动检查仍会提示 |
| Shorebird 自动 | `shorebird.yaml` 默认 `auto_update` 开启 |

## 调试说明

- `flutter run` / 普通 `flutter build`：**无** Shorebird 引擎，补丁检查会显示「未启用」  
- 整包下载在 Debug 下仍可用（走 GitHub）  
