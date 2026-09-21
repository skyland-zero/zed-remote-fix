# zed-remote-fix

让 **Zed 通过 SSH 把 Windows 机器当成远端开发机**（remote development server）正常工作。

Zed 官方虽然已经把 Windows 列为远端 server 的受支持平台，并且会下载
`zed-remote-server-windows-x86_64.zip`，但在 SSH 会话里它**启动不了自己的 daemon**，
于是永远卡在 `Starting proxy`，大约 60 秒后报：

```
failed to establish connection: Client exited with exit_code 1
```

本仓库用一个约 10 KB 的启动器（shim）绕过这个问题：**不改 Zed 客户端、不改协议、不重编译 Zed**，
只在 Windows 远端放一个占位的 launcher。

- 上游 issue：<https://github.com/zed-industries/zed/issues/58892>
- 根因分析：见 [docs/root-cause.md](docs/root-cause.md)
- 给上游的草稿评论：见 [docs/upstream-issue-comment.md](docs/upstream-issue-comment.md)

---

## 原理

```
Zed 客户端 ──ssh──▶ %USERPROFILE%\.zed_server\zed-remote-server-stable-<版本>.exe
                    （这个名字下装的是 shim.exe，不是官方二进制）
                          │
                          ├─ 启动/复用 daemon：
                          │    zed-remote-server-real.exe run --log-file ... --stdin-socket ...
                          │    （CreateProcess + CREATE_BREAKAWAY_FROM_JOB，脱离 SSH 的 job object）
                          │
                          └─ 以 proxy --reconnect 模式运行官方二进制，把 stdio 原样转发
```

shim 做三件事：

1. 清掉上一个 daemon 死掉后残留的 `server.pid` / `*.sock`（Windows 上 AF_UNIX socket 文件不会随进程消失，
   残留文件会让新 daemon `bind` 失败）；
2. 用 `CreateProcess` 把官方二进制的 `run` 子命令以「脱离 job object」的方式拉起（这是 Zed 自己做不到的一步）；
3. 其他调用（例如 Zed 用来校验的 `version`）原样转发给官方二进制。

---

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `shim/shim.cs` | shim 源码（C#，只用 .NET Framework 4.x 语法） |
| `build.ps1` | 用 Windows 自带的 `csc.exe` 编译 shim |
| `install.ps1` | **在远端 Windows 机器上执行**：识别官方二进制 → 备份 → 编译 → 安装 → 自检 |
| `install-conpty.ps1` | **在远端 Windows 机器上执行**：把新版 ConPTY（`conpty.dll` + `OpenConsole.exe`）放到 `.zed_server`，修远端终端里 TUI 光标不可见等问题 |
| `verify.ps1` | 自检；`-LiveTest` 会真的跑一次 proxy 握手 |
| `uninstall.ps1` | 还原官方二进制（`-Purge` 直接清空 `.zed_server`） |
| `docs/` | 根因分析、给上游的草稿 |

---

## 前置条件（远端 Windows 机器）

- Windows 10 1803+ / Windows 11（Zed 的 Windows remote server 只支持 x86_64 / arm64）
- **OpenSSH Server** 已安装并启动（`Get-Service sshd`），客户端能免密登录
- OpenSSH 的默认 shell 保持 `cmd.exe` 或 PowerShell
  （`HKLM\SOFTWARE\OpenSSH` 的 `DefaultShell`）——**不要**设成 MSYS2 / Git Bash 的 bash，
  那会让 Zed 的 Windows 探测（`cmd.exe /c ver`）被路径转换搞坏
- .NET Framework 4.x（Windows 自带 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`）
- 有 `curl`/`wget` 最好，没有也行（Zed 会在本机下载后通过 SFTP 上传，约 40 MB）

---

## 首次部署

1. **先用 Zed 连一次这台机器**。连接会失败，但 Zed 会把官方远端二进制上传到
   `%USERPROFILE%\.zed_server\zed-remote-server-stable-<完整版本号>.exe`（约 118 MB）。
2. 把本仓库放到远端机器上（任选其一）：
   ```powershell
   git clone https://github.com/skyland-zero/zed-remote-fix "$env:USERPROFILE\zed-remote-fix"
   ```
   或者下载 zip / 直接把文件夹拷过去。
3. 在远端机器上执行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\zed-remote-fix\install.ps1"
   ```
   （如果是从别的机器 SSH 进去，可以一条命令搞定：）
   ```bash
   ssh workpc 'powershell -ExecutionPolicy Bypass -File C:\Users\<用户名>\zed-remote-fix\install.ps1'
   ```
4. 重新用 Zed 连接，即可正常打开远端目录。

可选自检（推荐）：

```powershell
powershell -ExecutionPolicy Bypass -File .\verify.ps1 -LiveTest
```

---

## Zed 升级后怎么办（**重点**）

远端文件名里带 Zed 的完整版本号，所以**每次升级 Zed 之后 shim 都会"失配"一次**：

