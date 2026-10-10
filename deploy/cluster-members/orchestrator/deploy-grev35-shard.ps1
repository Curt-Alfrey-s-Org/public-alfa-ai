#Requires -Version 5.1
<#
.SYNOPSIS
    G-rev2: deploy orchestrator rpc-server shard :31350 for 35B MoE pool.
.DESCRIPTION
    Stops Code27 coordinator on orchestrator if running. Does not start llama-server on orchestrator.
.EXAMPLE
    .\deploy-grev35-shard.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'
$Llc = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$EnvPath = Join-Path $Llc '.env.rpc'

$shardBlock = @"
# G-rev2: orchestrator rpc-server shard for 35B MoE pool (:31350)
RPC_PORT=31350
CUDA_VISIBLE_DEVICES=0
"@

if (-not (Test-Path (Split-Path $EnvPath))) {
    New-Item -ItemType Directory -Path (Split-Path $EnvPath) -Force | Out-Null
}
Set-Content -Path $EnvPath -Value $shardBlock -Encoding ASCII
Write-Host "Wrote orchestrator shard env to $EnvPath" -ForegroundColor Green

Write-Host '== G-rev2: stop Code27 coordinator on orchestrator (if any) ==' -ForegroundColor Cyan
wsl.exe -d Ubuntu bash -lc "docker stop llamacpp-server 2>/dev/null; docker rm -f llamacpp-server 2>/dev/null; true"

. (Join-Path $Common 'deploy-llamacpp-rpc.ps1')
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $RepoDir -EnvFileRpc $EnvPath

Write-Host 'Verify from hub: nc -zv orchestrator 31350' -ForegroundColor Green
