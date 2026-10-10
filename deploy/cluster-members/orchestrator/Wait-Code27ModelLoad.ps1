#Requires -Version 5.1
<#
.SYNOPSIS
    Wait for one Code27 model load pass (log milestones + timing, detect reload loops).
.DESCRIPTION
    503 on /health is normal while loading. Fails if load_tensors starts more than
    once (Docker restart loop). Records per-shard weight buffer timing from logs.
#>
[CmdletBinding()]
param(
    [string]$ContainerName = 'llamacpp-server',
    [string]$HealthUrl = 'http://127.0.0.1:31360/health',
    [int]$TimeoutSec = 1200,
    [int]$PollSec = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ShardEndpoints = @(
    @{ Label = 'hub RTX 3050'; Pattern = '192\.168\.0\hub:31353' }
    @{ Label = 'apps 1660S'; Pattern = '192\.168\.0\apps:31354' }
    @{ Label = 'inference RTX 5060'; Pattern = '192\.168\.0\inference:31357' }
)

function Get-CoordinatorLogs {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = wsl.exe -d Ubuntu docker logs $ContainerName 2>&1 | Out-String
    $ErrorActionPreference = $prev
    return $text
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$loadStarts = 0
$loadStartAt = $null
$shardAt = @{}
$offloaded65 = $false
$listening = $false
$rpcCrash = 0
$lastLoadCountWarn = 0

Write-Host "== Code27: wait for single model load pass (timeout ${TimeoutSec}s) ==" -ForegroundColor Cyan
Write-Host '  503 on /health is expected until load completes.' -ForegroundColor DarkGray

while ((Get-Date) -lt $deadline) {
    $logs = Get-CoordinatorLogs
    if (-not $logs) {
        Start-Sleep -Seconds $PollSec
        continue
    }

    $loadStarts = ([regex]::Matches($logs, 'load_tensors: loading model tensors')).Count
    if ($loadStarts -gt 1) {
        throw @"
Code27 reload loop detected: load_tensors started $loadStarts times.
Coordinator must use restart: no (code27-load overlay). Run reset-code27-rpc-pool.ps1 and redeploy.
"@
    }
    if ($loadStarts -eq 1 -and -not $loadStartAt) {
        $loadStartAt = Get-Date
        Write-Host ('  [{0}] load_tensors started (one pass)' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
    }

    foreach ($shard in $ShardEndpoints) {
        $key = $shard.Label
        if ($shardAt.ContainsKey($key)) { continue }
        if ($logs -match ('RPC0\[' + $shard.Pattern + '\] model buffer size =\s+([\d.]+)\s+MiB')) {
            $now = Get-Date
            $shardAt[$key] = @{ At = $now; MiB = [double]$Matches[1] }
            $elapsed = if ($loadStartAt) { ($now - $loadStartAt).TotalSeconds } else { 0 }
            Write-Host ('  [{0}] {1} weights ready: {2} MiB (+{3:N0}s from load start)' -f `
                (Get-Date -Format 'HH:mm:ss'), $key, $Matches[1], $elapsed) -ForegroundColor Green
        }
    }

    if ($logs -match 'offloaded 65/65 layers') { $offloaded65 = $true }
    if ($logs -match 'HTTP server is listening|main: HTTP server started') { $listening = $true }
    $rpcCrash = ([regex]::Matches($logs, 'Remote RPC server crashed')).Count

    if ($rpcCrash -gt 0 -and $loadStarts -eq 1 -and $offloaded65) {
        throw @"
Code27 load failed after weights uploaded: Remote RPC server crashed ($rpcCrash).
Check inference 3050 sched_reserve / hybrid compute. GPUs were reset; fix shard then redeploy.
"@
    }

    try {
        $null = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 5
        Write-Host ('  [{0}] /health 200 OK' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Green
        if ($loadStartAt) {
            $total = ((Get-Date) - $loadStartAt).TotalSeconds
            Write-Host ("  Total load time: {0:N0}s (single pass)" -f $total) -ForegroundColor Green
        }
        if ($shardAt.Count -ge 2) {
            $first = ($shardAt.Values | Sort-Object { $_.At } | Select-Object -First 1)
            $last = ($shardAt.Values | Sort-Object { $_.At } | Select-Object -Last 1)
            $span = ($last.At - $first.At).TotalSeconds
            Write-Host ("  Shard weight spread: {0:N0}s (parallel RPC upload; not 3x serial)" -f $span) -ForegroundColor DarkGray
        }
        return $true
    } catch {
        $code = 'waiting'
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($loadStarts -eq 0) {
            Write-Host ('  [{0}] container up, model load not started yet...' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
        } elseif ($code -eq 503) {
            if ($shardAt.Count -lt 3) {
                Write-Host ('  [{0}] loading... {1}/3 shard weight buffers logged (503 OK)' -f `
                    (Get-Date -Format 'HH:mm:ss'), $shardAt.Count) -ForegroundColor DarkGray
            } else {
                Write-Host ('  [{0}] weights on all shards; finishing KV/sched (503 OK)...' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
            }
        }
    }

    Start-Sleep -Seconds $PollSec
}

throw "Code27 load timed out after ${TimeoutSec}s. Run report-code27-vram-budget.ps1 and check shard logs."
