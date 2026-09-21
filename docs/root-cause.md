# 根因分析

本文记录 **Zed 通过 SSH 连接 Windows 远端**失败的两个独立原因，以及本仓库的绕过方式。
所有代码引用来自 `zed-industries/zed`（2026-09，v1.20.x）。

---

## 现象

客户端（任意平台）连接 Windows 宿主时：

```
INFO  [remote::transport::ssh] Remote is windows: true
INFO  [remote::transport::ssh] Remote shell discovered: pwsh.exe
INFO  [remote::transport::ssh] Remote platform discovered: RemotePlatform { os: Windows, arch: X86_64 }
INFO  [remote::transport::ssh] Remote OS version discovered: Some("10.0.19045")
...
ERROR [remote::remote_client] failed to establish connection: Client exited with exit_code 1
ERROR [workspace::notifications] Client exited with exit_code 1
```

大约 60 秒超时。上游 issue：<https://github.com/zed-industries/zed/issues/58892>

---

## 原因 A：daemon 根本启动不了（上游 bug，主因）

Zed 在 Windows 上启动远端 daemon 的代码在
`crates/remote_server/src/server.rs` → `spawn_server()`：

```rust
#[cfg(windows)]
fn spawn_server_windows(binary_name: &Path, paths: &ServerPaths) -> Result<(), SpawnServerError> {
    ...
    crate::windows::shell_execute_from_explorer(&binary_path, &parameters, &directory)
        .map_err(|e| SpawnServerError::ProcessStatus(std::io::Error::other(e)))?;
    Ok(())
}
```

`crates/remote_server/src/windows.rs::shell_execute_from_explorer()` 通过 COM 拿 Explorer 的
`IShellDispatch2` 再 `ShellExecute`，即「让资源管理器帮忙启动进程」：

```rust
let shell_dispatch: IShellDispatch2 =
    CoCreateInstance::<_, IShellWindows>(&ShellWindows, None, CLSCTX_LOCAL_SERVER)?
        .FindWindowSW(...)?            // ← 在 SSH 会话里这一步失败
        ...
```

SSH 会话没有交互式桌面（session 0 隔离、没有 Explorer 窗口），`CoCreateInstance` /
`FindWindowSW` 直接失败：

```
Access is denied. (0x80070005)
```

结果：

- daemon 从未启动 → 远端 **连 `server-<identifier>.log` 都不会生成**；
- `proxy` 去连 stdin/stdout/stderr socket 失败 → 进程以 1 退出；
- 客户端等 60 秒后报 `Client exited with exit_code 1`。

> 为什么上游用 ShellExecute？大概是想让 daemon 落在用户的交互式会话里（脱离 sshd 的
> job object，并具备桌面环境）。但这在 SSH-only 场景下恰恰不可用。

**本仓库的做法**：在 Zed 期望的文件名处放一个 launcher，用
`CreateProcess(..., CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS, ...)`
自己把 daemon 拉起来（失败时逐级退化到更保守的 flag 组合），效果与 ShellExecute 想达到的
「脱离 SSH 会话的 job object」相同，但不需要桌面。

---

## 原因 B：僵尸 socket 文件（shim 早期版本的坑，已修）

`crates/remote_server/src/server.rs`：

```rust
struct ServerListeners { stdin: UnixListener, stdout: UnixListener, stderr: UnixListener }

impl ServerListeners {
    pub fn new(stdin_path: PathBuf, stdout_path: PathBuf, stderr_path: PathBuf) -> Result<Self> {
        Ok(Self {
            stdin: UnixListener::bind(stdin_path).context("failed to bind stdin socket")?,
            ...
```

daemon 的 IPC 是 `%LOCALAPPDATA%\Zed\server_state\<identifier>\{stdin,stdout,stderr}.sock`。
Windows 从 1803 起支持 AF_UNIX，但 **socket 文件的语义和文件系统文件一样：属主进程死了，
文件仍然留在磁盘上**。下一次 `bind()` 到同一个路径会失败（Windows: `WSAEADDRINUSE`），
daemon 只写完 `server.pid` 就退出。

客户端侧的 `execute_proxy()` 已有一半防护：

