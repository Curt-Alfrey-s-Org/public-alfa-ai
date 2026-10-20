#Requires -Version 5.1
<#
.SYNOPSIS
  Free GPU and RAM on gaming-a for gaming (stop local inference shard).

.DESCRIPTION
  Stops the WSL llama.cpp rpc-server shard on this host only. Does NOT stop the
  cluster coordinator on hub.

  IMPORTANT: llama.cpp RPC backends are fixed at coordinator start. Stopping this
  shard while it was opted into the live pool will crash inference. Correct leave:
  from orchestrator run Start-Stop-AlfaAi.ps1 stop, then start and answer N for gaming-a.

  This script is for freeing the GPU when gaming-a was NOT in the active pool, or
  after the coordinator is already stopped.

.PARAMETER ShutdownWsl
  After stopping the shard, run wsl --shutdown to drop vmmem RAM (Dockge down until resume).

.EXAMPLE
  cd C:\Users\Corey\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\gaming-stop-for-session.ps1 -ShutdownWsl
#>
[CmdletBinding()]
param(
    [switch] $ShutdownWsl,
    # When set (orchestrator SSH from orchestrator), skip Read-Host so stop cannot hang.
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'

function ConvertTo-AlfaWslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $resolved = (Resolve-Path -LiteralPath $WinPath).Path
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    throw "Not a Windows path: $WinPath"
}

Write-Host '== gaming-worker-a-219: stop inference shard for gaming ==' -ForegroundColor Cyan
Write-Host 'If gaming-a was in the live pool: run full stop+start from orchestrator and answer N for gaming-a.' -ForegroundColor Yellow
Write-Host 'Killing this shard while the coordinator holds the session crashes inference.' -ForegroundColor Yellow

$stopScript = Join-Path $Common 'inference-stop-local.sh'
$wslStop = ConvertTo-AlfaWslPath -WinPath $stopScript
$envPrefix = 'inference_STOP_MODE=shard HOST_LABEL=219 ALFA_AI_REPO=/mnt/c/Users/Corey/alfa-ai '
wsl.exe -d Ubuntu bash -lc "${envPrefix}bash '$wslStop'"
if ($LASTEXITCODE -ne 0) {
    throw "inference-stop-local (shard) failed (exit $LASTEXITCODE)"
}

# Fail closed inside WSL. Do NOT use LAN TCP to orchestrator -- Win10
# netsh portproxy keeps that listen open after rpc-server is gone
# (https://learn.microsoft.com/en-us/windows/wsl/networking).
# Do NOT gate on nvidia-smi memory.used: WDDM desktop (Chrome/Discord) often
# shows ~2 GiB with no CUDA rpc-server left.
Write-Host 'Verify shard really stopped (WSL :31352 + docker name):' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ncExit = 0
try {
    $null = wsl.exe -d Ubuntu bash -lc 'nc -z -w 2 127.0.0.1 31352' 2>&1
    $ncExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($ncExit -eq 0) {
    throw 'FAIL: 127.0.0.1:31352 still listening in WSL after inference-stop-local (shard)'
}

$ErrorActionPreference = 'Continue'
$dockerPs = ''
try {
    $dockerPs = (wsl.exe -d Ubuntu docker ps -a --format '{{.Names}}' 2>&1 | Out-String)
} finally {
    $ErrorActionPreference = $prevEap
}
if ($dockerPs -match '(?m)^llamacpp-rpc') {
    throw 'FAIL: llamacpp-rpc* container still present after shard stop'
}

Write-Host 'Shard stopped (WSL :31352 closed, no rpc container). GPU snapshot:' -ForegroundColor Green
nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu,fan.speed --format=csv,noheader

if ($ShutdownWsl) {
    Write-Host 'Shutting down WSL (frees vmmem; Dockge offline until resume)...' -ForegroundColor Cyan
    wsl.exe --shutdown
    Start-Sleep -Seconds 5
    Get-Process vmmem -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  vmmem still present (id $($_.Id))" -ForegroundColor Yellow
    }
    if (-not (Get-Process vmmem -ErrorAction SilentlyContinue)) {
        Write-Host '  WSL VM stopped' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Gaming tips:' -ForegroundColor Cyan
Write-Host '  - Set GPU Tweak III fan mode Manual 100% if GPU fan.speed above shows 0%'
Write-Host '  - Quit Discord / Wallpaper Engine for extra headroom (optional)'
Write-Host 'After gaming: from orchestrator Start-Stop-AlfaAi.ps1 start and answer Y for gaming-a to rejoin'
Write-Host '(Optional local warm-up) gaming-resume-pool-shard.ps1 before that start'
if (-not $NoPause) {
    Read-Host 'Press Enter to close this window'
}
