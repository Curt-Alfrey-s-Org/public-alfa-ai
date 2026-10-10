#Requires -Version 5.1
<#
.SYNOPSIS
    Full gaming-a startup: deploy + portproxy + post-startup gate (one command).

.DESCRIPTION
    Chains:
      1. git pull
      2. SSH key preflight (warn if log upload will skip)
      3. Win10 portproxy sync (before + after deploy)
      4. build-start-gaming-worker-a-219.ps1
      5. run-post-startup-status-with-log.ps1 -WarmUpSec 180

    Run as normal user (Corey). Portproxy uses elevated scheduled task when needed.

.EXAMPLE
    cd C:\Users\Corey\alfa-ai
    git pull --ff-only origin main
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\startup-gaming-worker-a-219.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$SkipDeploy,
    [switch]$SkipPostStartup,
    [switch]$SkipLogUpload,
    [switch]$ForceBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MemberDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $MemberDir '..\..\..')).Path
$CommonDir = Join-Path $MemberDir '..\_common'

. (Join-Path $MemberDir 'Initialize-GamingWorkerCache.ps1')
Initialize-GamingWorkerWindowsCache | Out-Null

Write-Host ''
Write-Host '== ALFa startup: gaming-worker-a-219 (gaming-a Win10) ==' -ForegroundColor Cyan
Write-Host ''

if (-not $SkipPull) {
    Push-Location $RepoRoot
    try {
        git pull --ff-only origin main
    } finally {
        Pop-Location
    }
}

$sshScript = Join-Path $CommonDir 'ensure-ssh-to-148.ps1'
$skipUpload = $SkipLogUpload
if (-not $skipUpload -and (Test-Path $sshScript)) {
    . $sshScript
    if (-not (Test-AlfaSshTo148)) {
        Ensure-AlfaSshTo148 | Out-Null
        if (-not (Test-AlfaSshTo148)) {
            Write-Host '  Log upload: disabled until SSH key is authorized on inference' -ForegroundColor Yellow
            $skipUpload = $true
        }
    }
}

$natScript = Join-Path $CommonDir 'install-wsl-nat-portproxy.ps1'
if (Test-Path $natScript) {
    . $natScript
    if (Test-AlfaWslNatPortProxyRequired) {
        Write-Host '== Pre-deploy portproxy sync ==' -ForegroundColor Cyan
        Sync-AlfaWslNatPortProxy -TcpPorts 31330,31331,5003 -DisplayNamePrefix 'ALFa gaming-worker-a-219' -RepoRoot $RepoRoot -SkipFirewall | Out-Null
        Write-Host ''
    }
}

if (-not $SkipDeploy) {
    $buildArgs = @{
        SkipLogUpload = $skipUpload
    }
    if ($ForceBuild) { $buildArgs['ForceBuild'] = $true }

    & (Join-Path $MemberDir 'build-start-gaming-worker-a-219.ps1') @buildArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not $SkipPostStartup) {
    Write-Host ''
    Write-Host '== Post-startup gate (WarmUpSec 180) ==' -ForegroundColor Cyan
    & (Join-Path $CommonDir 'run-post-startup-status-with-log.ps1') `
        -HostProfile gaming-worker-a-219 -WarmUpSec 180 -NoScp:$skipUpload
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host ''
Write-Host 'STARTUP OK (gaming-worker-a-219) - verify RESULT: OK above; remote probe from inference if needed.' -ForegroundColor Green
