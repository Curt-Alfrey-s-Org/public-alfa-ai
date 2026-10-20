<#
.SYNOPSIS
    Bring up llama.cpp coordinator (llama-server) on gaming-b for tier 3b.
.DESCRIPTION
    Expects C:\alfa-ai-worker mirror with deploy\llamacpp-rpc. Ensure MODELS_DIR in .env.rpc
    points at the hub GGUF tree (map SMB e.g. Z:\llama-cpp\models). Start rpc-server shards
    on all backends before this. Stop Petals on the 5070 first.
.EXAMPLE
    cd C:\alfa-ai-worker-staging\gaming-worker-b-249
    .\deploy-llamacpp-rpc.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Initialize-Alfa249CacheRoot.ps1')
Initialize-Alfa249CacheRoot | Out-Null
Ensure-gaming-worker-b249RpcDockerImage -LoadIfMissing

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

Write-Host '== gaming-b llama.cpp RPC coordinator ==' -ForegroundColor Cyan
Invoke-AlfaLlamacppRpcDeploy -Role Coordinator -RepoDir $WorkerDir -EnvFileRpc $targetEnv
