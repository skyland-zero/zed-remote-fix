#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the zed-remote-fix shim from this Windows machine and restores the untouched
    official remote server binary.

.DESCRIPTION
    After this script runs, %USERPROFILE%\.zed_server contains the official binary under the
    versioned name again. Zed remote development into Windows will go back to failing inside
    an SSH session, but nothing of ours is left behind.

.PARAMETER CleanState
    Also stop a running remote server daemon and delete %LOCALAPPDATA%\Zed\server_state\*.

.PARAMETER Purge
    Delete the whole .zed_server directory (Zed will upload the official binary again on the
    next connection attempt). Implies -CleanState.

.EXAMPLE
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch]$CleanState,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$serverDir = Join-Path $env:USERPROFILE '.zed_server'
$realPath  = Join-Path $serverDir 'zed-remote-server-real.exe'

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Ok($message)   { Write-Host "OK  $message" -ForegroundColor Green }
function Die($message)  { Write-Host "ERROR $message" -ForegroundColor Red; exit 1 }

function Stop-RemoteServerProcesses {
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'zed-remote-server*' })
    foreach ($process in $processes) {
        Write-Host "    stopping $($process.ProcessName) pid $($process.Id)"
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }
    if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

function Copy-FileWithRetry {
    param([string]$From, [string]$To)

    try {
        Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
    } catch [System.IO.IOException] {
        Write-Host 'WARN the target file is in use, stopping remote server processes and retrying' -ForegroundColor Yellow
        Stop-RemoteServerProcesses
        Start-Sleep -Milliseconds 500
        Copy-Item -LiteralPath $From -Destination $To -Force
    }
}

function Install-File {
    param([string]$From, [string]$To, [string]$Label)

    try {
        Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
        return
    } catch [System.IO.IOException] {
        # A running shim keeps the file locked; a running executable can be renamed on
        # Windows 10 1703+, which avoids killing the user's remote session.
        Write-Host "WARN $Label is in use; moving it aside" -ForegroundColor Yellow
        try {
            $aside = "$To.in-use-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Move-Item -LiteralPath $To -Destination $aside -Force -ErrorAction Stop
            Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
            return
        } catch {
            Write-Host "WARN in-place replacement failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Stop-RemoteServerProcesses
        Start-Sleep -Milliseconds 500
        Copy-Item -LiteralPath $From -Destination $To -Force
    }
}

function Clear-ServerState {
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

Step 'zed-remote-fix uninstall'

if ($Purge) {
    if (Test-Path -LiteralPath $serverDir) {
        Remove-Item -LiteralPath $serverDir -Recurse -Force
        Ok "deleted $serverDir"
    }
    Clear-ServerState
    Step 'done - the next Zed connection will upload the official server binary again'
    exit 0
}

if (-not (Test-Path -LiteralPath $realPath)) {
    Die "zed-remote-server-real.exe was not found - nothing to restore (use -Purge to wipe $serverDir)"
}

$existing = @(Get-ChildItem -LiteralPath $serverDir -Filter 'zed-remote-server-stable-*.exe' -File -ErrorAction SilentlyContinue)
$shims = @($existing | Where-Object { $_.Length -lt 5MB })

if ($shims.Count -eq 0) {
    Die 'no shim is installed (no small zed-remote-server-stable-*.exe found)'
}

Stop-RemoteServerProcesses

foreach ($shim in $shims) {
    Install-File -From $realPath -To $shim.FullName -Label $shim.Name
    Ok "restored official binary over $($shim.Name)"
}

if ($CleanState) { Clear-ServerState }

$infoPath = Join-Path $serverDir 'zed-remote-fix-info.txt'
if (Test-Path -LiteralPath $infoPath) { Remove-Item -LiteralPath $infoPath -Force }

Step 'done'
Write-Host @"

The machine now behaves like a plain (unpatched) Zed Windows remote host again.
Backups of the official binary are still in $serverDir\backup if you need them.
"@
