#Requires -Version 5.1
<#
.SYNOPSIS
    Checks a zed-remote-fix installation on this Windows machine.

.DESCRIPTION
    Without -LiveTest the script only checks the files on disk and runs the shim's
    `version` check (the same check Zed performs before it uses the binary).

    With -LiveTest it also runs the shim the way Zed does
    (`<shim> proxy --identifier shim-selftest-<pid>`), verifies that the RPC handshake bytes
    come back on stdout and that the daemon logged "accepted new connections", and then
    cleans everything up again.

.EXAMPLE
    .\verify.ps1

.EXAMPLE
    .\verify.ps1 -LiveTest
#>
[CmdletBinding()]
param(
    [switch]$LiveTest,
    [int]$WaitSeconds = 8,
    [switch]$KeepState
)

$ErrorActionPreference = 'Stop'

$serverDir = Join-Path $env:USERPROFILE '.zed_server'
$realPath  = Join-Path $serverDir 'zed-remote-server-real.exe'

$script:failures = 0

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Ok($message)   { Write-Host "OK  $message" -ForegroundColor Green }
function Bad($message)  { Write-Host "FAIL $message" -ForegroundColor Red; $script:failures++ }
function Warn($message) { Write-Host "WARN $message" -ForegroundColor Yellow }

Step "checking $serverDir"

if (-not (Test-Path -LiteralPath $serverDir)) {
    Bad "$serverDir does not exist - connect once from Zed, then run install.ps1"
    exit 1
}

$existing = @(Get-ChildItem -LiteralPath $serverDir -Filter 'zed-remote-server-stable-*.exe' -File -ErrorAction SilentlyContinue)
$shims = @($existing | Where-Object { $_.Length -lt 5MB })
$officials = @($existing | Where-Object { $_.Length -gt 5MB })

if (-not (Test-Path -LiteralPath $realPath)) {
    Bad 'zed-remote-server-real.exe is missing (run install.ps1)'
} else {
    $realSize = [math]::Round((Get-Item -LiteralPath $realPath).Length / 1MB, 1)
    Ok "official binary present: zed-remote-server-real.exe ($realSize MB)"
}

if ($shims.Count -eq 0) {
    Bad 'no shim installed (no small zed-remote-server-stable-*.exe found) - run install.ps1'
    exit 1
}
if ($shims.Count -gt 1) {
    Warn "several shim-sized files found: $($shims.Name -join ', ')"
}
if ($officials.Count -gt 0) {
    Warn "a full-sized versioned binary also exists (Zed will use the newest name): $($officials.Name -join ', ')"
}

$shim = $shims | Sort-Object Length | Select-Object -First 1
Ok "shim installed as: $($shim.Name) ($($shim.Length) bytes)"

Step 'running the version check Zed uses'
$versionOut = & $shim.FullName version 2>&1
$versionExit = $LASTEXITCODE
if ($versionOut) { $versionOut | ForEach-Object { Write-Host "    $_" } }
if ($versionExit -eq 0) { Ok 'version check passed' } else { Bad "version check failed (exit code $versionExit)" }

if (-not $LiveTest) {
    Step 'result'
    if ($script:failures -eq 0) { Ok 'basic checks passed (use -LiveTest for the full protocol test)' }
    exit $script:failures
}

# ------------------------------------------------------------------ live protocol test
Step "live test: starting `"$($shim.Name) proxy`" like Zed does"

$id         = 'shim-selftest-' + $PID
$stateDir   = Join-Path $env:LOCALAPPDATA "Zed\server_state\$id"
$logFile    = Join-Path $env:LOCALAPPDATA "Zed\logs\server-$id.log"

function Stop-TestDaemon {
    param([string]$StateDir, [string]$Identifier)

    $daemonPid = 0
    $pidFile = Join-Path $StateDir 'server.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $parsed = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$parsed)) {
            $daemonPid = $parsed
            try { Stop-Process -Id $daemonPid -Force -ErrorAction Stop; Write-Host "    stopped daemon pid $daemonPid" } catch { }
        }
    }

    # also remove the proxy, its crash handler and the daemon's crash handler
    $patterns = @("*$Identifier*")
    if ($daemonPid -gt 0) { $patterns += "*crash-handler-$daemonPid*" }

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'zed-remote-server*' -and $_.CommandLine -and ($patterns | Where-Object { $_.CommandLine -like $_ }) } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $shim.FullName
$psi.Arguments              = "proxy --identifier $id"
$psi.WorkingDirectory       = $serverDir
$psi.UseShellExecute        = $false
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true

$process = [System.Diagnostics.Process]::Start($psi)
Write-Host "    proxy pid $($process.Id), waiting $WaitSeconds s ..."
Start-Sleep -Seconds $WaitSeconds

$handshakeBytes = -1
try {
    $buffer = New-Object byte[] 8192
    $handshakeBytes = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)
} catch {
    $handshakeBytes = -1
}

# stop the daemon first so the proxy's stdio pipes close and stderr can be read safely
Stop-TestDaemon -StateDir $stateDir -Identifier $id
if (-not $process.HasExited) { try { $process.Kill() } catch { } }
try { $process.WaitForExit(5000) | Out-Null } catch { }

$stderrText = ''
try { $stderrText = $process.StandardError.ReadToEnd() } catch { }
$logText = ''
if (Test-Path -LiteralPath $logFile) { $logText = Get-Content -LiteralPath $logFile -Raw }

if ($stderrText) {
    Write-Host '    shim / proxy stderr:'
    ($stderrText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 6 | ForEach-Object { Write-Host "      $_" }
}

if ($handshakeBytes -gt 0) { Ok "RPC handshake received on stdout ($handshakeBytes bytes)" }
else { Bad 'no RPC bytes received on stdout - the proxy could not reach the daemon' }

if ($logText -match 'starting up with PID') { Ok 'daemon logged "starting up"' } else { Bad 'daemon never logged "starting up" (see server log)' }
if ($logText -match 'accepted new connections') { Ok 'daemon accepted the proxy connection' } else { Bad 'daemon never accepted a connection' }

if (-not $KeepState) {
    Stop-TestDaemon -StateDir $stateDir -Identifier $id
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $logFile)  { Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue }
    Write-Host '    test state cleaned up'
} else {
    Write-Host "    kept state: $stateDir"
    Write-Host "    kept log  : $logFile"
}

Step 'result'
if ($script:failures -eq 0) {
    Ok 'all checks passed'
} else {
    Write-Host "$script:failures check(s) failed" -ForegroundColor Red
}
exit $script:failures
