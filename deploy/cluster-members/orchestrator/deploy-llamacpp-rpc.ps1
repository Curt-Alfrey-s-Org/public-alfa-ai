<#
.SYNOPSIS
    Bring up llama.cpp rpc-server on BOTH RTX 3060s (orchestrator) for tier 3b Coder-Next.
.DESCRIPTION
    Uses deploy/llamacpp-rpc/docker-compose.rpc-server.dual-gpu-93.yml (:31350 + :31355).
    Run from the real git checkout (e.g. C:\alfa-ai). Stop Petals on GPU 0/1 first.
.EXAMPLE
    cd C:\alfa-ai
    .\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$Common  = Join-Path $PSScriptRoot '..\_common\deploy-llamacpp-rpc.ps1'
. $Common

$targetEnv = Join-Path $RepoDir 'deploy\llamacpp-rpc\.env.rpc'
if (-not (Test-Path $targetEnv)) {
    throw "Missing $targetEnv - create deploy\llamacpp-rpc\.env.rpc on this host before deploy (gitignored; do not copy from *.example at runtime)."
}

Write-Host '== orchestrator llama.cpp RPC (dual shard) ==' -ForegroundColor Cyan
Write-Host "  Repo: $RepoDir"
Invoke-AlfaLlamacppRpcDeploy -Role ShardDual93 -RepoDir $RepoDir -EnvFileRpc $targetEnv
