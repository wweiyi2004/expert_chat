# 电脑执行端工作区

首个实现提供独立 CLI 和 stdio MCP 文件服务，工作区配置由电脑执行端持有。已实现工作区注册、目录访问规则、受限文件读写、写入版本检查与即时撤销。

Windows 桌面应用已接入“工具 → 电脑工作区”管理页面，会话的“工作”模式也已自动接入文件工具。共享 Rust 模型引擎、自动运行命令、任务 worktree 管理与手机远程界面尚未接入；当前复用现有会话模型循环调用 Rust 文件服务。

## 在会话中使用

切换到“工作”即可开始，无需先选择目录或手动配置 MCP。未绑定项目时使用应用专用默认工作区；Windows 默认位置为 `%LOCALAPPDATA%/expert-chat/desktop-workspaces/default`，不是当前项目、用户主目录或整块磁盘。

默认目录首次创建时可读写。之后可以在管理页面收紧它的权限，后续启动不会重新放宽；默认登记不能移除，文件也不会自动清理。使用自定义 `--data-dir` 时，默认目录位于配置目录旁的 `<配置目录名>-workspaces/default`。

点击“工作”旁的下拉箭头，或输入框上方的“工作选项”，可绑定已登记项目或恢复默认。每个会话的选择独立保存在本机，不随会话导出/备份传递给其他设备。所选项目被移除时会明确报错，不偷偷改用默认目录。

工作模式下，模型可调用列目录、读文件、带版本校验的写文件和创建目录工具，结果回送给下一轮模型请求。切回聊天后不自动开放这些文件工具。生成中不能从页面切换目标；每轮绑定的目录固定，权限仍由 Rust 在每次操作时检查。停止生成后关闭该轮 MCP 连接；已提交写入的结果不确定时需要核对文件。

要求所选模型支持工具调用。文件工具接入不代表可以运行 shell、构建或测试命令；这些能力仍未开放。

## 桌面页面

打开 Expert Chat 的“工具 → 电脑工作区”，选择“添加工作区”，填写名称并选择项目文件夹。默认只读；展开工作区后可添加目录规则、编辑权限或移除登记。移除工作区不删除源文件，删除规则会恢复继承权限。

Windows 构建会自动编译并将 `expert-desktop.exe` 放在应用程序旁。页面仅调用这个随应用打包的执行端，不从项目目录或 PATH 寻找同名程序。页面保存失败会保留表单，CLI 改动后可通过刷新读取最新规则。

## 构建和检查

在仓库根目录运行，当前 Windows 实测工具链为 Rust 1.96.0：

```powershell
cargo build --manifest-path next/Cargo.toml --locked
python scripts/check.py --scope desktop
```

Windows 可执行文件为 `next/target/debug/expert-desktop.exe`。Linux 为同目录下的 `expert-desktop`。依赖通过 `next/Cargo.lock` 锁定。

## 添加工作区并划定范围

以下路径为示例，替换成电脑上已经存在的实际项目目录。首次使用默认配置目录为 Windows `%LOCALAPPDATA%/expert-chat/desktop`；可用全局参数 `--data-dir` 指定独立配置目录。

```powershell
# 注册项目，默认整个项目只读。
next/target/debug/expert-desktop.exe workspace add demo --name "我的项目" --path "E:/Projects/demo"

# 仅允许修改 src 子目录，其他位置保持只读。
next/target/debug/expert-desktop.exe scope set demo source --path "E:/Projects/demo/src" --access read-write

# 禁止访问某个已有目录。
next/target/debug/expert-desktop.exe scope set demo private --path "E:/Projects/demo/private" --access deny

# 额外授权参考目录，只读。
next/target/debug/expert-desktop.exe scope set demo reference --path "E:/Reference/library" --access read-only

next/target/debug/expert-desktop.exe workspace list
next/target/debug/expert-desktop.exe workspace show demo
next/target/debug/expert-desktop.exe workspace default
```

规则适用于整个目录子树，**路径最具体的规则优先**。例如根目录只读、`src` 可写、`src/private` 拒绝访问。新增子规则可以覆盖祖先规则，因此需要查看完整规则后判断有效权限。

`root` 是主目录作用域名称，其他名称是额外入口；不能通过 `root` 绕过更具体的拒绝或只读规则。绝对路径、`..`、Windows 设备路径和 ADS 路径不接受。链接/junction 不跟随；需要访问链接目标时，将目标真实目录另行授权。

