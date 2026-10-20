<#
.SYNOPSIS
    Bring up llama.cpp rpc-server on gaming-a (:31352) for tier 3b.
.EXAMPLE
    .\deploy\cluster-members\gaming-worker-a\deploy-llamacpp-rpc.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

. (Join-Path $PSScriptRoot 'Initialize-GamingWorkerCache.ps1')
Initialize-GamingWorkerWindowsCache | Out-Null

$Common  = Join-Path $PSScriptRoot '..\_common\deploy-llamacpp-rpc.ps1'
. $Common

$targetEnv = Join-Path $RepoDir 'deploy\llamacpp-rpc\.env.rpc'
if (-not (Test-Path $targetEnv)) {
    if (-not (Test-Path (Split-Path $targetEnv))) {
        throw "Missing $(Split-Path $targetEnv) - run deploy.ps1 SMB stage first."
    }
    throw "Missing $targetEnv - create deploy\llamacpp-rpc\.env.rpc on this host before deploy (gitignored; do not copy from *.example at runtime)."
}

Write-Host '== gaming-a llama.cpp RPC shard ==' -ForegroundColor Cyan
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $RepoDir -EnvFileRpc $targetEnv