```rust
let server_pid = check_pid_file(&server_paths.pid_file)?;   // pid 不存在时只删 pid 文件
if is_reconnecting {
    ...
} else if let Some(pid) = server_pid {
    kill_running_server(pid, &server_paths)?;               // 只有 pid 活着才清理 socket
}
gpui::block_on(spawn_server(&server_paths))?;                // 这里也会删掉旧 socket
```

但**当 daemon 已经死掉（pid 文件是死的）时，socket 文件不会被删**。上游
`spawn_server()` 自己会删（所以上游路径通常没问题），而我们的 shim 直接调 `run`
子命令，绕过了 `spawn_server()`，于是踩到了这个坑。

典型日志：

```
ERROR [remote_server] (remote proxy) encountered error while forwarding messages:
      stdin_task failed: Failed to connect to stdin socket
      C:\Users\<user>\AppData\Local\Zed\server_state\setup-1\stdin.sock:
      由于目标计算机积极拒绝，无法连接。 (os error 10061)
ERROR [remote_server] (remote proxy) server exited unexpectedly
```

**修复**（`shim/shim.cs` 中 `EnsureDaemon()`）：

1. daemon 没在跑时，把 `server.pid` 与三个 `.sock` 一起删掉再启动；
2. 等待条件从「文件存在」改成「文件存在 **且** pid 文件里的进程真的活着」；
3. 之后再等 200 ms，让 `listen()` 完成；
4. `DaemonRunning()` 校验进程名必须是 `zed-remote-server*`，防止 PID 复用误判。

---

## 附带发现：`check_pid_file` 的 PID 复用风险（值得上游修）

`crates/remote_server/src/server.rs`：

```rust
fn check_pid_file(path: &Path) -> Result<Option<u32>, CheckPidError> { ... }

fn kill_running_server(pid: u32, paths: &ServerPaths) -> Result<(), ExecuteProxyError> {
    ...
    if let Some(process) = system.process(sysinfo::Pid::from_u32(pid)) {
        let killed = process.kill();     // ← 只要这个 PID 存在就杀
```

`check_pid_file` 只判断「这个 PID 是否存在」，没有校验进程身份。Windows 上 PID 会被快速
复用，于是：

- 老 daemon 死掉 → `server.pid` 残留；
- 若干次进程创建后，同一个 PID 被无关进程占用；
- 下一次连接时 `check_pid_file` 返回 `Some(pid)`，`kill_running_server` 就可能
  **杀掉一个完全无关的进程**。

shim 用进程名前缀校验规避了这个问题（`DaemonRunning()`）。

---

## 上游代码索引

| 位置 | 作用 |
| --- | --- |
| `crates/remote_server/src/windows.rs` | `shell_execute_from_explorer()` — 原因 A |
| `crates/remote_server/src/server.rs` `spawn_server_windows()` | 调用上面那个函数 |
| `crates/remote_server/src/server.rs` `ServerListeners::new()` | AF_UNIX bind — 原因 B |
| `crates/remote_server/src/server.rs` `execute_proxy()` | proxy 主流程、`--reconnect` 语义 |
| `crates/remote_server/src/server.rs` `check_pid_file()` / `kill_running_server()` | PID 复用风险 |
| `crates/remote/src/transport/ssh.rs` | 客户端：平台探测、二进制下载/上传、`version` 校验 |

## 观测到的证据（一次真实故障）

远端 `.zed_server` 与 `server_state` 的状态：

```
setup-1:
  server.pid     2026/9/21 16:36:46     ← 新 daemon 写下的，PID 已死
  stdin.sock     2026/9/21 14:57:05     ← 14:57 那个 daemon 的僵尸文件
  stdout.sock    2026/9/21 14:57:05
  stderr.sock    2026/9/21 14:57:05
```

`server-setup-1.log` 的最后两行：

```
(remote server) starting up with PID 17372:  ... 16:36:46
（此后再无任何日志：bind 失败后进程直接退出）
```

客户端日志：

```
16:36:47 ERROR [remote_server] (remote proxy) ... Failed to connect to stdin socket ... (os error 10061)
16:36:47 ERROR [remote_server] (remote proxy) server exited unexpectedly
16:37:46 ERROR [remote::remote_client] failed to establish connection: Client exited with exit_code 1
```
