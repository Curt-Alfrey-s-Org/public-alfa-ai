#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy gaming-c rpc-server shard :31351 for inference (RTX 5070).
.DESCRIPTION
    Run on gaming-worker-c when opted into inference at the next orchestrator cluster start.
    Not auto-deployed from orchestrator yet -- start this locally before answering Y for gaming-c.
.EXAMPLE
    cd C:\Users\YOURUSER\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\deploy-grev27-pool-shard.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Write-Host '== Phase H: Docker preflight on gaming-c ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-docker-engine.sh') -EnvPrefix 'HOST_LABEL=59 '

Write-Host '== Phase H: stop local llama / free GPU on gaming-c ==' -ForegroundColor Cyan
$repoWsl = ConvertTo-AlfaWslPath -WinPath $RepoDir
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'inference-stop-local.sh') `
    -EnvPrefix "inference_STOP_MODE=shard HOST_LABEL=59 ALFA_AI_REPO=$repoWsl "
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-gpu-empty.sh') -EnvPrefix 'HOST_LABEL=59 MAX_MIB=3072 '

$shardBlock = @"
# Phase H: gaming-c rpc-server shard for inference (:31351)
RPC_PORT=31351
CUDA_VISIBLE_DEVICES=0
"@

if (-not (Test-Path (Split-Path $EnvPath))) {
    New-Item -ItemType Directory -Path (Split-Path $EnvPath) -Force | Out-Null
}
Set-Content -Path $EnvPath -Value $shardBlock -Encoding ASCII
Write-Host "Wrote gaming-c shard env to $EnvPath" -ForegroundColor Green

. (Join-Path $Common 'deploy-llamacpp-rpc.ps1')
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $RepoDir -EnvFileRpc $EnvPath

Write-Host '== Phase H: LAN reachability check (orchestrator) ==' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ncExit = 1
try {
    $null = wsl.exe -d Ubuntu bash -lc 'nc -z -w 3 orchestrator 31351' 2>&1
    $ncExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($ncExit -ne 0) {
    throw 'FAIL: orchestrator is not reachable on LAN.'
}
Write-Host '  OK orchestrator reachable on LAN' -ForegroundColor Green
Write-Host 'deploy-grev27-pool-shard OK on gaming-c' -ForegroundColor Green
Write-Host 'Then from orchestrator: Start-Stop-AlfaAi.ps1 start and answer Y for gaming-c' -ForegroundColor Green
