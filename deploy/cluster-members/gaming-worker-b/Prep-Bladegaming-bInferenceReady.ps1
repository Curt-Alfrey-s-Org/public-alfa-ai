#Requires -Version 5.1
<#
.SYNOPSIS
    Offline-friendly inference prep for gaming-worker-b (gaming-b) with cache-root picker.
.DESCRIPTION
    Pins ALFA_WINDOWS_CACHE_ROOT via Initialize-Alfa249CacheRoot, then runs the
    shared Prep-GamingHostinferenceReady.ps1 (picker, hub tarball stage, optional
    WSL docker load). Does NOT start the rpc-server shard.

    See docs/inference_GAMING_HOST_JOIN.md.
.PARAMETER RepoDir
    Path to alfa-ai clone (default: repo root above gaming-worker-b-249).
.PARAMETER LoadImage
    Run docker load into WSL after cache promote.
.PARAMETER SkipGit
    Skip git pull.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-b\Prep-gaming-worker-b249inferenceReady.ps1 -LoadImage
#>
[CmdletBinding()]
param(
    [string]$RepoDir = '',
    [switch]$LoadImage,
    [switch]$SkipGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Initialize-Alfa249CacheRoot.ps1')
Initialize-Alfa249CacheRoot | Out-Null

if (-not $RepoDir) {
    $RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

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
