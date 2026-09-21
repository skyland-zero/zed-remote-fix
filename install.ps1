#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or refreshes) the zed-remote-fix shim on this Windows machine, so that it can
    be used as a Zed remote-development host over SSH.

.DESCRIPTION
    Zed expects the remote server binary at

        %USERPROFILE%\.zed_server\zed-remote-server-stable-<full-version>.exe

    On Windows the binary Zed puts there cannot start its own daemon inside an SSH session
    (upstream issue https://github.com/zed-industries/zed/issues/58892), so this script
    installs a small launcher shim under that exact name and keeps the official binary next
    to it as zed-remote-server-real.exe.

    Run this script ON THE REMOTE (WINDOWS) MACHINE:
      * the first time the machine is set up, and
      * again after every Zed update, because the file name contains the version number.

.PARAMETER OfficialExe
    Path to the official remote server executable. Auto-detected when omitted.

.PARAMETER FullVersion
    Full Zed version string as it appears in the file name, e.g.
    '1.20.2+stable.360.7c451e694f3c52ee0aeb01d7e28b5fa18cd0ad2f'.
    Only needed when the official binary cannot be auto-detected.

.PARAMETER ShimSource
    Path to shim.cs. Auto-detected (shim\shim.cs next to this script) when omitted.

.PARAMETER CleanState
    Also stop a running remote server daemon and delete %LOCALAPPDATA%\Zed\server_state\*.

.PARAMETER SkipVerify
    Skip the `shim.exe version` self check at the end.

.PARAMETER KeepRunning
    Do not stop running remote server processes up front. By default the script stops them,
    because a running `proxy`/daemon keeps the installed binary locked and cannot be replaced
    (an open Zed remote window would have to be reconnected afterwards).

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -CleanState
#>
[CmdletBinding()]
param(
    [string]$OfficialExe,
    [string]$FullVersion,
    [string]$ShimSource,
    [switch]$CleanState,
    [switch]$SkipVerify,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'

$serverDir = Join-Path $env:USERPROFILE '.zed_server'
$realPath  = Join-Path $serverDir 'zed-remote-server-real.exe'
$backupDir = Join-Path $serverDir 'backup'
$repoUrl   = 'https://github.com/skyland-zero/zed-remote-fix'

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Ok($message)   { Write-Host "OK  $message" -ForegroundColor Green }
function Warn($message) { Write-Host "WARN $message" -ForegroundColor Yellow }
function Die($message)  { Write-Host "ERROR $message" -ForegroundColor Red; exit 1 }

function Stop-RemoteServerProcesses {
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'zed-remote-server*' })
    foreach ($process in $processes) {
        Write-Host "    stopping $($process.ProcessName) pid $($process.Id)"
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { Warn "could not stop pid $($process.Id)" }
    }
    if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    return $processes.Count
}

function Copy-FileWithRetry {
    param([string]$From, [string]$To)

    try {
        Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
        return
    } catch [System.IO.IOException] {
        Warn 'the target file is in use, stopping remote server processes and retrying'
        Stop-RemoteServerProcesses | Out-Null
        Start-Sleep -Milliseconds 500
        Copy-Item -LiteralPath $From -Destination $To -Force
    }
}

function Resolve-ShimSource {
    param([string]$Explicit)

    $candidates = @()
    if ($Explicit) { $candidates += $Explicit }
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot 'shim\shim.cs')
        $candidates += (Join-Path $PSScriptRoot 'shim.cs')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $url = 'https://raw.githubusercontent.com/skyland-zero/zed-remote-fix/main/shim/shim.cs'
    $tmp = Join-Path $env:TEMP 'zed-remote-fix-shim.cs'
    Warn "shim.cs not found locally, downloading $url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
        return $tmp
    } catch {
        Die "shim.cs not found and the download failed: $($_.Exception.Message)"
    }
}

Step "zed-remote-fix install on $env:COMPUTERNAME as $env:USERNAME"

if (-not (Test-Path -LiteralPath $serverDir)) {
    New-Item -ItemType Directory -Force -Path $serverDir | Out-Null
}
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

# ---------------------------------------------------------------- 1. compile the shim
$shimSourcePath = Resolve-ShimSource -Explicit $ShimSource
Ok "shim source : $shimSourcePath"

$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $csc) { Die 'csc.exe (.NET Framework 4.x) was not found on this machine' }

$shimExe = Join-Path $env:TEMP 'zed-remote-fix-shim.exe'
if (Test-Path -LiteralPath $shimExe) { Remove-Item -LiteralPath $shimExe -Force }

$compileOutput = & $csc /nologo /target:exe /platform:anycpu /out:"$shimExe" "$shimSourcePath" 2>&1
$compileExit = $LASTEXITCODE
if ($compileOutput) { $compileOutput | ForEach-Object { Write-Host "    $_" } }
if ($compileExit -ne 0 -or -not (Test-Path -LiteralPath $shimExe)) {
    Die "compiling the shim failed (csc exit code $compileExit)"
}
Ok ("compiled shim: {0} bytes" -f (Get-Item -LiteralPath $shimExe).Length)

