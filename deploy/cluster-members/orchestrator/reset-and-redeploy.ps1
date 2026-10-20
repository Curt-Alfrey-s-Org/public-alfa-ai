<#
.SYNOPSIS
    Clean teardown + hub tarball reset + full redeploy for orchestrator (WSL Docker).
.DESCRIPTION
    Idempotent reset path:
      1. Stop primary Dockge and llamacpp-rpc containers.
      2. Delete hub tarball local cache + .loaded sentinels.
      3. git pull --ff-only origin main
      4. build-start-alfa-ai-93.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$TeardownOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CommonDir = Join-Path $PSScriptRoot '..\_common'
. (Join-Path $CommonDir 'initialize-windows-deploy.ps1')

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$localCacheDir = Get-AlfaWindowsDockerImagesCacheDir
$tarballsForHost = @()

$containerNames = @(
    'alfa-dockge',
    'llamacpp-rpc-server'
)

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Stop-Alfa93Containers {
    Write-Step '1. Stop ALFa orchestrator stack'
    Assert-AlfaWindowsDockerEngine
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($name in $containerNames) {
            & docker rm -f $name 2>&1 | Out-Null
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Clear-Alfa93TarballCache {
    Write-Step '2. Clear hub tarball local cache'
    if (-not (Test-Path $localCacheDir)) {
        Write-Host '  (no cache dir)' -ForegroundColor DarkGray
        return
    }
    foreach ($tb in $tarballsForHost) {
        Remove-Item -Force (Join-Path $localCacheDir $tb) -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $localCacheDir ($tb + '.loaded')) -ErrorAction SilentlyContinue
    }
    Write-Host '  Cache cleared' -ForegroundColor Green
}

Stop-Alfa93Containers
Clear-Alfa93TarballCache

if ($TeardownOnly) {
    Write-Host ''
    Write-Host 'Teardown only - not redeploying.' -ForegroundColor Yellow
    exit 0
}

Write-Step '3. Redeploy via build-start-alfa-ai-93.ps1'
$buildStart = Join-Path $PSScriptRoot 'build-start-alfa-ai-93.ps1'
& $buildStart -SkipPull:$SkipPull
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host 'reset-and-redeploy complete' -ForegroundColor Green
