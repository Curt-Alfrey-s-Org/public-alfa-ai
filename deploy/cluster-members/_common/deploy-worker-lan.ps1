<#
.SYNOPSIS
    Shared LAN-first worker deploy helper for Win11/WSL cluster members
    (gaming-b gaming-worker-b, gaming-c gaming-worker-c, gaming-a gaming-worker-a).
.DESCRIPTION
    Stages Dockge agent stacks, the GPU worker-monitor sidecar (:31331),
    and optional llama.cpp RPC compose files.
    Petals/Hivemind workers stay retired -- inference is llama.cpp RPC only.

.PARAMETER MachineName
    Short logical name (gaming-worker-b, gaming-worker-c, gaming-worker-a).
.PARAMETER MachineIP
    LAN IPv4 for Dockge agent registration URL.
.PARAMETER WorkerDir
    Local worker root (C:\alfa-ai-worker).
.PARAMETER DockgePortDefault
    Fallback Dockge port when member .env.dockge omits ALFA_DOCKGE_HOST_PORT.
#>

function Invoke-AlfaWorkerDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$MachineIP,
        [Parameter(Mandatory)] [string]$WorkerDir,
        [string]$DockgePortDefault = '5001',
        [switch]$IncludeLlamacppRpc
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $CommonDir = $PSScriptRoot
    $DockgeDir = Join-Path $CommonDir 'dockge'
    $syncScript = Join-Path $CommonDir 'sync-dockge-stacks-windows.ps1'
    if (Test-Path $syncScript) { . $syncScript }

    if (-not (Test-Path $WorkerDir)) {
        throw "[worker-deploy] WorkerDir missing: $WorkerDir"
    }

    function Read-WorkerEnvValue {
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

    Write-Host ''
    Write-Host "== ALFa worker deploy: $MachineName ($MachineIP) ==" -ForegroundColor Cyan
    Write-Host "  WorkerDir: $WorkerDir"
    Write-Host ''

    $memberEnv = Join-Path $WorkerDir 'deploy\cluster-members\_worker\.env.dockge'
    if (-not (Test-Path $memberEnv)) {
        $memberEnv = Join-Path $WorkerDir '.env.dockge'
    }
    $dockgePort = Read-WorkerEnvValue $memberEnv 'ALFA_DOCKGE_HOST_PORT' $DockgePortDefault

    $stacksDir = Sync-AlfaWorkerDockgeStacks -WorkerDir $WorkerDir -IncludeLlamacppRpc:$IncludeLlamacppRpc

    $dockgeCompose = Join-Path $DockgeDir 'docker-compose.dockge.yml'
    $dockgeEnvFile = Join-Path $DockgeDir 'dockge.local.env'
    $dockgeDataDir = Join-Path $WorkerDir 'dockge-data'

    if (-not (Test-Path $dockgeCompose)) {
        $dockgeCompose = Join-Path $WorkerDir 'deploy\cluster-members\_common\dockge\docker-compose.dockge.yml'
        $dockgeEnvFile = Join-Path $WorkerDir 'deploy\cluster-members\_common\dockge\dockge.local.env'
    }

    if (-not (Test-Path $dockgeCompose)) {
        throw "[worker-deploy] Dockge compose missing under $DockgeDir"
    }

    if (-not (Test-Path $dockgeDataDir)) {
        New-Item -ItemType Directory -Path $dockgeDataDir -Force | Out-Null
    }

    $stacksNorm = ConvertTo-AlfaDockerHostPath -Path $stacksDir
    $dataNorm   = ConvertTo-AlfaDockerHostPath -Path $dockgeDataDir
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($dockgeEnvFile, @(
        "DOCKGE_HOST_PORT=$dockgePort"
        "DOCKGE_DATA_HOST=$dataNorm"
        "DOCKGE_STACKS_HOST=$stacksNorm"
    ), $utf8NoBom)

    Push-Location (Split-Path -Parent $dockgeCompose)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker rm -f alfa-dockge 2>&1 | Out-Null
        & docker compose -f (Split-Path -Leaf $dockgeCompose) --env-file (Split-Path -Leaf $dockgeEnvFile) down 2>&1 | Out-Null
        & docker compose -f (Split-Path -Leaf $dockgeCompose) --env-file (Split-Path -Leaf $dockgeEnvFile) up -d 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Dockge agent: http://$MachineIP`:$dockgePort/" -ForegroundColor Green
        } else {
            throw "Dockge compose up failed (exit $LASTEXITCODE)"
        }
    } finally {
        $ErrorActionPreference = $prev
        Pop-Location
    }

    $monitorDir = Join-Path $CommonDir 'worker-monitor'
    $monitorCompose = Join-Path $monitorDir 'docker-compose.worker-monitor.yml'
    $monitorScript = Join-Path $monitorDir 'monitor.py'
    if ((Test-Path $monitorCompose) -and (Test-Path $monitorScript)) {
        Write-Host ''
        Write-Host '== worker-monitor :31331 (GPU stats, not Petals) ==' -ForegroundColor Cyan
        $scriptHost = ConvertTo-AlfaDockerHostPath -Path $monitorScript
        $monitorEnv = Join-Path $monitorDir 'worker-monitor.local.env'
        [System.IO.File]::WriteAllLines($monitorEnv, @(
            "MONITOR_SCRIPT_HOST=$scriptHost"
            "WORKER_NAME=$MachineName"
            "WORKER_ROLE=gpu-worker"
            "MONITOR_PORT=31331"
        ), $utf8NoBom)
        Push-Location $monitorDir
        $prevMon = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & docker rm -f worker-monitor 2>&1 | Out-Null
            & docker compose -f 'docker-compose.worker-monitor.yml' --env-file 'worker-monitor.local.env' up -d 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                throw "worker-monitor compose up failed (exit $LASTEXITCODE)"
            }
            Write-Host "  worker-monitor: http://$MachineIP`:31331/health" -ForegroundColor Green
        } finally {
            $ErrorActionPreference = $prevMon
            Pop-Location
        }
    }

    Write-Host ''
    Write-Host "== $MachineName worker deploy complete ==" -ForegroundColor Green
    Write-Host "  Register agent: http://$MachineIP`:$dockgePort/ on orchestrator primary Dockge"
    Write-Host ''
}
