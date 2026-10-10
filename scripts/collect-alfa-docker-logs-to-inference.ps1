#Requires -Version 5.1
# Windows wrapper for scripts/collect-alfa-docker-logs-to-148.sh (Git Bash only).
#
# Usage (PowerShell):
#   .\scripts\collect-alfa-docker-logs-to-148.ps1
#   .\scripts\collect-alfa-docker-logs-to-148.ps1 -NoScp
#
# Does NOT use C:\Windows\System32\bash.exe (WSL stub). See LOG_CAPTURE_RUNBOOK.md.
param(
    [switch]$NoScp
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

function Test-IsWslBashStub {
    param([string]$Path)
    return $Path -match '\\Windows\\System32\\bash\.exe$|\\Windows\\SysWOW64\\bash\.exe$'
}

function Find-GitBashExe {
    $try = @(
        (Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path ${env:LocalAppData} 'Programs\Git\bin\bash.exe'),
        'C:\Program Files\Git\bin\bash.exe',
        (Join-Path ${env:ProgramFiles} 'Git\usr\bin\bash.exe')
    )
    foreach ($p in $try) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd -and $gitCmd.Source) {
        $gitBin = Split-Path -Parent $gitCmd.Source
        $gitRoot = Split-Path -Parent $gitBin
        foreach ($rel in @('bin\bash.exe', 'usr\bin\bash.exe')) {
            $p = Join-Path $gitRoot $rel
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
  return $null
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BashSh = Join-Path $RepoRoot 'scripts\collect-alfa-docker-logs-to-148.sh'

if (-not (Test-Path -LiteralPath $BashSh)) {
    Write-Error "Missing $BashSh. Run: git restore scripts/collect-alfa-docker-logs-to-148.sh"
    exit 1
}

$BashExe = Find-GitBashExe
if (-not $BashExe) {
    Write-Error @"
Git Bash not found (refusing Windows\System32\bash.exe WSL stub).
Install Git for Windows, or run manually:
  & 'C:\Program Files\Git\bin\bash.exe' '$BashSh'
"@
    exit 1
}

if (Test-IsWslBashStub -Path $BashExe) {
    Write-Error "Resolved bash is the WSL stub: $BashExe. Use Git for Windows bash.exe."
    exit 1
}

$env:SCP_TO_BUILD_HOST = if ($NoScp) { '0' } else { '1' }

Write-Host "Repo:  $RepoRoot" -ForegroundColor Cyan
Write-Host "Bash:  $BashExe" -ForegroundColor Cyan
Write-Host "SCP:   $($env:SCP_TO_BUILD_HOST)" -ForegroundColor Cyan

& $BashExe $BashSh
exit $LASTEXITCODE
