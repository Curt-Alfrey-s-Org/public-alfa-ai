#Requires -Version 5.1
<#
.SYNOPSIS
  Free GPU and RAM on orchestrator for gaming (stop local inference shard).
#>
[CmdletBinding()]
param(
    [switch] $ShutdownWsl
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

Write-Host '== operator-93: stop inference shard for gaming ==' -ForegroundColor Cyan
Write-Host 'inference on hub may show errors until this shard is back or you run full stop+start.' -ForegroundColor Yellow

$stopScript = Join-Path $Common 'inference-stop-local.sh'
$wslStop = ConvertTo-AlfaWslPath -WinPath $stopScript
$envPrefix = 'inference_STOP_MODE=shard HOST_LABEL=93 ALFA_AI_REPO=/mnt/c/Users/operator/alfa-ai '
wsl.exe -d Ubuntu bash -lc "${envPrefix}bash '$wslStop'"
if ($LASTEXITCODE -ne 0) {
    throw "inference-stop-local (shard) failed (exit $LASTEXITCODE)"
}

Write-Host 'Shard stopped. Verify GPU idle:' -ForegroundColor Cyan
nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu,fan.speed --format=csv,noheader

if ($ShutdownWsl) {
    Write-Host 'Shutting down WSL (frees vmmem; Dockge offline until resume)...' -ForegroundColor Cyan
    wsl.exe --shutdown
    Start-Sleep -Seconds 5
    if (-not (Get-Process vmmem -ErrorAction SilentlyContinue)) {
        Write-Host '  WSL VM stopped' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'After gaming: from orchestrator Start-Stop-AlfaAi.ps1 start (Done Gaming starts WSL only; it does not redeploy this shard)'
Write-Host 'If inference stays broken: Start-Stop-AlfaAi.ps1 stop then start'
Read-Host 'Press Enter to close this window'
