#Requires -Version 5.1
<#
.SYNOPSIS
    Offline-friendly inference prep for gaming-worker-a-219 (gaming-a) with cache-root picker.

.DESCRIPTION
    Pins ALFA_WINDOWS_CACHE_ROOT via Initialize-GamingWorkerCache.ps1, then runs
    the shared Prep-GamingHostinferenceReady.ps1 (picker, hub tarball stage,
    optional WSL docker load). Does NOT start the rpc-server shard.

.PARAMETER RepoDir
    Path to alfa-ai clone (default: repo root from this script).
.PARAMETER LoadImage
    Run docker load into WSL after cache promote.
.PARAMETER SkipGit
    Skip git pull.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\Prep-GamingWorkerinferenceReady.ps1 -LoadImage
#>
[CmdletBinding()]
param(
    [string]$RepoDir = '',
    [switch]$LoadImage,
    [switch]$SkipGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) {
    $RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

. (Join-Path $PSScriptRoot 'Initialize-GamingWorkerCache.ps1')
Initialize-GamingWorkerWindowsCache | Out-Null

$prepScript = Join-Path $PSScriptRoot '..\_common\Prep-GamingHostinferenceReady.ps1'
$prepArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $prepScript,
    '-RepoDir', $RepoDir
)
if ($LoadImage) {
    $prepArgs += '-LoadImage'
}
if ($SkipGit) {
    $prepArgs += '-SkipGit'
}

& powershell.exe @prepArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
