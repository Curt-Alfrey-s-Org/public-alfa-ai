<#
.SYNOPSIS
    Install and start a Dockge agent on a Windows / WSL worker node.
#>

function Install-AlfaDockgeAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$MachineName,
        [Parameter(Mandatory=$true)][string]$MachineIP,
        [string]$DockgePort = '5001',
        [string]$WorkerDir  = 'C:\alfa-ai-worker',
        [string]$SmbRoot    = '\\hub\temp\cluster_members',
        [string]$MirrorUrl  = 'http://hub'
    )

    $ErrorActionPreference = 'Stop'
    $commonDir = $PSScriptRoot

    $preflight = Join-Path $commonDir 'nvidia-preflight.ps1'
    if (Test-Path $preflight) {
        Write-Host '[install-dockge-agent] running nvidia preflight...' -ForegroundColor Cyan
        . $preflight
        Invoke-AlfaNvidiaPreflight -Role 'gpu-worker' | Out-Null
    }

    $mirrorHelper = Join-Path $commonDir 'configure-docker-mirror.ps1'
    if (Test-Path $mirrorHelper) {
        Write-Host '[install-dockge-agent] configuring registry mirror...' -ForegroundColor Cyan
        . $mirrorHelper
        Configure-AlfaDockerMirror -MirrorUrl $MirrorUrl
    }

    $stacksDir = Join-Path $WorkerDir 'stacks'
    $dataDir   = Join-Path $WorkerDir 'dockge-data'
    foreach ($d in @($WorkerDir, $stacksDir, $dataDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $dockgeDir = Join-Path $commonDir 'dockge'
    $dockgeCompose = Join-Path $dockgeDir 'docker-compose.dockge.yml'
    if (-not (Test-Path $dockgeCompose)) {
        Write-Host "  SKIP: $dockgeCompose not found" -ForegroundColor Yellow
        return
    }

    $stacksNorm = ConvertTo-AlfaDockerHostPath -Path $stacksDir
    $dataNorm   = ConvertTo-AlfaDockerHostPath -Path $dataDir
    $envFile = Join-Path $dockgeDir 'dockge.local.env'
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($envFile, @(
        "DOCKGE_HOST_PORT=$DockgePort"
        "DOCKGE_DATA_HOST=$dataNorm"
        "DOCKGE_STACKS_HOST=$stacksNorm"
    ), $utf8NoBom)

    Push-Location $dockgeDir
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker rm -f alfa-dockge 2>&1 | Out-Null
        & docker compose -f docker-compose.dockge.yml --env-file dockge.local.env down 2>&1 | Out-Null
        & docker compose -f docker-compose.dockge.yml --env-file dockge.local.env up -d 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  WARN: Dockge agent compose up failed' -ForegroundColor Yellow
        } else {
            Write-Host ''
            Write-Host "[install-dockge-agent] Agent ready:" -ForegroundColor Green
            Write-Host "  local:  http://127.0.0.1:${DockgePort}/"
            Write-Host "  LAN:    http://${MachineIP}:${DockgePort}/  <-- add this in primary Dockge on orchestrator" -ForegroundColor Cyan
            Write-Host ''
        }
    } finally {
        $ErrorActionPreference = $prev
        Pop-Location
    }
}

function Register-AlfaDockgeAgents {
    param(
        [Parameter(Mandatory=$true)][string]$PrimaryUrl,
        [Parameter(Mandatory=$true)][object[]]$Agents,
        [string]$User,
        [string]$Pass
    )
    $ErrorActionPreference = 'Continue'
    Write-Host "[register-agents] target: $PrimaryUrl" -ForegroundColor Cyan
    foreach ($agent in $Agents) {
        Write-Host "  - $($agent.name) -> $($agent.url)"
    }
    Write-Host "  NOTE: paste these under Settings > Remote agents on the primary UI." -ForegroundColor Yellow
}
