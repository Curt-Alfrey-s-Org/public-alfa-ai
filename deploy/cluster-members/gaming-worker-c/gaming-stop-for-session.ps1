#Requires -Version 5.1
<#
.SYNOPSIS
  Free GPU on gaming-c for gaming (stop local inference shard :31351).
.DESCRIPTION
  Stops the WSL llama.cpp rpc-server on this host only. Does NOT stop hub coordinator.
  If gaming-c was in the live pool: from orchestrator run Start-Stop-AlfaAi.ps1 stop, then start and answer N for gaming-c.
.PARAMETER ShutdownWsl
  After stop, run wsl --shutdown.
.PARAMETER NoPause
  Skip Read-Host (for scripted runs).
#>
[CmdletBinding()]
param(
    [switch] $ShutdownWsl,
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'
$RpcPort = 31351

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

Write-Host '== gaming-worker-c-59: stop inference shard for gaming ==' -ForegroundColor Cyan
Write-Host 'If gaming-c was in the live pool: full stop+start from orchestrator and answer N for gaming-c.' -ForegroundColor Yellow

$stopScript = Join-Path $Common 'inference-stop-local.sh'
$wslStop = ConvertTo-AlfaWslPath -WinPath $stopScript
$repoWsl = ConvertTo-AlfaWslPath -WinPath $RepoDir
$envPrefix = "inference_STOP_MODE=shard HOST_LABEL=59 ALFA_AI_REPO=$repoWsl "
wsl.exe -d Ubuntu bash -lc "${envPrefix}bash '$wslStop'"
if ($LASTEXITCODE -ne 0) {
    throw "inference-stop-local (shard) failed (exit $LASTEXITCODE)"
}

Write-Host ("Verify shard stopped (WSL :{0} + docker name):" -f $RpcPort) -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ncExit = 0
try {
    $null = wsl.exe -d Ubuntu bash -lc "nc -z -w 2 127.0.0.1 $RpcPort" 2>&1
    $ncExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($ncExit -eq 0) {
    throw ("FAIL: 127.0.0.1:{0} still listening in WSL after inference-stop-local (shard)" -f $RpcPort)
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

Write-Host ("Shard stopped (WSL :{0} closed)." -f $RpcPort) -ForegroundColor Green
nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu --format=csv,noheader

if ($ShutdownWsl) {
    Write-Host 'Shutting down WSL...' -ForegroundColor Cyan
    wsl.exe --shutdown
    Start-Sleep -Seconds 5
}

Write-Host 'After gaming: from orchestrator Start-Stop-AlfaAi.ps1 start and answer Y for gaming-c'
if (-not $NoPause) {
    Read-Host 'Press Enter to close'
}
