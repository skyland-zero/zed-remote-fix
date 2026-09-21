#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles shim\shim.cs into shim.exe with the C# compiler that ships with Windows.

.EXAMPLE
    .\build.ps1

.EXAMPLE
    .\build.ps1 -Out C:\temp\shim.exe
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not $Source) { $Source = Join-Path $PSScriptRoot 'shim\shim.cs' }
if (-not $Out)    { $Out    = Join-Path $PSScriptRoot 'shim\shim.exe' }

if (-not (Test-Path -LiteralPath $Source)) { throw "shim source not found: $Source" }

function Get-Csc {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

$csc = Get-Csc
if (-not $csc) {
    throw 'csc.exe was not found. .NET Framework 4.x is required (it is part of Windows 10/11 by default).'
}

Write-Host "compiler : $csc"
Write-Host "source   : $Source"
Write-Host "output   : $Out"

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }

$output = & $csc /nologo /target:exe /platform:anycpu /out:"$Out" "$Source" 2>&1
$exitCode = $LASTEXITCODE
if ($output) { $output | ForEach-Object { Write-Host "  $_" } }

if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $Out)) {
    throw "compiling the shim failed (csc exit code $exitCode)"
}

$size = (Get-Item -LiteralPath $Out).Length
Write-Host ("OK: {0} ({1} bytes)" -f $Out, $size) -ForegroundColor Green
