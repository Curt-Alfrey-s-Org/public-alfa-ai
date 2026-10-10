#Requires -Version 5.1
<#
.SYNOPSIS
  One-time efficiency tuning on gaming-worker-a-219 (WSL RAM cap, startup cleanup, Defender paths).

.DESCRIPTION
  Run elevated on gaming-a. GPU fans: set GPU Tweak III to Manual 100% and save profile
  (no stable CLI; verify with nvidia-smi --query-gpu=fan.speed).

.EXAMPLE
  cd C:\Users\Corey\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\apply-gaming-worker-a-efficiency.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipWslShutdown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ExampleWsl = Join-Path $PSScriptRoot 'wslconfig-gaming-worker-a-219.example'
$DestWsl = Join-Path $env:USERPROFILE '.wslconfig'

. (Join-Path $PSScriptRoot 'Initialize-GamingWorkerCache.ps1')
$cacheRoot = Initialize-GamingWorkerWindowsCache

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run in an elevated PowerShell (Run as administrator).'
}

Write-Host '== apply-gaming-worker-a-efficiency on gaming-a ==' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ExampleWsl)) {
    throw "Missing template: $ExampleWsl"
}
Copy-Item -LiteralPath $ExampleWsl -Destination $DestWsl -Force
Write-Host "Wrote $DestWsl (memory=12GB cap)" -ForegroundColor Green

$startupPaths = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk')
)
foreach ($lnk in $startupPaths) {
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "Removed startup: $lnk" -ForegroundColor Green
    }
}

$exclusions = @(
    $RepoDir,
    (Join-Path $env:LOCALAPPDATA 'Docker'),
    $cacheRoot
)
foreach ($path in $exclusions) {
    if (Test-Path -LiteralPath $path) {
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-Host "Defender exclusion: $path" -ForegroundColor Green
        } catch {
            Write-Host "Defender exclusion skipped (may exist): $path" -ForegroundColor Yellow
        }
    }
}

if (-not $SkipWslShutdown) {
    Write-Host 'Applying .wslconfig requires wsl --shutdown' -ForegroundColor Cyan
    wsl.exe --shutdown
    Start-Sleep -Seconds 8
    wsl.exe -d Ubuntu echo WSL_OK | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'WSL failed to restart after shutdown'
    }
}

Write-Host ''
Write-Host 'Manual step (GPU fans):' -ForegroundColor Yellow
Write-Host '  GPU Tweak III -> RTX 5060 -> Fan -> Manual -> 100% -> Apply at startup'
Write-Host 'Verify: nvidia-smi --query-gpu=fan.speed --format=csv,noheader'
Write-Host ''
Write-Host 'Restart Dockge agent if needed: reconcile-dockge-stacks.ps1 or Dockge UI Start' -ForegroundColor Cyan
