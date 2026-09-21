// zed-remote-fix — a launcher shim for Zed's Windows remote-development server.
//
// WHY THIS EXISTS
//   Zed's own spawn_server() on Windows starts the remote server daemon through Explorer's
//   ShellExecute (crates/remote_server/src/windows.rs -> shell_execute_from_explorer()).
//   Inside an SSH session that COM call fails with "Access is denied. (0x80070005)"
//   (session 0 isolation), so no daemon is ever started and the client ends up with
//   "Failed to connect over SSH - Client exited with exit_code 1".
//   Upstream issue: https://github.com/zed-industries/zed/issues/58892
//
// WHAT THIS SHIM DOES
//   It is installed under the exact file name Zed expects
//   (zed-remote-server-stable-<version>.exe) next to the untouched official binary
//   (zed-remote-server-real.exe). When Zed runs `proxy --identifier <id>`:
//     1. removes stale pid/socket files left behind by a dead daemon
//        (a Windows AF_UNIX socket file outlives its owner and makes `bind` fail),
//     2. starts `zed-remote-server-real.exe run ...` detached from the SSH job object
//        (CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS) and
//        waits until it really accepts connections,
//     3. runs the real binary in `proxy --reconnect` mode with stdio forwarded, so Zed's
//        RPC protocol works unchanged.
//   Any other invocation (e.g. `version`) is forwarded verbatim to the real binary.
//
// BUILD:  see ../build.ps1  (uses the csc.exe that ships with Windows/.NET Framework)
// INSTALL: see ../install.ps1
// LICENSE: MIT
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class ZedRemoteShim
{
    private const string RealBinaryName = "zed-remote-server-real.exe";

    private const int CreateNewProcessGroup = 0x00000200;
    private const int CreateDetachedProcess = 0x00000008;
    private const int CreateBreakawayFromJob = 0x01000000;
    private const int StartupUseStdHandles = 0x00000100;
    private const uint DuplicateSameAccess = 0x00000002;
    private const uint Infinite = 0xFFFFFFFF;
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, int dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref StartupInfo lpStartupInfo, out ProcessInformation lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(IntPtr hSourceProcessHandle, IntPtr hSourceHandle, IntPtr hTargetProcessHandle, out IntPtr lpTargetHandle, uint dwDesiredAccess, bool bInheritHandle, uint dwOptions);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll")]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr hObject);

    private static int Main(string[] argv)
    {
        string dir = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
        string realPath = Path.Combine(dir, RealBinaryName);
        if (!File.Exists(realPath))
        {
            Console.Error.WriteLine("zed shim: real server binary not found: " + realPath);
            return 1;
        }

        string[] forwarded = argv;
        if (argv.Length > 0 && string.Equals(argv[0], "proxy", StringComparison.OrdinalIgnoreCase))
        {
            string identifier = GetOption(argv, "--identifier");
            if (identifier != null && identifier.Length > 0)
            {
                EnsureDaemon(realPath, identifier, dir);
                if (!HasFlag(argv, "--reconnect"))
                {
                    forwarded = Append(argv, "--reconnect");
                }
            }
        }

        return RunChild(realPath, forwarded, dir);
    }

    private static void EnsureDaemon(string realPath, string identifier, string workingDirectory)
    {
        string zedDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zed");
        string stateDir = Path.Combine(zedDir, "server_state", identifier);
        string logsDir = Path.Combine(zedDir, "logs");
        Directory.CreateDirectory(stateDir);
        Directory.CreateDirectory(logsDir);

        string pidFile = Path.Combine(stateDir, "server.pid");
        string stdinSocket = Path.Combine(stateDir, "stdin.sock");
        string stdoutSocket = Path.Combine(stateDir, "stdout.sock");
        string stderrSocket = Path.Combine(stateDir, "stderr.sock");
        string logFile = Path.Combine(logsDir, "server-" + identifier + ".log");

        if (DaemonRunning(pidFile))
        {
            return;
        }

        // The previous daemon is gone, but on Windows an AF_UNIX socket file
        // stays on disk after its owner dies, and binding to a stale path
        // fails. Remove the leftovers before spawning a fresh daemon.
        if (File.Exists(pidFile) || File.Exists(stdinSocket) || File.Exists(stdoutSocket) || File.Exists(stderrSocket))
        {
            Console.Error.WriteLine("zed shim: removing stale daemon state in " + stateDir);
        }
        TryDelete(pidFile);
        TryDelete(stdinSocket);
        TryDelete(stdoutSocket);
        TryDelete(stderrSocket);

        string arguments = "run"
            + " --log-file \"" + logFile + "\""
            + " --pid-file \"" + pidFile + "\""
            + " --stdin-socket \"" + stdinSocket + "\""
            + " --stdout-socket \"" + stdoutSocket + "\""
            + " --stderr-socket \"" + stderrSocket + "\"";

        if (!StartDetached(realPath, arguments, workingDirectory))
        {
            Console.Error.WriteLine("zed shim: failed to start remote server daemon");
            return;
        }

        for (int waited = 0; waited < 15000; waited += 50)
        {
            if (File.Exists(stdinSocket) && File.Exists(stdoutSocket) && File.Exists(stderrSocket) && DaemonRunning(pidFile))
            {
                // Give the daemon a moment to finish listen() before the proxy dials in.
                Thread.Sleep(200);
                return;
            }
            Thread.Sleep(50);
        }
        Console.Error.WriteLine("zed shim: timed out waiting for daemon to accept connections");
    }

    private static bool DaemonRunning(string pidFile)
    {
        try
        {
            if (!File.Exists(pidFile))
            {
                return false;
            }
            int pid;
            if (!int.TryParse(File.ReadAllText(pidFile).Trim(), out pid) || pid <= 0)
            {
                return false;
            }
            Process process = Process.GetProcessById(pid);
            if (process.HasExited)
            {
                return false;
            }
            // Guard against a recycled pid: the daemon must be our server binary.
            string name = process.ProcessName;
            return name != null && name.StartsWith("zed-remote-server", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static bool StartDetached(string exePath, string arguments, string workingDirectory)
    {
        int[] flagCandidates = new int[]
        {
            CreateDetachedProcess | CreateNewProcessGroup | CreateBreakawayFromJob,
            CreateDetachedProcess | CreateNewProcessGroup,
            CreateNewProcessGroup,
            0
        };

        foreach (int flags in flagCandidates)
        {
            StartupInfo startup = new StartupInfo();
            startup.cb = Marshal.SizeOf(typeof(StartupInfo));
            ProcessInformation info;
            string commandLine = Quote(exePath) + " " + arguments;
            if (CreateProcess(exePath, commandLine, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory, ref startup, out info))
            {
                CloseHandle(info.hThread);
                CloseHandle(info.hProcess);
                return true;
            }
        }
        return false;
    }

    private static int RunChild(string exePath, string[] argv, string workingDirectory)
    {
        IntPtr stdinHandle = MakeInheritableHandle(StdInputHandle);
        IntPtr stdoutHandle = MakeInheritableHandle(StdOutputHandle);
        IntPtr stderrHandle = MakeInheritableHandle(StdErrorHandle);

        StartupInfo startup = new StartupInfo();
        startup.cb = Marshal.SizeOf(typeof(StartupInfo));
        startup.dwFlags = StartupUseStdHandles;
        startup.hStdInput = stdinHandle;
        startup.hStdOutput = stdoutHandle;
        startup.hStdError = stderrHandle;

        ProcessInformation info;
        string commandLine = Quote(exePath) + " " + JoinArguments(argv);
        if (!CreateProcess(exePath, commandLine, IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, workingDirectory, ref startup, out info))
        {
            Console.Error.WriteLine("zed shim: failed to start " + exePath + " (win32 error " + Marshal.GetLastWin32Error() + ")");
            return 1;
        }

        CloseHandle(info.hThread);
        WaitForSingleObject(info.hProcess, Infinite);
        uint exitCode;
        GetExitCodeProcess(info.hProcess, out exitCode);
        CloseHandle(info.hProcess);
        CloseHandle(stdinHandle);
        CloseHandle(stdoutHandle);
        CloseHandle(stderrHandle);
        return unchecked((int)exitCode);
    }

    private static IntPtr MakeInheritableHandle(int stdHandle)
    {
        IntPtr source = GetStdHandle(stdHandle);
        if (source == IntPtr.Zero || source == new IntPtr(-1))
        {
            return source;
        }
        IntPtr target;
        if (DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(), out target, 0, true, DuplicateSameAccess))
        {
            return target;
        }
        return source;
    }

    private static string GetOption(string[] argv, string name)
    {
        for (int i = 0; i < argv.Length; i++)
        {
            if (string.Equals(argv[i], name, StringComparison.OrdinalIgnoreCase) && i + 1 < argv.Length)
            {
                return argv[i + 1];
            }
            string prefix = name + "=";
            if (argv[i].StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return argv[i].Substring(prefix.Length);
            }
        }
        return null;
    }

    private static bool HasFlag(string[] argv, string name)
    {
        foreach (string arg in argv)
        {
            if (string.Equals(arg, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private static string[] Append(string[] argv, string extra)
    {
        string[] result = new string[argv.Length + 1];
        Array.Copy(argv, result, argv.Length);
        result[argv.Length] = extra;
        return result;
    }

    private static string JoinArguments(string[] argv)
    {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < argv.Length; i++)
        {
            if (i > 0)
            {
                builder.Append(' ');
            }
            builder.Append(Quote(argv[i]));
        }
        return builder.ToString();
    }

    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOf(' ') < 0 && value.IndexOf('\t') < 0 && value.IndexOf('"') < 0)
        {
            return value;
        }

        StringBuilder builder = new StringBuilder();
        builder.Append('"');
        for (int i = 0; i < value.Length; i++)
        {
            int backslashes = 0;
            while (i < value.Length && value[i] == '\\')
            {
                backslashes++;
                i++;
            }
            if (i == value.Length)
            {
                builder.Append('\\', backslashes * 2);
                break;
            }
            if (value[i] == '"')
            {
                builder.Append('\\', backslashes * 2 + 1);
                builder.Append('"');
            }
            else
            {
                builder.Append('\\', backslashes);
                builder.Append(value[i]);
            }
        }
        builder.Append('"');
        return builder.ToString();
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }
}