1. 升级后第一次连接会失败 —— 这是预期的。此时 Zed 已经把新版本的官方二进制上传到
   `%USERPROFILE%\.zed_server\zed-remote-server-stable-<新版本号>.exe`。
2. 在远端重跑一次安装脚本（它会自动挑出体积最大的那个官方 exe，认出新版本号）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -CleanState
   ```
3. 再连一次即可。

> 脚本会先把被占用的 exe **改名挪走**再放新的（Windows 10 1703+ 支持替换正在运行的 exe），
> 所以**升级重装不会打断你正在进行的远端会话**。旧文件会以 `…exe.in-use-<时间戳>` 留在
> `.zed_server` 里，等那次会话结束、下次再跑 `install.ps1` 时自动清掉。
> 如果确实要强制重启远端 server，用 `-StopRunning`（会断开当前会话）。

> 想确认装对了，`install.ps1` 最后会打印 `OK  the shim forwards to the official binary correctly`，
> 并在 `%USERPROFILE%\.zed_server\zed-remote-fix-info.txt` 留下本次安装的版本号与哈希。

**换新电脑**：重复「首次部署」的 1~3 步即可，不需要任何手工改名。

---

## 验证

```powershell
.\verify.ps1              # 文件检查 + `version` 校验（和 Zed 的检查一致）
.\verify.ps1 -LiveTest    # 再跑一次真实 proxy 握手，然后自动清理
```

`-LiveTest` 通过时会看到：

```
OK  RPC handshake received on stdout (41 bytes)
OK  daemon logged "starting up"
OK  daemon accepted the proxy connection
```

---

## 回滚 / 卸载

```powershell
.\uninstall.ps1           # 把官方二进制放回版本化文件名
.\uninstall.ps1 -Purge    # 直接删掉整个 .zed_server（下次连接 Zed 会重新上传）
```

官方二进制的备份保存在 `%USERPROFILE%\.zed_server\backup\`。

---

## 排错对照表

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 卡在 `Starting proxy`，约 60 s 后 `Client exited with exit_code 1`；远端**没有** `server-*.log` | daemon 根本没被拉起（Zed 用 Explorer ShellExecute 启动失败） | 跑 `install.ps1` |
| 连接成功但 git 面板空白 / 报 `missing repository handle`、`no such worktree` | daemon 在会话进行中被重启过（例如跑了 `install.ps1 -CleanState`），客户端手里还是旧 server 的 worktree / repository 句柄 | **关闭远端窗口，重新打开远端项目**（干净重连即可，远端 git 本身没问题） |
| `stdin_task failed: Failed to connect to stdin socket ... (os error 10061)` + `server exited unexpectedly` | 上一个 daemon 死掉留下僵尸 socket | 新版 shim 会自动清理；如仍出现，`install.ps1 -CleanState` 或手动删 `%LOCALAPPDATA%\Zed\server_state\<identifier>` |
| 日志出现 `zed shim: removing stale daemon state in ...` | shim 正在清理旧状态 | 正常现象 |
| `Failed to download binary on server ... Neither curl nor wget is available` | 远端没有 curl/wget | 正常，Zed 会自动改成"本机下载 + SFTP 上传"；也可以装个 curl 让下载走服务器 |
| 远端 `cmd.exe /c ver` 行为异常 / 报 `uname` 相关错误 | 默认 shell 被改成了 MSYS2、Git Bash 等 | 把 OpenSSH `DefaultShell` 改回 `cmd.exe` / PowerShell |
| 远端 TUI（pi/vim/htop）里光标看不见 | ① 远端用的是 Windows 自带的老 ConPTY（缺 `conpty.dll`）
  ② 浅色主题下 `ansi.white` == 背景色，而 ConPTY 会把反显光标烘培成 ANSI 白底 | ① 跑 `install-conpty.ps1`，然后**新开**一个终端
  ② Pi 设置 `showHardwareCursor: true`，或主题覆写 `terminal.ansi.white`（见「附二」） |
| 连接成功但打开远端文件夹很慢 | Zed 对超大目录（>10 万文件）仍然吃紧 | 只打开具体项目子目录 |
| git 面板/diff 报错 | 先看 `%LOCALAPPDATA%\Zed\logs\server-<id>.log` 里有没有 `opening git repository at ...` | 有 → 远端 git 正常，按上面一行关窗重开；没有 → daemon 会话异常，关窗重连 |

日志位置：

- 客户端：`cmd-shift-p` / `ctrl-shift-p` → **Open Log**
- 远端：`%LOCALAPPDATA%\Zed\logs\server-<identifier>.log`
  与 `%LOCALAPPDATA%\Zed\server_state\<identifier>\`

---

## 已知限制

- 只修正「Zed 启动远端 daemon」这一步。Zed 里其他依赖 Explorer/桌面会话的功能
  （例如让远端用系统默认程序打开文件、在资源管理器里定位文件）在 SSH 会话下仍可能失败。
- 文件名与 Zed 版本绑定 → **每次 Zed 升级都要重跑 `install.ps1`**（见上文）。
- 只针对 **Windows 作为远端**；Linux/macOS 远端不需要这个 shim。
- shim 依赖 Zed 现有的 daemon 参数（`run --log-file/--pid-file/--stdin-socket/...`）。
  如果上游改了这些参数或状态目录布局，需要同步更新 `shim/shim.cs`。
- **远端终端默认用的是 Windows 自带的老版 ConPTY**（官方 zip 里只有 `remote_server.exe`，
  没带 `conpty.dll`/`OpenConsole.exe`），本地 Zed 终端则用新版 OpenConsole —— 这一步仍然值得做（终端整体
  行为/渲染更一致），但它**不是** TUI 光标不可见的原因，那个另有原因：见下一节与
  [docs/terminal-cursor.md](docs/terminal-cursor.md)。

---

## 附：修远端终端（ConPTY / TUI 光标问题）

**症状**：在 Zed 远端的终端里跑 `pi`、`vim`、`htop` 这类全屏 TUI，光标看不见（或终端渲染怪异）；
同一个程序在本地 Zed 终端里正常。

**原因**：`alacritty_terminal` 会先试 `LoadLibrary("conpty.dll")`，找不到就退回 Windows 自带的
老 ConPTY（日志会写 `Using Windows API for pseudoconsole`）。本地 Zed 安装目录里带
`conpty.dll` + `x64\OpenConsole.exe`，而官方发布的远端 server 压缩包只有 `remote_server.exe`，
所以远端一直在用老的实现。

**修法**：把客户端 Zed 安装目录里的那两个文件放到远端 `.zed_server`（保持同样的 `x64\` 结构调整）：

```powershell
# 在远端机器上执行；-Source 指向客户端那台机器的 Zed 安装目录
.\install-conpty.ps1 -Source 'C:\Users\<你>\AppData\Local\Programs\Zed'
```

也可以直接从客户端推过去：

```bash
ZED_DIR="$LOCALAPPDATA/Programs/Zed"      # 客户端的 Zed 安装目录
ssh <远端> 'powershell -c New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.zed_server\x64"'
scp "$ZED_DIR/conpty.dll"            <远端>:'C:/Users/<用户>/.zed_server/conpty.dll'
scp "$ZED_DIR/x64/OpenConsole.exe"   <远端>:'C:/Users/<用户>/.zed_server/x64/OpenConsole.exe'
```

**生效条件**：`conpty.dll` 是每次创建 pseudo console 时才加载的，所以**只要新开一个终端**即可
（不用重连）。验证方法：

```powershell
Get-Process OpenConsole -ErrorAction SilentlyContinue     # 出现进程 = 新版 ConPTY 已启用
```

或看日志里有没有 `alacritty_terminal::tty::windows::conpty  Using conpty.dll for pseudoconsole`。

---

## 附二：TUI 里光标看不见（pi / vim 的“反显光标”）

**症状**：在 Zed（**浅色主题**）的终端里跑 `pi`，输入行的光标看不见；同一个程序在 Windows Terminal /
VS Code（深色背景）正常；用 `PI_HARDWARE_CURSOR=1` 或 Pi 设置 `showHardwareCursor: true` 就正常。

**原因（有实测证据，见 [docs/terminal-cursor.md](docs/terminal-cursor.md)）**：

1. Pi 用 `ESC[7m`（反显）画软件光标；
2. **ConPTY 的 console 属性模型里没有“反显”**，所以它会把它折算成显式颜色再发出去：
   `ESC[7m X ESC[27m` → `ESC[30m ESC[47m X ESC[m`（黑字 + **ANSI 白底**）；
3. 浅色主题把 `terminal.ansi.white` 映射成了和终端背景一样的白色（如 `VS Code Light 2026`：
   背景 `#FFFFFF`、`ansi.white` `#FFFFFF`）→ 白底空格 = 看不见。

**修法（选一）**：

```jsonc
// A. 推荐：让 Pi 用硬件光标（跑 pi 的那台机器的 %USERPROFILE%\.pi\agent\settings.json）
{ "showHardwareCursor": true }
```

```jsonc
// B. 或者让 ansi.white 跟背景可区分（Zed settings.json）
"experimental.theme_overrides": { "terminal.ansi.white": "#b0b0b0" }
```

- C. 换一个把 white 映射成灰色的浅色主题（Zed 内置 `One Light` 就是 `#fafafa` + `#bbbbbb`），
  或把终端背景改成深色。
- D. 这本质上是 ConPTY + 主题配色的问题，可以反馈给 Pi（Windows 下默认用硬件光标）或主题作者。

## 适用性

在以下环境实测通过（2026-09）：

- 客户端：Zed 1.20.2 on Windows（同样的流程也适用于 macOS/Linux 客户端）
- 远端：Windows 10 22H2（10.0.19045）x86_64，OpenSSH Server（默认 shell `pwsh.exe`）
- 远端 server：`zed-remote-server-windows-x86_64.zip` v1.20.2

## License

MIT
