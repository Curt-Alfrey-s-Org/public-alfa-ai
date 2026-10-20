#Requires -Version 5.1
<#
.SYNOPSIS
    Print per-shard VRAM budget vs coordinator logs (Code27 27B RPC pool).
.DESCRIPTION
    Parses the latest load_tensors / sched_reserve block from llamacpp-server logs.
    Use after deploy or while debugging OOM / reload loops.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File report-code27-vram-budget.ps1
#>
[CmdletBinding()]
param(
    [string]$ContainerName = 'llamacpp-server',
    [int]$ExitNonZeroOnReloadLoop = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ShardBudgets = @{
    'hub' = @{ Label = 'hub RTX 3050'; BudgetMiB = 6144 }
    'apps' = @{ Label = 'apps GTX 1660S'; BudgetMiB = 6144 }
    'orchestrator' = @{ Label = 'inference RTX 5060'; BudgetMiB = 8192 }
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$logs = wsl.exe -d Ubuntu docker logs $ContainerName 2>&1 | Out-String
$ErrorActionPreference = $prevEap
if (-not $logs -or $logs.Trim().Length -lt 10) {
    Write-Warning "No logs for container $ContainerName"
    exit 0
}

$reloadCount = ([regex]::Matches($logs, 'load_tensors: loading model tensors')).Count
$probeCount = ([regex]::Matches($logs, 'POST /v1/chat/completions 192\.168\.0\hub')).Count
$rpcCrashCount = ([regex]::Matches($logs, 'Remote RPC server crashed')).Count

function Get-LastMatchMiB {
    param([string]$Text, [string]$Pattern)
    $m = [regex]::Matches($Text, $Pattern)
    if ($m.Count -eq 0) { return $null }
    return [double]$m[$m.Count - 1].Groups[1].Value
}

function Get-LastShardMap {
    param([string]$Text, [string]$Pattern)
    $result = @{}
    foreach ($m in [regex]::Matches($Text, $Pattern)) {
        $key = '{0}:{1}' -f $m.Groups[1].Value, $m.Groups[2].Value
        $result[$key] = [double]$m.Groups[3].Value
    }
    return $result
}

$weightPattern = 'RPC0\[(\d+\.\d+\.\d+\.\d+):(\d+)\] model buffer size =\s+([\d.]+)\s+MiB'
$kvPattern = 'RPC0\[(\d+\.\d+\.\d+\.\d+):(\d+)\] KV buffer size =\s+([\d.]+)\s+MiB'
$rsPattern = 'RPC0\[(\d+\.\d+\.\d+\.\d+):(\d+)\] RS buffer size =\s+([\d.]+)\s+MiB'
$computePattern = 'RPC0\[(\d+\.\d+\.\d+\.\d+):(\d+)\] compute buffer size =\s+([\d.]+)\s+MiB'

$weights = Get-LastShardMap -Text $logs -Pattern $weightPattern
$kv = Get-LastShardMap -Text $logs -Pattern $kvPattern
$rs = Get-LastShardMap -Text $logs -Pattern $rsPattern
$compute = Get-LastShardMap -Text $logs -Pattern $computePattern

$cpuModelMiB = Get-LastMatchMiB -Text $logs -Pattern 'CPU model buffer size =\s+([\d.]+)\s+MiB'
$cpuMappedMiB = Get-LastMatchMiB -Text $logs -Pattern 'CPU_Mapped model buffer size =\s+([\d.]+)\s+MiB'
$cpuRepackMiB = Get-LastMatchMiB -Text $logs -Pattern 'CPU_REPACK model buffer size =\s+([\d.]+)\s+MiB'
$offloaded = if ($logs -match 'offloaded (\d+)/(\d+) layers') { $Matches[0] } else { 'unknown' }

Write-Host ''
Write-Host '== Code27 VRAM budget (latest log snapshot) ==' -ForegroundColor Cyan
Write-Host ("  load_tensors attempts: {0}  |  LiteLLM hub probes: {1}  |  RPC crashes: {2}" -f $reloadCount, $probeCount, $rpcCrashCount)
Write-Host ("  layer offload: {0}" -f $offloaded)
Write-Host ''

$totalWeights = 0.0
$totalBudget = 0.0
$rows = @()

foreach ($endpoint in @('hub', 'apps', 'orchestrator')) {
    $meta = $ShardBudgets[$endpoint]
    $w = if ($weights.ContainsKey($endpoint)) { $weights[$endpoint] } else { 0.0 }
    $k = if ($kv.ContainsKey($endpoint)) { $kv[$endpoint] } else { 0.0 }
    $r = if ($rs.ContainsKey($endpoint)) { $rs[$endpoint] } else { 0.0 }
    $c = if ($compute.ContainsKey($endpoint)) { $compute[$endpoint] } else { 0.0 }
    $estPeak = $w + $k + $r + $c
    $headroom = $meta.BudgetMiB - $estPeak
    $totalWeights += $w
    $totalBudget += $meta.BudgetMiB

    $flag = ''
    if ($estPeak -gt $meta.BudgetMiB) { $flag = ' OVER' }
    elseif ($headroom -lt 512) { $flag = ' TIGHT' }

    $rows += [PSCustomObject]@{
        Shard    = $meta.Label
        Endpoint = $endpoint
        Weights  = [math]::Round($w, 1)
        KV       = [math]::Round($k, 1)
        RS       = [math]::Round($r, 1)
        Compute  = [math]::Round($c, 1)
        EstPeak  = [math]::Round($estPeak, 1)
        Budget   = $meta.BudgetMiB
        Free     = [math]::Round($headroom, 1)
        Note     = $flag.Trim()
    }
}

$rows | Format-Table -AutoSize

Write-Host 'orchestrator orchestrator (CPU-only, not in GPU pool):' -ForegroundColor DarkGray
Write-Host ("  CPU model buffer: {0} MiB  |  CPU_Mapped: {1} MiB  |  CPU_REPACK: {2} MiB" -f `
    ($(if ($null -ne $cpuModelMiB) { $cpuModelMiB } else { 'n/a' })), `
    ($(if ($null -ne $cpuMappedMiB) { $cpuMappedMiB } else { '0' })), `
    ($(if ($null -ne $cpuRepackMiB) { $cpuRepackMiB } else { '0' })))
Write-Host ("  Sum RPC weights (one copy split): {0} MiB (~{1:N1} GB)  |  Pool budget: {2} MiB (~{3:N1} GB)" -f `
    [math]::Round($totalWeights, 1), ($totalWeights / 1024), $totalBudget, ($totalBudget / 1024))

if ($reloadCount -gt 3) {
    Write-Host ''
    Write-Host "WARN: $reloadCount load attempts -- likely crash/reload loop (not triple-loading one GPU)." -ForegroundColor Yellow
    if ($probeCount -gt 10) {
        Write-Host 'WARN: LiteLLM on hub is POSTing during 503 -- stop alfa-ai-litellm during first load.' -ForegroundColor Yellow
    }
}

if ($ExitNonZeroOnReloadLoop -gt 0 -and $reloadCount -gt $ExitNonZeroOnReloadLoop) {
    exit 1
}
