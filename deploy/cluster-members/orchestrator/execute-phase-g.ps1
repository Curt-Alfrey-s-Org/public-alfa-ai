#Requires -Version 5.1
<#
.SYNOPSIS
    Phase G on orchestrator: Ollama 35B on RTX 3060 + Code coordinator on 3050/5060 pool.

.DESCRIPTION
    1) Stop rpc-server on orchestrator :31350 (3060 reserved for Ollama 35B).
    2) Pull qwen3.6:35b-a3b (hub-first).
    3) Switch coordinator to Code27 profile (RPC inference:31357 + apps:31354 + hub:31353).
    4) Redeploy coordinator.

    Does not start Petals or 80B Code profile. Use LiteLLM aliases:
      fast / chat / qwen3.6:35b-a3b  -> Ollama 35B on orchestrator + inference
      qwen3.6-27b                    -> 27B RPC pool (after Code27 coordinator up)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy\cluster-members\orchestrator\execute-phase-g.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$SkipCoordinator
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$PullScript = Join-Path $RepoDir 'deploy\cluster-members\_common\pull-models.ps1'
$SwitchScript = Join-Path $PSScriptRoot 'switch-coordinator-profile.ps1'
$CoordScript = Join-Path $PSScriptRoot 'deploy-llamacpp-rpc-coordinator.ps1'

Write-Host '== Phase G (orchestrator): stop 3060 rpc-server shard ==' -ForegroundColor Cyan
$rpc = wsl -d Ubuntu docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -match 'llamacpp-rpc-93' }
foreach ($name in $rpc) {
    if ($name -match 'gpu0|31350') {
        Write-Host "  Stopping $name (free RTX 3060 for Ollama 35B)..."
        wsl -d Ubuntu docker stop $name 2>$null | Out-Null
    }
}

if (-not $SkipPull) {
    Write-Host '== Phase G (orchestrator): pull qwen3.6:35b-a3b ==' -ForegroundColor Cyan
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw 'ollama not on PATH'
    }
    & powershell -ExecutionPolicy Bypass -File $PullScript -Role Speed
}

if (-not $SkipCoordinator) {
    Write-Host '== Phase G (orchestrator): Code27 coordinator (inference:31357 + apps:31354 + hub:31353) ==' -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File $SwitchScript -Profile Code27
    & powershell -ExecutionPolicy Bypass -File $CoordScript -Profile Code27
}

Write-Host ''
Write-Host 'Phase G orchestrator steps done. Verify:' -ForegroundColor Green
Write-Host '  ollama list  -> qwen3.6:35b-a3b'
Write-Host '  curl http://127.0.0.1:31360/health'
Write-Host '  curl http://127.0.0.1:31360/v1/models  -> qwen3.6-27b (Code27 profile)'
Write-Host '  Code27: nvidia-smi on orchestrator -- 3060 VRAM should be Ollama 35B only (no ~7 GiB llama-server shard)'
Write-Host 'Next: run phase-g on inference and hub; smoke fast + qwen3.6-27b via LiteLLM on hub'
