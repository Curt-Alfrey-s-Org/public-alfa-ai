<#
.SYNOPSIS
    Re-stage a Windows/WSL worker for Dockge control and restart the Dockge agent.

.DESCRIPTION
    Copies compose files into <WorkerDir>\stacks\<name>\, re-runs compose up from those
    folders (so Dockge shows stacks as managed), and recreates alfa-dockge with
    DOCKGE_STACKS_HOST pointing at stacks\.

.PARAMETER WorkerDir
    Worker root (default C:\alfa-ai-worker).

.PARAMETER MachineIP
    LAN IP printed in the summary (e.g. orchestrator).

.PARAMETER DockgePortDefault
    Host port when .env.dockge omits ALFA_DOCKGE_HOST_PORT (gaming-a = 5003).
#>
[CmdletBinding()]
param(
    [string]$WorkerDir = 'C:\alfa-ai-worker',
    [Parameter(Mandatory)]
    [string]$MachineIP,
    [string]$DockgePortDefault = '5001',
    [switch]$IncludeLlamacppRpc,
    [switch]$SkipWorkerUp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CommonDir = $PSScriptRoot
. (Join-Path $CommonDir 'initialize-windows-deploy.ps1')
. (Join-Path $CommonDir 'sync-dockge-stacks-windows.ps1')

if (-not (Initialize-AlfaDockerCli)) {
    throw 'Docker engine not reachable. Run: wsl -d Ubuntu sudo service docker start'
}

function Read-StackEnvValue {
    param([string]$EnvPath, [string]$Key, [string]$Default)
    if (-not (Test-Path $EnvPath)) { return $Default }
    foreach ($line in Get-Content $EnvPath) {
        $t = $line.Trim()
        if ($t -match '^\s*#' -or $t -eq '') { continue }
        if ($t -match "^\s*$([Regex]::Escape($Key))=(.+)$") {
            return $matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $Default
}

$envDockge = Join-Path $WorkerDir '.env.dockge'
$dockgePort = Read-StackEnvValue $envDockge 'ALFA_DOCKGE_HOST_PORT' $DockgePortDefault

Write-Host ''
Write-Host "== reconcile Dockge stacks (worker $MachineIP) ==" -ForegroundColor Cyan
Write-Host "  WorkerDir: $WorkerDir"
Write-Host "  Dockge:    http://127.0.0.1:${dockgePort}/"
Write-Host ''

$stacksDir = Sync-AlfaWorkerDockgeStacks -WorkerDir $WorkerDir -IncludeLlamacppRpc:$IncludeLlamacppRpc

if (-not $SkipWorkerUp -and $IncludeLlamacppRpc) {
    $rpcStack = Join-Path $stacksDir 'llamacpp-rpc'
    if (Test-Path $rpcStack) {
        Write-Host '== llamacpp-rpc stack (Dockge-managed) ==' -ForegroundColor Cyan
        $prevRm = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & docker rm -f llamacpp-rpc-server 2>&1 | Out-Null
        $ErrorActionPreference = $prevRm

        Push-Location $rpcStack
        try {
            & docker compose -f docker-compose.rpc-server.yml --env-file .env.rpc up -d --no-build
            if ($LASTEXITCODE -ne 0) {
                & docker compose -f docker-compose.rpc-server.yml --env-file .env.rpc up -d
                if ($LASTEXITCODE -ne 0) { throw "llamacpp-rpc up failed (exit $LASTEXITCODE)" }
            }
            Write-Host '  llamacpp-rpc stack up (Dockge-managed path)' -ForegroundColor Green
        } finally {
            Pop-Location
        }
        Write-Host ''
    }
}

Write-Host '== Dockge agent ==' -ForegroundColor Cyan
$dockgeDir = Join-Path $WorkerDir 'deploy\cluster-members\_common\dockge'
$dockgeCompose = Join-Path $dockgeDir 'docker-compose.dockge.yml'
$dockgeEnvFile = Join-Path $dockgeDir 'dockge.local.env'
$dockgeDataDir = Join-Path $WorkerDir 'dockge-data'
if (-not (Test-Path $dockgeDataDir)) {
    New-Item -ItemType Directory -Path $dockgeDataDir -Force | Out-Null
}

$stacksNorm = ConvertTo-AlfaDockerHostPath -Path $stacksDir
$dataNorm   = ConvertTo-AlfaDockerHostPath -Path $dockgeDataDir
$utf8NoBom  = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($dockgeEnvFile, @(
    "DOCKGE_HOST_PORT=$dockgePort"
    "DOCKGE_DATA_HOST=$dataNorm"
    "DOCKGE_STACKS_HOST=$stacksNorm"
), $utf8NoBom)

Push-Location $dockgeDir
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker rm -f alfa-dockge 2>&1 | Out-Null
    & docker compose -f docker-compose.dockge.yml --env-file dockge.local.env up -d 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "alfa-dockge up failed (exit $LASTEXITCODE)" }
    Write-Host "  Dockge agent: http://127.0.0.1:${dockgePort}/" -ForegroundColor Green
    Write-Host "  LAN register: http://${MachineIP}:${dockgePort}/  (on orchestrator primary UI)" -ForegroundColor Cyan
    Write-Host "  Stacks folder: $stacksDir" -ForegroundColor Green
} finally {
    $ErrorActionPreference = $prevEAP
    Pop-Location
}

Write-Host ''
Write-Host 'Open Dockge -> Current. Stop llamacpp-rpc before gaming if present.' -ForegroundColor Cyan
Write-Host ''
