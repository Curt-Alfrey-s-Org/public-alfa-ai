#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy gaming-b rpc-server shard :31358 for inference (RTX 5070).
.DESCRIPTION
    Run on gaming-worker-b when opted into inference at the next orchestrator cluster start.
    Not auto-deployed from orchestrator yet -- start this locally before answering Y for gaming-b.
.EXAMPLE
    cd C:\Users\YOURUSER\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-b\deploy-grev27-pool-shard.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Initialize-Alfa249CacheRoot.ps1')
Initialize-Alfa249CacheRoot | Out-Null

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'
$Llc = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$EnvPath = Join-Path $Llc '.env.rpc'

function ConvertTo-AlfaWslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $resolved = (Resolve-Path -LiteralPath $WinPath).Path
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    throw "Not a Windows path: $WinPath"
}

function Invoke-AlfaWslBashScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$EnvPrefix = ''
    )
    $wslScript = ConvertTo-AlfaWslPath -WinPath $ScriptPath
    wsl.exe -d Ubuntu bash -lc "${EnvPrefix}bash '$wslScript'"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL bash failed (exit $LASTEXITCODE): $ScriptPath"
    }
}

Write-Host '== Phase H: Docker preflight on gaming-b ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-docker-engine.sh') -EnvPrefix 'HOST_LABEL=249 '

Write-Host '== Phase H: stop local llama / free GPU on gaming-b ==' -ForegroundColor Cyan
$repoWsl = ConvertTo-AlfaWslPath -WinPath $RepoDir
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'inference-stop-local.sh') `
    -EnvPrefix "inference_STOP_MODE=shard HOST_LABEL=249 ALFA_AI_REPO=$repoWsl "
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-gpu-empty.sh') -EnvPrefix 'HOST_LABEL=249 MAX_MIB=3072 '

$shardBlock = @"
# Phase H: gaming-b rpc-server shard for inference (:31358)
RPC_PORT=31358
CUDA_VISIBLE_DEVICES=0
"@

if (-not (Test-Path (Split-Path $EnvPath))) {
    New-Item -ItemType Directory -Path (Split-Path $EnvPath) -Force | Out-Null
}
Set-Content -Path $EnvPath -Value $shardBlock -Encoding ASCII
Write-Host "Wrote gaming-b shard env to $EnvPath" -ForegroundColor Green

Ensure-gaming-worker-b249RpcDockerImage -LoadIfMissing

. (Join-Path $Common 'deploy-llamacpp-rpc.ps1')
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $RepoDir -EnvFileRpc $EnvPath

Write-Host '== Phase H: LAN reachability check (orchestrator) ==' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ncExit = 1
try {
    $null = wsl.exe -d Ubuntu bash -lc 'nc -z -w 3 orchestrator 31358' 2>&1
    $ncExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($ncExit -ne 0) {
    throw 'FAIL: orchestrator is not reachable on LAN.'
}
Write-Host '  OK orchestrator reachable on LAN' -ForegroundColor Green
Write-Host 'deploy-grev27-pool-shard OK on gaming-b' -ForegroundColor Green
Write-Host 'Then from orchestrator: Start-Stop-AlfaAi.ps1 start and answer Y for gaming-b' -ForegroundColor Green
