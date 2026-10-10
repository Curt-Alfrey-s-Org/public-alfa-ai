#Requires -Version 5.1
<#
.SYNOPSIS
    Fail 27B/35B pool deploy if any shard GPU still holds model VRAM.
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
        throw "Pool GPU idle check failed: no nvidia-smi output from $Label ($SshTarget)"
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
Pool GPU idle check failed on $Label GPU $gpu : ${used} MiB used (max $MaxMiB).
Stop coordinator and restart rpc-server on all shards before load.
"@
        }
        Write-Host "  $Label GPU ${gpu}: ${used} MiB (idle OK)" -ForegroundColor Green
    }
}

Write-Host "== Phase H: verify all pool shard GPUs idle (max ${MaxIdleMiB} MiB; orchestrator allows 1536 for WDDM) ==" -ForegroundColor Cyan

Test-ShardGpuIdle -Label 'orchestrator 3060' -SshTarget 'operator@orchestrator' `
    -Query 'wsl -d Ubuntu nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits' -MaxMiB 1536

Test-ShardGpuIdle -Label 'apps 1660S' -SshTarget 'operator@apps' `
    -Query 'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits' -MaxMiB $MaxIdleMiB

Test-ShardGpuIdle -Label 'inference 3060' -SshTarget 'operator@orchestrator' `
    -Query 'nvidia-smi -i 1 --query-gpu=memory.used --format=csv,noheader,nounits' -MaxMiB $MaxIdleMiB

Test-ShardGpuIdle -Label 'inference 5060' -SshTarget 'operator@orchestrator' `
    -Query 'nvidia-smi -i 0 --query-gpu=memory.used --format=csv,noheader,nounits' -MaxMiB $MaxIdleMiB

Write-Host 'Pool GPU idle check passed.' -ForegroundColor Green