# ------------------------------------------------- 2. find the official server binary
$existing = @(Get-ChildItem -LiteralPath $serverDir -Filter 'zed-remote-server-stable-*.exe' -File -ErrorAction SilentlyContinue)
$officialCandidates = @($existing | Where-Object { $_.Length -gt 5MB } | Sort-Object Length -Descending)
$hasReal = Test-Path -LiteralPath $realPath

$officialPath = $null
$versionedName = $null

if ($OfficialExe) {
    if (-not (Test-Path -LiteralPath $OfficialExe)) { Die "the file passed with -OfficialExe does not exist: $OfficialExe" }
    $officialPath = (Resolve-Path -LiteralPath $OfficialExe).Path
    $versionedName = Split-Path -Leaf $officialPath
} elseif ($officialCandidates.Count -gt 0) {
    $officialPath = $officialCandidates[0].FullName
    $versionedName = $officialCandidates[0].Name
} elseif ($FullVersion) {
    $versionedName = "zed-remote-server-stable-$FullVersion.exe"
    if ($hasReal) { $officialPath = $realPath }
    if (-not $officialPath) { Die "no official binary found in $serverDir; pass -OfficialExe" }
} elseif ($existing.Count -eq 1 -and $hasReal) {
    # already installed: the versioned file is our shim, real.exe holds the official binary
    $versionedName = $existing[0].Name
    $officialPath = $realPath
} else {
    Die @"
no official remote server binary found in $serverDir

How to get one:
  * connect once from Zed: it uploads the official binary to that folder even though the
    connection then fails, then run this script again, or
  * download https://github.com/zed-industries/zed/releases/download/v<version>/zed-remote-server-windows-x86_64.zip
    and pass the extracted remote_server.exe with -OfficialExe.
"@
}

Ok "official exe: $officialPath"
Ok "install as  : $versionedName"

# ------------------------------------------------------------- 3. install both files
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($officialPath -ne $realPath) {
    Copy-FileWithRetry -From $officialPath -To $realPath
    Ok 'official binary stored as zed-remote-server-real.exe'
} else {
    Ok 'official binary already stored as zed-remote-server-real.exe'
}

Copy-Item -LiteralPath $realPath -Destination (Join-Path $backupDir "official-$stamp.exe") -Force

if (-not $KeepRunning) {
    Step 'stopping running remote server processes (they lock the installed binary)'
    $stopped = Stop-RemoteServerProcesses
    if ($stopped -gt 0) { Ok "stopped $stopped process(es)" } else { Ok 'none were running' }
}

$installedPath = Join-Path $serverDir $versionedName
if (Test-Path -LiteralPath $installedPath) {
    $previous = Get-Item -LiteralPath $installedPath
    if ($previous.Length -gt 5MB) {
        Copy-Item -LiteralPath $installedPath -Destination (Join-Path $backupDir "official-$($previous.Name)-$stamp.exe") -Force
    }
}

Copy-FileWithRetry -From $shimExe -To $installedPath
Ok "shim installed as $versionedName"

# ------------------------------------------------------------------- 4. self check
if (-not $SkipVerify) {
    Step 'self check'
    $versionOut = & $installedPath version 2>&1
    $versionExit = $LASTEXITCODE
    if ($versionOut) { $versionOut | ForEach-Object { Write-Host "    $_" } }
    if ($versionExit -ne 0) { Die "the installed shim failed its 'version' check (exit code $versionExit)" }
    Ok 'the shim forwards to the official binary correctly'
}

# -------------------------------------------------------------- 5. optional cleanup
if ($CleanState) {
    Step 'cleaning remote server state'
    Get-Process -Name 'zed-remote-server-real' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "    stopping daemon pid $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500

    $stateRoot = Join-Path $env:LOCALAPPDATA 'Zed\server_state'
    if (Test-Path -LiteralPath $stateRoot) {
        Get-ChildItem -LiteralPath $stateRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Ok 'server_state cleaned'
}

# ------------------------------------------------------- 6. write an install manifest
$infoPath = Join-Path $serverDir 'zed-remote-fix-info.txt'
@(
    "installed_at    : $(Get-Date -Format o)"
    "host            : $env:COMPUTERNAME ($env:USERNAME)"
    "versioned_name  : $versionedName"
    "official_source : $officialPath"
    "shim_sha256     : $((Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash)"
    "official_sha256 : $((Get-FileHash -LiteralPath $realPath -Algorithm SHA256).Hash)"
    "source          : $repoUrl"
) | Set-Content -LiteralPath $infoPath -Encoding ASCII

Step 'done'
Write-Host @"

Next steps:
  1. Reconnect from Zed.
  2. If it still fails, run .\verify.ps1 -LiveTest and check
     %LOCALAPPDATA%\Zed\logs\server-*.log and Zed's own log (cmd-shift-p -> Open Log).
  3. Remember: after every Zed update run this script again, because the expected file
     name contains the Zed version.
"@
