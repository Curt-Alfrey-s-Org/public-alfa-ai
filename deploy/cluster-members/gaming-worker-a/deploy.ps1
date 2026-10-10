<#
.SYNOPSIS
    Deploy script for gaming-worker-a (orchestrator, Win10/WSL).
.DESCRIPTION
    Stages repo subset from SMB, brings up Dockge agent. llama.cpp RPC via
    deploy-llamacpp-rpc.ps1 when needed. Petals/Hivemind retired.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File `
        \\hub\temp\cluster_members\gaming-worker-a-219\deploy.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CommonDir       = Join-Path $PSScriptRoot '..\_common'
. (Join-Path $CommonDir 'initialize-windows-deploy.ps1')

$preflightScript = Join-Path $CommonDir 'nvidia-preflight.ps1'
$statsScript     = Join-Path $CommonDir 'write-system-stats.ps1'
$deployLibScript = Join-Path $CommonDir 'deploy-worker-lan.ps1'

if (Test-Path $preflightScript) {
    . $preflightScript
    Invoke-AlfaNvidiaPreflight -Role 'gpu-worker' | Out-Null
}
Initialize-AlfaWindowsDockerMirror
if (Test-Path $statsScript) { . $statsScript }

$MachineName = 'gaming-worker-a'
$MachineIP   = 'orchestrator'
$WorkerDir   = 'C:\alfa-ai-worker'

$smbRoot   = '\\hub\temp\cluster_members'
$smbMember = Join-Path $smbRoot 'gaming-worker-a-219'
$smbRepo   = Join-Path $smbRoot '_common\repo'

Write-Host ''
Write-Host "== Stage $MachineName from SMB ($smbRoot) ==" -ForegroundColor Cyan
if (-not (Test-Path $WorkerDir)) {
    New-Item -ItemType Directory -Path $WorkerDir -Force | Out-Null
}

if (Test-Path $smbRepo) {
    foreach ($sub in @('deploy','scripts')) {
        $src = Join-Path $smbRepo $sub
        $dst = Join-Path $WorkerDir $sub
        if (Test-Path $src) {
            Write-Host "  robocopy $sub\" -ForegroundColor Cyan
            & robocopy $src $dst /MIR /R:2 /W:2 /NP /NDL /NJH /NJS /MT:8 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy $sub failed (exit $LASTEXITCODE)" }
        } else {
            Write-Host "  WARN: $src missing -- re-run stage-cluster-members.ps1 on orchestrator" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "FAIL: $smbRepo not found. Run stage-cluster-members.ps1 on orchestrator first." -ForegroundColor Red
    exit 1
}

if (Get-Command Write-AlfaClusterSystemStats -ErrorAction SilentlyContinue) {
    Write-AlfaClusterSystemStats -WorkerDir $WorkerDir -MachineName $MachineName -MachineIP $MachineIP
}

if (-not (Test-Path $deployLibScript)) {
    throw "Missing $deployLibScript"
}
. $deployLibScript
Invoke-AlfaWorkerDeploy `
    -MachineName       $MachineName `
    -MachineIP         $MachineIP `
    -WorkerDir         $WorkerDir `
    -DockgePortDefault '5003' `
    -IncludeLlamacppRpc
