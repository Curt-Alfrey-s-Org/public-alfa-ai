#Requires -Version 5.1
<#
.SYNOPSIS
    Fail Code27 deploy if llama-server placed model weights on orchestrator CPU (WSL RAM).
.DESCRIPTION
    After coordinator load, logs must show RPC shard buffers only -- no large
    CPU_Mapped / CPU_REPACK weight buffers on the orchestrator orchestrator host.
#>
[CmdletBinding()]
param(
    [int]$MaxCpuMappedMiB = 512
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logs = wsl.exe -d Ubuntu docker logs llamacpp-server 2>&1
if (-not $logs) {
    Write-Warning 'No llamacpp-server logs yet'
    exit 0
}

$cpuMapped = [regex]::Match($logs, 'CPU_Mapped model buffer size =\s+([\d.]+)\s+MiB')
$cpuRepack = [regex]::Match($logs, 'CPU_REPACK model buffer size =\s+([\d.]+)\s+MiB')

$mappedMiB = 0.0
$repackMiB = 0.0
if ($cpuMapped.Success) { $mappedMiB = [double]$cpuMapped.Groups[1].Value }
if ($cpuRepack.Success) { $repackMiB = [double]$cpuRepack.Groups[1].Value }

if ($mappedMiB -gt $MaxCpuMappedMiB -or $repackMiB -gt 0) {
    throw @"
Code27 rejected: model weight blocks on orchestrator CPU (WSL).
  CPU_Mapped: $mappedMiB MiB (max $MaxCpuMappedMiB)
  CPU_REPACK: $repackMiB MiB (max 0)
Free RPC shard VRAM on hub/apps/inference and redeploy shards before coordinator.
"@
}

if ($logs -match 'CUDA0\[|load_tensors:.*CUDA0') {
    throw 'Code27 rejected: local CUDA0 weight buffer on orchestrator -- CUDA_VISIBLE_DEVICES must stay empty.'
}

Write-Host "Code27 OK: no orchestrator CPU/GPU weight spill (CPU_Mapped ${mappedMiB} MiB)" -ForegroundColor Green