权限配置目录不能与任何授权范围重叠，避免文件工具修改自己的权限。规则变化对后续工具调用立即生效；已经接受的同步文件操作会先完成，权限更新随后取得锁。

```powershell
# 收回 source 的写权限。
next/target/debug/expert-desktop.exe scope set demo source --path "E:/Projects/demo/src" --access read-only

# 完全禁止此目录，使用 deny。
next/target/debug/expert-desktop.exe scope set demo source --path "E:/Projects/demo/src" --access deny

# 删除规则会恢复继承权限，并不等价于禁止访问。
next/target/debug/expert-desktop.exe scope remove demo source

# 删除工作区注册，不删除源文件；已连接服务的后续访问也会被拒绝。
next/target/debug/expert-desktop.exe workspace remove demo
```

## 文件操作

```powershell
next/target/debug/expert-desktop.exe file list demo
next/target/debug/expert-desktop.exe file read demo src/main.rs
next/target/debug/expert-desktop.exe file read demo --scope reference README.md
next/target/debug/expert-desktop.exe file mkdir demo src/new_module
```

读取返回 UTF-8 内容与 SHA-256。写已有文件时必须提交该版本值；外部修改后旧版本被拒绝。新文件使用 `new`，已有路径不会被覆盖。内容由 stdin 提供，避免把多行源码放进 shell 参数：

```powershell
Get-Content -Raw -Encoding utf8 ./prepared-source.txt | next/target/debug/expert-desktop.exe file write demo src/new.rs --expected new
```

PowerShell 管道可能调整末尾换行；要求字节精确时使用能原样传递 UTF-8 stdin 的程序或 MCP。文本工具单文件上限 1 MiB，目录最多返回 1000 项并标记截断。已有文件使用同目录临时文件替换，保留原权限；写入新文件失败时可能留下未完成文件，调用方应检查结果。

版本检查防止普通过期编辑，并由执行端锁串行化自身操作；它不是与外部编辑器之间的跨进程原子 compare-and-swap。该服务也不是防御同一系统用户恶意并发修改权限库的操作系统沙箱。

## MCP 接入

在支持本地 stdio MCP 的客户端中配置已经构建的程序：

```json
{
  "command": "E:/path/to/expert_chat/next/target/debug/expert-desktop.exe",
  "args": ["serve", "demo"]
}
```

使用自定义配置目录时，参数为 `["--data-dir", "E:/ExpertChatState", "serve", "demo"]`。不同客户端可能将 `args` 称为“参数列表”；在现有 Expert Chat 的本地 MCP 配置中分别填写程序与参数即可。不要将本服务标记为电脑 UI 操作服务。

服务固定绑定一个工作区，仅暴露：

- `coding_workspace_info`：查看工作区和当前访问规则。
- `coding_list_directory`：列目录，拒绝的条目不返回。
- `coding_read_file`：读取内容与版本。
- `coding_write_file`：在可写范围创建或更新文件。
- `coding_create_directory`：创建单级目录。

新增/扩大权限通过用户使用的本地页面或 CLI 完成，不提供给模型。读写服务每次重新读取当前授权，重新连接不会恢复已撤销权限。MCP 握手兼容 `2025-11-25` 的路径已通过黑盒测试。

## 权限边界和后续工作

这里的访问约束适用于本服务的文件工具。没有暴露任意 shell、网络请求、删除源文件或修改权限的模型工具；其他独立 MCP 服务不受本服务代管。

命令执行需要单独的进程隔离后端。工作目录不能限制一个 shell 读取其他目录，因此当前没有“允许命令但假装仍被目录规则隔离”的开关。后续先验证现成隔离实现，再开放构建/测试命令及相应授权流程。

实现复用 `cap-std`/`cap-tempfile` 的目录能力操作与官方 `rmcp` SDK；注册信息采用加锁与原子替换保存。本轮没有创建真实项目授权、启动用户 MCP 服务或修改用户源文件，验证使用临时样例。

验证覆盖只读/读写/拒绝、嵌套覆盖、外部目录、撤销、过期版本、路径逃逸、Windows junction、损坏配置和真实 stdio 文件修改流程。Windows 已实测；CI 已加入 Windows/Linux 检查，Linux 结果以 CI 实际运行记录为准。
