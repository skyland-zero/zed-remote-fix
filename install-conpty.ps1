#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the modern ConPTY (conpty.dll + OpenConsole.exe) next to Zed's remote server
    binary on this Windows machine, so remote terminals behave like local ones.

.DESCRIPTION
    Problem
      A Zed Windows remote host is installed from the release zip, which contains only
      remote_server.exe. The local Zed installation, by contrast, ships Windows Terminal's
      ConPTY (conpty.dll + x64\OpenConsole.exe / arm64\OpenConsole.exe).

      Zed's terminal code (alacritty_terminal -> ConptyApi::load_conpty) does
      LoadLibrary("conpty.dll") and otherwise falls back to the in-box Windows ConPTY
      ("Using Windows API for pseudoconsole"). The in-box implementation is older and has
      known rendering bugs, which show up as e.g. a missing cursor in full-screen TUI apps
      (pi, vim, htop, ...) or general display corruption.

    Fix
      Copy conpty.dll and <arch>\OpenConsole.exe into %USERPROFILE%\.zed_server, next to
      zed-remote-server-real.exe. conpty.dll is loaded every time a pseudo console is
      created, so only a NEW terminal is needed - no restart, no reconnect.

.PARAMETER Source
    Directory that contains conpty.dll and <arch>\OpenConsole.exe, normally the client's Zed
    installation (e.g. C:\Users\<you>\AppData\Local\Programs\Zed).

.EXAMPLE
    .\install-conpty.ps1 -Source "$env:LOCALAPPDATA\Programs\Zed"

.EXAMPLE
    # auto-detect the Zed installation on this machine
    .\install-conpty.ps1
#>
[CmdletBinding()]
param(
    [string]$Source
)

$ErrorActionPreference = 'Stop'

$serverDir = Join-Path $env:USERPROFILE '.zed_server'

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Ok($message)   { Write-Host "OK  $message" -ForegroundColor Green }
function Die($message)  { Write-Host "ERROR $message" -ForegroundColor Red; exit 1 }

function Get-ArchName {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    switch ($architecture) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { Die "unsupported processor architecture: $architecture" }
    }
}

function Resolve-SourceDir {
    param([string]$Explicit)

    $candidates = @()
    if ($Explicit) { $candidates += $Explicit }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Zed'),
        (Join-Path $env:ProgramFiles 'Zed'),
        (Join-Path ${env:ProgramFiles(x86)} 'Zed'),
        (Join-Path $env:LOCALAPPDATA 'Zed')
    )

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ((Test-Path -LiteralPath (Join-Path $candidate 'conpty.dll')) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'x64\OpenConsole.exe'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $serverDir)) {
    Die "$serverDir does not exist - connect once from Zed first (or run install.ps1)"
}

$arch = Get-ArchName
$sourceDir = Resolve-SourceDir -Explicit $Source
if (-not $sourceDir) {
    Die @"
could not find a directory with conpty.dll + x64\OpenConsole.exe

Pass it explicitly, usually the Zed installation on the machine you connect FROM:
    .\install-conpty.ps1 -Source 'C:\Users\<you>\AppData\Local\Programs\Zed'
or download the Windows Terminal MSIX / the zed-remote-server zip that contains them.
"@
}

Ok "source     : $sourceDir"
Ok "target     : $serverDir"
Ok "architecture: $arch"

$conptySource = Join-Path $sourceDir 'conpty.dll'
$openConsoleSource = Join-Path $sourceDir "$arch\OpenConsole.exe"
if (-not (Test-Path -LiteralPath $openConsoleSource)) {
    Die "$arch\OpenConsole.exe not found in $sourceDir"
}

Step 'copying files'
Copy-Item -LiteralPath $conptySource -Destination (Join-Path $serverDir 'conpty.dll') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $serverDir $arch) | Out-Null
Copy-Item -LiteralPath $openConsoleSource -Destination (Join-Path $serverDir "$arch\OpenConsole.exe") -Force

Get-ChildItem -LiteralPath $serverDir -Recurse -File |
    Where-Object { $_.Name -in @('conpty.dll', 'OpenConsole.exe') } |
    ForEach-Object { Ok ("{0}  ({1} bytes)" -f $_.FullName, $_.Length) }

Step 'done'
Write-Host @"

Now open a NEW terminal in the remote Zed window (the DLL is loaded for every new pseudo
console). To confirm it is in use, look for an OpenConsole.exe process on this machine:

    Get-Process OpenConsole -ErrorAction SilentlyContinue

and in Zed's log (ctrl-shift-p -> Open Log) for:

    alacritty_terminal::tty::windows::conpty  Using conpty.dll for pseudoconsole
"@
