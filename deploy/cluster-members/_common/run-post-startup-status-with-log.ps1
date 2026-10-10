#Requires -Version 5.1
<#
.SYNOPSIS
    Post-startup cluster status on Windows - runs bash checks in WSL, logs, SCP to inference hub.

.DESCRIPTION
    Prefer WSL Ubuntu with Docker Engine (see docs/WINDOWS_WSL_DOCKER_ENGINE.md).
    Maps Windows repo path to WSL and invokes run-post-startup-status-with-log.sh.

.PARAMETER HostProfile
    hub-111 | apps-105 | operator-93 | gaming-worker-c-59 | gaming-worker-a-219 | gaming-worker-b-249 | ai-148

.PARAMETER NoScp
    Skip SCP to inference hub.

.PARAMETER WarmUpSec
    Seconds to wait inside WSL before running checks (default 0). Use 180 after
    cold start so Petals throughput benchmark and gateway health can finish.

.EXAMPLE
    .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 -HostProfile operator-93
.EXAMPLE
    .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 -HostProfile gaming-worker-a-219 -WarmUpSec 180
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('operator-93', 'gaming-worker-c-59', 'gaming-worker-a-219', 'gaming-worker-b-249')]
    [string]$HostProfile,

    [switch]$NoScp,

    [int]$WarmUpSec = 0,

    [string]$WslDistro = 'Ubuntu',

    [string]$RepoRoot
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $here = $PSScriptRoot
    $RepoRoot = (Resolve-Path (Join-Path $here '..\..\..')).Path
}

$winRepo = $RepoRoot -replace '\\', '/'
if ($winRepo -match '^([A-Za-z]):/(.*)$') {
    $drive = $Matches[1].ToLower()
    $rest = $Matches[2]
    $wslRepo = "/mnt/$drive/$rest"
} else {
    Write-Error "Cannot map repo path to WSL: $RepoRoot"
}

$wrapper = "$wslRepo/deploy/cluster-members/_common/run-post-startup-status-with-log.sh"
$scpFlag = if ($NoScp) { '0' } else { '1' }

Write-Host "Windows repo: $RepoRoot" -ForegroundColor Cyan
Write-Host "WSL repo:     $wslRepo" -ForegroundColor Cyan
Write-Host "Profile:      $HostProfile" -ForegroundColor Cyan
Write-Host "SCP to inference:  $scpFlag" -ForegroundColor Cyan
if ($WarmUpSec -gt 0) {
    Write-Host ('WarmUpSec:    {0} (inside WSL - keeps VM alive)' -f $WarmUpSec) -ForegroundColor Cyan
}

$wslParts = @("cd '$wslRepo'")
if ($WarmUpSec -gt 0) {
    $wslParts += "sleep $WarmUpSec"
}
$wslParts += @(
    "export HOST_PROFILE='$HostProfile'"
    "export SCP_TO_BUILD_HOST='$scpFlag'"
    "bash '$wrapper'"
)
$wslCmd = $wslParts -join '; '

& wsl.exe -d $WslDistro -e bash -lc $wslCmd
exit $LASTEXITCODE
