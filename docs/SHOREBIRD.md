# Shorebird 代码补丁 OTA（免重装）

本项目同时支持两种更新：

| 类型 | 入口 | 用户体验 |
|------|------|----------|
| **整包** | GitHub Releases | 下载 APK / zip 后安装或覆盖 |
| **代码补丁 OTA** | Shorebird | 后台下 Dart 补丁，**下次冷启动**生效，无需重装 |

## 前置条件

1. 安装 CLI（本机已可安装）：

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

在项目根目录：

```powershell
cd E:\wweiyi\Project\Software\expert_chat
shorebird init --display-name "Expert Chat"
```

会生成 `shorebird.yaml`（含 `app_id`），并把它加入 `pubspec.yaml` 的 assets。  
**请提交 `shorebird.yaml` 到 Git。**

## 发布基座包（用户必须先装这个）

普通 `flutter build` **不能**收补丁。必须用：

```powershell
# Android（APK，侧载 / 内测）
shorebird release android --artifact apk -- --build-name=1.2.0 --build-number=3

# Windows
shorebird release windows -- --build-name=1.2.0 --build-number=3
```

把生成的安装包发给用户（也可继续挂到 GitHub Release）。

## 推送代码补丁（免重装）

只改 **Dart** 后：

```powershell
shorebird patch android
shorebird patch windows
```

注意：

- **不能**只靠补丁：原生插件变更、**新增/替换 assets（字体等）**、Flutter 引擎大版本  
- 补丁默认绑定「当时的 release 版本号」；升 `1.2.0 → 1.3.0` 要先再 `shorebird release` 一版基座  

## 应用内行为

- Shorebird 默认在启动时**后台**检查并下载补丁  
- 「我的 → 关于与更新 → 检查代码补丁」可手动检查并下载  
- 下载后需 **完全退出再打开** 才运行新代码  

## 与 GitHub 检查更新的关系

- **检查更新**：整包（新 APK/zip）  
- **检查代码补丁**：Shorebird OTA  

两者可同时保留。
