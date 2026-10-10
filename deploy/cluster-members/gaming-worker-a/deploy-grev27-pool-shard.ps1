#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy gaming-a rpc-server shard :31352 for inference (RTX 5060 8 GB).
.EXAMPLE
    cd C:\Users\Corey\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\deploy-grev27-pool-shard.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'
$Llc = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$EnvPath = Join-Path $Llc '.env.rpc'

. (Join-Path $PSScriptRoot 'Initialize-GamingWorkerCache.ps1')
Initialize-GamingWorkerWindowsCache | Out-Null

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

Write-Host '== Phase H: Docker preflight on gaming-a ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-docker-engine.sh') -EnvPrefix 'HOST_LABEL=219 '

# Hub image load is handled by Invoke-AlfaLlamacppRpcDeploy (picker cache root\docker-images
# first; UNC/SMB may be Access Denied for Corey). Do not duplicate a brittle preflight here.

$natScript = Join-Path $Common 'install-wsl-nat-portproxy.ps1'
if (Test-Path -LiteralPath $natScript) {
    . $natScript
    if (Test-AlfaWslNatPortProxyRequired) {
        Write-Host '== Phase H: Win10 NAT portproxy (:31352 + Dockge :5003) ==' -ForegroundColor Cyan
        $proxyOk = Sync-AlfaWslNatPortProxy `
            -TcpPorts 31330, 31331, 5003, 31352 `
            -DisplayNamePrefix 'ALFa gaming-worker-a-219' `
            -RepoRoot $RepoDir
        if (-not $proxyOk) {
            throw 'FAIL: WSL NAT portproxy refresh failed for :31352 (run install-wsl-nat-portproxy.ps1 once as Admin)'
        }
    }
}

Write-Host '== Phase H: stop local llama / free GPU on gaming-a ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'inference-stop-local.sh') -EnvPrefix 'inference_STOP_MODE=shard HOST_LABEL=219 ALFA_AI_REPO=/mnt/c/Users/Corey/alfa-ai '
# Win10/WDDM reserve ~3 GB on RTX 5060; allow up to 3072 MiB already used.
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-gpu-empty.sh') -EnvPrefix 'HOST_LABEL=219 MAX_MIB=3072 '

$shardBlock = @"
# Phase H: gaming-a rpc-server shard for 27B/35B pool (:31352)
RPC_PORT=31352
CUDA_VISIBLE_DEVICES=0
"@

if (-not (Test-Path (Split-Path $EnvPath))) {
    New-Item -ItemType Directory -Path (Split-Path $EnvPath) -Force | Out-Null
}
Set-Content -Path $EnvPath -Value $shardBlock -Encoding ASCII
Write-Host "Wrote gaming-a shard env to $EnvPath" -ForegroundColor Green

. (Join-Path $Common 'deploy-llamacpp-rpc.ps1')
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $RepoDir -EnvFileRpc $EnvPath

Write-Host '== Phase H: LAN reachability check (orchestrator) ==' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ncExit = 1
try {
    $null = wsl.exe -d Ubuntu bash -lc 'nc -z -w 3 orchestrator 31352' 2>&1
    $ncExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($ncExit -ne 0) {
    throw @(
        'FAIL: orchestrator is not reachable on LAN.',
        'Confirm Win10 portproxy includes :31352 and host firewall allows orchestrator/24.'
    ) -join "`n"
}
Write-Host '  OK orchestrator reachable on LAN' -ForegroundColor Green

Write-Host 'deploy-grev27-pool-shard OK on gaming-a' -ForegroundColor Green
Write-Host 'Verify from hub: nc -zv orchestrator 31352' -ForegroundColor Green
