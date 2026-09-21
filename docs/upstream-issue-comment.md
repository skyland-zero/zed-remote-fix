# Draft comment for zed-industries/zed#58892

Not posted anywhere yet — copy/paste (and trim) as you like.

---

Confirming this with a root-cause analysis, plus a workaround that makes Windows-over-SSH remote
development work today.

## Why it hangs at "Starting proxy"

The client gets all the way through the handshake (`Remote is windows: true`, shell/arch detection,
`Remote OS version discovered`), so the failure is purely on the daemon-launch side.

`crates/remote_server/src/server.rs` → `spawn_server()` → `spawn_server_windows()` →
`crates/remote_server/src/windows.rs::shell_execute_from_explorer()`:

```rust
let shell_dispatch: IShellDispatch2 =
    CoCreateInstance::<_, IShellWindows>(&ShellWindows, None, CLSCTX_LOCAL_SERVER)?
        .FindWindowSW(...)?
```

This asks the *interactive* Explorer session to launch the process. In an SSH session there is no
interactive desktop / no Explorer window (session 0 isolation), and the call fails with
`Access is denied. (0x80070005)`. Consequences:

* the daemon never starts, so the remote side does not even create `server-<id>.log`;
* `proxy` cannot connect to the stdio sockets and exits with code 1;
* ~60 s later the client reports `Client exited with exit_code 1`.

Because `shell_execute_from_explorer()` already returns a `Result`, a plain fallback spawn would be
enough: a `CreateProcess` with `CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP |
DETACHED_PROCESS` (and progressively weaker flag sets if the job does not allow breakaway) starts the
daemon fine from inside an SSH session and also detaches it from sshd's job object. We verified this
on Windows 10 22H2 with the official `zed-remote-server-windows-x86_64` binary:

```
$ <official-server>.exe version
1.20.2
$ <launcher> proxy --identifier test      # launcher = CreateProcess(breakaway) + stdio forwarding
<stdout> 41 bytes of RPC frames
%LOCALAPPDATA%\Zed\logs\server-test.log:
  (remote server) starting up with PID ...
  (remote server) accepting new connections
  (remote server) accepted new connections
```

## A second, independent failure mode: stale AF_UNIX socket files

`ServerListeners::new()` binds `server_state/<identifier>/{stdin,stdout,stderr}.sock` without removing
a stale path first. On Windows an AF_UNIX socket file outlives its owner just like on Unix, so after a
daemon dies (crash, logout, killed sshd session) the next `run` fails to bind and exits right after
logging `starting up with PID ...`. The proxy then reports:

```
(remote proxy) ... Failed to connect to stdin socket ...: 由于目标计算机积极拒绝，无法连接。 (os error 10061)
(remote proxy) server exited unexpectedly
```

`spawn_server()` does delete the sockets before spawning (in the non-reconnect path), but
`check_pid_file()` returns `None` for a dead PID and only removes the *pid* file, so anyone talking to
the daemon directly (or a partially failed spawn) is left with the stale sockets. Deleting
`%LOCALAPPDATA%\Zed\server_state\<id>` "fixes" it, which matches the workaround other people reported
in this thread.

## Smaller issue in the same area: `check_pid_file()` can kill an unrelated process

`check_pid_file()` only checks that *some* process with the recorded PID exists, and
`kill_running_server()` then kills it. PIDs are recycled on Windows, so a stale `server.pid` can make
the client kill an unrelated process. Checking the process name (or a start-time/id token) before
killing would be safer.

## Workaround we use today

<https://github.com/skyland-zero/zed-remote-fix> — a ~10 KB launcher installed under the file name Zed
expects (`%USERPROFILE%\.zed_server\zed-remote-server-stable-<version>.exe`) next to the untouched
official binary. It cleans stale pid/socket files, starts the daemon with a breakaway `CreateProcess`,
and forwards stdio to the real binary's `proxy --reconnect` mode. No client changes, no forked Zed.
Caveat: the file name embeds the Zed version, so it has to be re-installed after each Zed update.

Happy to turn this into a PR (fallback in `spawn_server_windows()` + stale-socket cleanup) if that is
the direction you prefer; I can also just leave the shim here as a community workaround.
