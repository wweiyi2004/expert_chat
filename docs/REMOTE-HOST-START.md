# Expert Chat 独立电脑执行端 3.8.0

本包已经包含 `expert-remote-host.exe`，**不需要安装 Dart SDK 或 Flutter**。完整解压后，在该 EXE 所在文件夹打开 PowerShell。不要关闭正在运行的 Expert Chat 或现有任务；这个宿主是独立程序，只接收通过“远程电脑任务”提交的新任务。

## 第一次启动

把下面的模型地址、模型名和项目目录换成你自己的值。私有数据目录必须在项目之外；项目目录需要已经存在。

```powershell
$dataDir = Join-Path $env:LOCALAPPDATA 'ExpertChatRemote\computer-a'
$env:EXPERT_REMOTE_MODEL_URL = 'https://your-provider.example/v1'
$env:EXPERT_REMOTE_MODEL = 'your-model'
$env:EXPERT_REMOTE_MODEL_KEY = [System.Net.NetworkCredential]::new('', (Read-Host '模型 API 密钥' -AsSecureString)).Password
$env:EXPERT_REMOTE_MODEL_FORMAT = 'openAiCompatible'
.\expert-remote-host.exe $dataDir 'D:\your-project' 47831
```

输入密钥时不会回显，也不必把密钥写进命令历史或项目文件。四种固定协议名称是 `openAiCompatible`、`openAiResponses`、`anthropicMessages`、`geminiNative`。没有模型时，明确提交并批准的命令仍可执行，但不会伪造 Agent 结果。数学能力可选，需要电脑已有 Python/SymPy；缺失会明确返回不可用。

保持此宿主进程运行，手机断开或关闭桌面界面不会结束它的任务。停止宿主或电脑重启后，未确认操作会等待人工核验，不会重放命令。原桌面聊天中的旧任务不会自动迁移到这里。

## 配对和安全连接

默认只监听电脑的 `127.0.0.1:47831`。可先在同一电脑的 Expert Chat 中打开“工具 → 远程电脑任务”，填写 `http://127.0.0.1:47831`。配对密钥在 `$dataDir` 目录的 `credential` 文件里；它授权此宿主的固定项目，请只复制给自己的设备，不要公开。

手机不能直接访问电脑的 `127.0.0.1`。跨设备请使用已有的加密 VPN/SSH 隧道，或使用手机信任、名称匹配的 HTTPS 证书。普通局域网不等于加密连接。

例如，**已经建立自己的加密 VPN** 后，在下一次启动时绑定电脑的实际 VPN 地址：

```powershell
# 把 100.64.0.10 换成你自己电脑的实际 VPN 地址
.\expert-remote-host.exe $dataDir 'D:\your-project' 47831 '100.64.0.10' --allow-network --protected-tunnel
```

手机填写相应地址和配对密钥，勾选“已通过自己的加密 VPN / SSH 隧道连接”，再配对。HTTPS 的证书设置见后面的[完整部署说明](DEVELOPMENT.md)。程序不会替你建立 VPN、公网中继或放宽证书验证。

## 权限、续轮和停止

默认是“请求批准”，每条命令都等人工决定。若电脑所有者明确需要另外两档，在**下次启动前**设置：

```powershell
$env:EXPERT_REMOTE_ALLOWED_POLICIES = 'request,assisted,full'
```

手机才会出现“模型辅助批准”和“完全访问”选项。完全访问会自动运行所选任务的命令，使用电脑账号权限；工作目录不是系统沙箱。不要为了改设置强行终止正在执行的任务。

达到轮次上限时，可在手机对原任务追加轮次或停止，不必重新提交目标。日志、审批和成果下载都在同一任务下；断线后先重连查原任务。配对密钥 30 天过期，可在宿主下次启动时追加 `--rotate-pairing` 轮换；换钥不会重启或重放旧任务。

[完整协议、恢复边界和开发验证说明](DEVELOPMENT.md)包含源码构建命令；那一部分供开发者使用，运行本 ZIP 不需要照着编译。`manifest.json` 提供包内文件 SHA256，`package-version.txt` 标明版本。
