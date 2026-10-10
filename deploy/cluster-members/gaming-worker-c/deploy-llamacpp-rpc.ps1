<#
.SYNOPSIS
    Bring up llama.cpp rpc-server on gaming-c (:31351) for tier 3b.
.EXAMPLE
    .\deploy\cluster-members\gaming-worker-c\deploy-llamacpp-rpc.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkerDir = 'C:\alfa-ai-worker'
$Common    = Join-Path $PSScriptRoot '..\_common\deploy-llamacpp-rpc.ps1'
. $Common

$targetEnv = Join-Path $WorkerDir 'deploy\llamacpp-rpc\.env.rpc'
if (-not (Test-Path $targetEnv)) {
    if (-not (Test-Path (Split-Path $targetEnv))) {
        throw "Missing $(Split-Path $targetEnv) - run deploy.ps1 SMB stage first."
    }
    throw "Missing $targetEnv - create deploy\llamacpp-rpc\.env.rpc on this host before deploy (gitignored; do not copy from *.example at runtime)."
}

Write-Host '== gaming-c llama.cpp RPC shard ==' -ForegroundColor Cyan
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $WorkerDir -EnvFileRpc $targetEnv
