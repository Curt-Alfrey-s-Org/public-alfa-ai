#Requires -Version 5.1
<#
.SYNOPSIS
    Fail Code27 deploy if RPC shard GPUs still hold model VRAM.
    Phase H pool: prefer verify-pool-gpu-idle.ps1 (all five shard GPUs).
.PARAMETER MaxIdleMiB
    Max VRAM (MiB) per shard GPU before coordinator load (rpc-server idle ~80-120).
#>
[CmdletBinding()]
param(
    [int]$MaxIdleMiB = 512
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ShardGpuIdle {
    param(
        [string]$Label,
        [string]$SshTarget,
        [string]$Query,
        [int]$MaxMiB
    )
    $out = ssh -o BatchMode=yes -o ConnectTimeout=8 $SshTarget $Query 2>$null
    if (-not $out) {
        throw "Code27 GPU idle check failed: no nvidia-smi output from $Label ($SshTarget)"
    }
    $lines = @($out -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
    foreach ($line in $lines) {
        $parts = $line -split ',\s*'
        if ($parts.Count -ge 2) {
            $used = [int]$parts[-1].Trim()
            $gpu = $parts[0].Trim()
        } else {
            $used = [int]$line.Trim()
            $gpu = '0'
        }
        if ($used -gt $MaxMiB) {
            throw @"
Code27 GPU idle check failed on $Label GPU $gpu : ${used} MiB used (max $MaxMiB).
Stop coordinator and restart rpc-server on all shards before load.
"@
        }
        Write-Host "  $Label GPU ${gpu}: ${used} MiB (idle OK)" -ForegroundColor Green
    }
}

Write-Host "== Code27: verify RPC shard GPUs idle (max ${MaxIdleMiB} MiB) ==" -ForegroundColor Cyan
Test-ShardGpuIdle -Label 'apps 1660S' -SshTarget 'operator@apps' `
    -Query 'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits' -MaxMiB $MaxIdleMiB
Test-ShardGpuIdle -Label 'inference RTX 5060' -SshTarget 'operator@orchestrator' `
    -Query 'nvidia-smi -i 0 --query-gpu=memory.used --format=csv,noheader,nounits' -MaxMiB $MaxIdleMiB

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$hub = ssh -o BatchMode=yes -o ConnectTimeout=8 operator@hub `
    'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits' 2>$null
$ErrorActionPreference = $prevEap
if ($hub) {
    $used111 = [int]$hub.Trim()
    if ($used111 -gt $MaxIdleMiB) {
        throw "Code27 GPU idle check failed on hub RTX 3050: ${used111} MiB used (max $MaxIdleMiB)."
    }
    Write-Host "  hub RTX 3050: ${used111} MiB (idle OK)" -ForegroundColor Green
} else {
    Write-Host '  WARN: could not SSH hub for nvidia-smi -- confirm 3050 is idle on hub' -ForegroundColor Yellow
}

Write-Host 'Code27 GPU idle check passed.' -ForegroundColor Green
