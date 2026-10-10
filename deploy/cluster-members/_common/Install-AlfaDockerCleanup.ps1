#Requires -Version 5.1
<#
.SYNOPSIS
  Install staggered Docker cleanup cron inside WSL Ubuntu (Windows workers).

.DESCRIPTION
  Copies the shared cleanup script into WSL and installs /etc/cron.d/alfa-docker-cleanup
  with the host-specific Sunday schedule from docs/operations/DOCKER_HOST_CLEANUP.md.

.PARAMETER CleanupHost
  Host key for schedule: 93, 219, 249, 59 (default: infer from COMPUTERNAME / ALFA_CLEANUP_HOST).

.PARAMETER Uninstall
  Remove /etc/cron.d/alfa-docker-cleanup from WSL.
#>
[CmdletBinding()]
param(
    [string]$CleanupHost = $env:ALFA_CLEANUP_HOST,
    [string]$Distro = 'Ubuntu',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$InstallSh = Join-Path $RepoRoot 'deploy\cluster-members\_common\install-docker-cleanup-cron.sh'
$CleanupSh = Join-Path $RepoRoot 'deploy\cluster-members\_common\docker-host-cleanup.sh'

if (-not (Test-Path -LiteralPath $InstallSh)) {
    throw "Missing $InstallSh"
}
if (-not (Test-Path -LiteralPath $CleanupSh)) {
    throw "Missing $CleanupSh"
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)
    $full = (Resolve-Path -LiteralPath $WindowsPath).Path
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    throw "Cannot convert path to WSL: $WindowsPath"
}

if (-not $CleanupHost) {
    $cn = ($env:COMPUTERNAME | ForEach-Object { $_.ToLowerInvariant() })
    if ($cn -match 'gaming-worker-a|219') { $CleanupHost = '219' }
    elseif ($cn -match 'gaming-worker-b|249') { $CleanupHost = '249' }
    elseif ($cn -match 'gaming-worker-c|59') { $CleanupHost = '59' }
    elseif ($cn -match 'operator|93') { $CleanupHost = '93' }
    else { $CleanupHost = '93' }
}

$wslInstall = ConvertTo-WslPath -WindowsPath $InstallSh
Write-Host "WSL distro=$Distro cleanup_host=$CleanupHost"

if ($Uninstall) {
    wsl -d $Distro -u root -- bash -lc "bash '$wslInstall' --uninstall"
    if ($LASTEXITCODE -ne 0) { throw "uninstall failed exit=$LASTEXITCODE" }
    Write-Host 'Removed alfa-docker-cleanup cron from WSL.'
    exit 0
}

# Ensure cron package exists (WSL Ubuntu).
wsl -d $Distro -u root -- bash -lc 'command -v cron >/dev/null || (export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq cron); service cron start 2>/dev/null || true'
if ($LASTEXITCODE -ne 0) {
    Write-Warning "cron package preflight returned $LASTEXITCODE (continuing)"
}

$envLine = "ALFA_CLEANUP_HOST=$CleanupHost ALFA_AI_REPO='$(ConvertTo-WslPath -WindowsPath $RepoRoot)'"
wsl -d $Distro -u root -- bash -lc "$envLine bash '$wslInstall'"
if ($LASTEXITCODE -ne 0) { throw "install-docker-cleanup-cron.sh failed exit=$LASTEXITCODE" }

Write-Host 'OK: WSL Docker cleanup cron installed. See docs/operations/DOCKER_HOST_CLEANUP.md'
