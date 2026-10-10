#Requires -Version 5.1
<#
.SYNOPSIS
    Stop Code27 coordinator and reset rpc-server shards so GPUs are empty.
.DESCRIPTION
    Run before a clean Code27 coordinator load. Restarts rpc-server on apps/inference
    (and hub when SSH works) then verifies VRAM is idle.
#>
[CmdletBinding()]
param(
    [switch]$Skip111,
    [int]$MaxIdleMiB = 512
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoWin = 'C:/Users/operator\alfa-ai'
$IdleScript = Join-Path $PSScriptRoot 'verify-code27-gpu-idle.ps1'

Write-Host '== Code27: stop coordinator on orchestrator ==' -ForegroundColor Cyan
wsl.exe -d Ubuntu bash -lc 'docker rm -f llamacpp-server 2>/dev/null || true'

Write-Host '== Code27: restart rpc-server shards (free VRAM) ==' -ForegroundColor Cyan
ssh -o BatchMode=yes operator@apps 'docker restart llamacpp-rpc-server'
if ($LASTEXITCODE -ne 0) { throw 'apps rpc-server restart failed' }

ssh -o BatchMode=yes operator@orchestrator "bash ~/alfa-ai/deploy/cluster-members/inference-coordinator/start-code27-rpc-shard.sh"
if ($LASTEXITCODE -ne 0) { throw 'inference rpc-server restart failed' }

if (-not $Skip111) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out111 = ssh -o BatchMode=yes -o ConnectTimeout=8 operator@hub `
        'sudo docker restart llamacpp-rpc-server' 2>&1
    $ec111 = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($ec111 -ne 0) {
        Write-Host "  WARN: hub rpc restart via SSH failed -- run on hub:" -ForegroundColor Yellow
        Write-Host '    sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/deploy-llamacpp-rpc-shard.sh' -ForegroundColor Yellow
    } else {
        Write-Host '  hub rpc-server restarted' -ForegroundColor DarkGray
    }
}

Write-Host '== Code27: wait for rpc-server bind ==' -ForegroundColor Cyan
Start-Sleep -Seconds 5

& powershell -ExecutionPolicy Bypass -File $IdleScript -MaxIdleMiB $MaxIdleMiB
Write-Host '== Code27 pool reset complete (GPUs idle) ==' -ForegroundColor Green
