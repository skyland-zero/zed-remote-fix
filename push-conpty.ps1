#Requires -Version 5.1
<#
.SYNOPSIS
    Pushes the modern ConPTY (conpty.dll + OpenConsole.exe) from this machine's Zed
    installation to a remote Windows host over SSH.

.DESCRIPTION
    See install-conpty.ps1 for the background. This is the convenient variant for people who
    only have Zed on the machine they connect FROM: it reads conpty.dll / <arch>\OpenConsole.exe
    from the local Zed installation and copies them into %USERPROFILE%\.zed_server on the
    remote host, next to the remote server binary.

    A new terminal has to be opened on the remote afterwards (conpty.dll is loaded whenever a
    pseudo console is created); no reconnect is needed.

.PARAMETER Remote
    SSH destination as you would type it for ssh/scp, e.g. "workpc" or "skyla@10.0.0.5".

.PARAMETER Source
    Local Zed installation directory. Auto-detected when omitted.

.EXAMPLE
    .\push-conpty.ps1 -Remote workpc

.EXAMPLE
    .\push-conpty.ps1 -Remote skyla@10.0.0.5 -Source "$env:LOCALAPPDATA\Programs\Zed"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Remote,
    [string]$Source
)

$ErrorActionPreference = 'Stop'

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Ok($message)   { Write-Host "OK  $message" -ForegroundColor Green }
function Die($message)  { Write-Host "ERROR $message" -ForegroundColor Red; exit 1 }

# Run a PowerShell snippet on the remote host without any shell quoting hazards.
function Invoke-RemotePowerShell {
    param([string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    & ssh $Remote "powershell -NoProfile -EncodedCommand $encoded"
}

function Resolve-SourceDir {
    param([string]$Explicit)

    $candidates = @()
    if ($Explicit) { $candidates += $Explicit }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Zed'),
        (Join-Path $env:ProgramFiles 'Zed'),
        (Join-Path ${env:ProgramFiles(x86)} 'Zed')
    )
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'conpty.dll')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-ArchName {
    param([string]$Architecture)

    switch ($Architecture) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { Die "unsupported remote architecture: $Architecture" }
    }
}

$sourceDir = Resolve-SourceDir -Explicit $Source
if (-not $sourceDir) {
    Die 'no Zed installation with conpty.dll found locally; pass -Source <dir>'
}
Ok "local Zed install: $sourceDir"
Ok "remote host      : $Remote"

Step 'detecting the remote architecture and user profile'
$remoteArch = (Invoke-RemotePowerShell '$env:PROCESSOR_ARCHITECTURE' 2>$null | Out-String).Trim()
$remoteHome = (Invoke-RemotePowerShell '$env:USERPROFILE' 2>$null | Out-String).Trim()
if (-not $remoteHome) { Die "could not query the remote host (architecture: '$remoteArch') - check your SSH connection" }

$arch = Get-ArchName -Architecture $remoteArch
Ok "remote home      : $remoteHome"
Ok "remote arch      : $arch"

$conptyLocal = Join-Path $sourceDir 'conpty.dll'
$openConsoleLocal = Join-Path $sourceDir "$arch\OpenConsole.exe"
if (-not (Test-Path -LiteralPath $openConsoleLocal)) {
    Die "$arch\OpenConsole.exe not found in $sourceDir"
}

$remoteDir = "$remoteHome/.zed_server".Replace('\', '/')
$remoteArchDir = "$remoteDir/$arch"
$remoteConpty = "$remoteDir/conpty.dll"
$remoteOpenConsole = "$remoteArchDir/OpenConsole.exe"

Step 'preparing the remote directory'
Invoke-RemotePowerShell "`$ProgressPreference='SilentlyContinue'; New-Item -ItemType Directory -Force -Path '$remoteArchDir' | Out-Null; 'ok'" | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'could not create the remote directory' }

Step 'copying files'
& scp -q $conptyLocal "$Remote`:$remoteConpty"
if ($LASTEXITCODE -ne 0) { Die 'copying conpty.dll failed' }
Ok "conpty.dll      -> $remoteConpty"

& scp -q $openConsoleLocal "$Remote`:$remoteOpenConsole"
if ($LASTEXITCODE -ne 0) { Die 'copying OpenConsole.exe failed' }
Ok "OpenConsole.exe -> $remoteOpenConsole"

Step 'verifying on the remote'
$verifyScript = 'Get-ChildItem $env:USERPROFILE\.zed_server -Recurse -Include conpty.dll,OpenConsole.exe | ForEach-Object { $_.FullName + ''  '' + $_.Length }'
Invoke-RemotePowerShell "`$ProgressPreference='SilentlyContinue'; $verifyScript"

Step 'done'
Write-Host @"

Now open a NEW terminal in the remote Zed window, then check on the remote:

    Get-Process OpenConsole -ErrorAction SilentlyContinue

If that lists a process, the modern ConPTY is in use.
"@
