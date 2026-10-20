<#
.SYNOPSIS
    Deploy script for orchestrator (Win11). Role: primary Dockge UI + llama.cpp RPC shards.
.DESCRIPTION
    April 2026 cluster: brain on hub hub; orchestrator runs primary Dockge UI and
    optional llama.cpp rpc-server / Ollama CPU tiers. Petals/Hivemind retired.

    Flow:
        1. nvidia-preflight (GPU facts for rpc-server deploy scripts)
        2. Configure Docker LAN registry mirror
        3. Git pull
        4. Load pre-built Docker images from hub (optional)
        5. Ensure tunnel_network exists
        6. Bring up primary Dockge (alfa-dockge) on this host
        7. Print agent URLs for remote Dockge registration

.EXAMPLE
    cd C:/Users/operator\alfa-ai
    .\deploy\cluster-members\orchestrator\deploy.ps1
.PARAMETER SkipPull
    Skip `git pull --ff-only origin main` at step 1.
#>

param(
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:DOCKER_BUILDKIT = '1'
$env:COMPOSE_DOCKER_CLI_BUILD = '1'

$CommonDir = Join-Path $PSScriptRoot '..\_common'
. (Join-Path $CommonDir 'initialize-windows-deploy.ps1')
Import-AlfaHubTarballLoader
. (Join-Path $CommonDir 'sync-dockge-stacks-windows.ps1')

$preflightScript = Join-Path $CommonDir 'nvidia-preflight.ps1'
$agentScript     = Join-Path $CommonDir 'install-dockge-agent.ps1'

if (Test-Path $preflightScript) {
    . $preflightScript
    Invoke-AlfaNvidiaPreflight -Role 'gpu-worker' | Out-Null
}
Initialize-AlfaWindowsDockerMirror
if (Test-Path $agentScript) { . $agentScript }

$RepoDir   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$DeployDir = Join-Path $RepoDir 'deploy'
$DockgeDir = Join-Path $CommonDir 'dockge'
$StacksDir = Sync-Alfaoperator93DockgeStacks -RepoDir $RepoDir

Write-Host ''
Write-Host '== ALFa AI orchestrator Deploy: Primary Dockge + llama.cpp RPC host ==' -ForegroundColor Cyan
Write-Host "  Brain:  http://hub (hub)"
Write-Host "  Repo:   $RepoDir"
Write-Host ''

function Read-DeployEnvPort {
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

if (-not $SkipPull) {
    Write-Host '== 1. Git pull ==' -ForegroundColor Cyan
    Push-Location $RepoDir
    try {
        & git pull --ff-only origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'WARN: git pull failed. Resolve conflicts manually.' -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }
    Write-Host ''
} else {
    Write-Host '== 1. Git pull (skipped -SkipPull) ==' -ForegroundColor DarkGray
    Write-Host ''
}

if (-not (Test-AlfaWindowsDockerEngine)) {
    Write-Host ''
    Write-Host 'ERROR: Docker engine is not reachable.' -ForegroundColor Red
    Write-Host '  - WSL: wsl -d Ubuntu docker ps (install via deploy/cluster-members/_common/wsl-docker/02-install-docker-wsl-engine.ps1)' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$portPreflightScript = Join-Path $CommonDir 'Test-AlfaWindowsDeployPortPreflight.ps1'
if (Test-Path -LiteralPath $portPreflightScript) {
    . $portPreflightScript
    if (-not (Test-AlfaWindowsDeployPortPreflight -Profile 'operator-93')) {
        exit 1
    }
    Write-Host ''
}

Write-Host '== 2. Loading pre-built Docker images (hub-first, local cache) ==' -ForegroundColor Cyan
$hubImagesRoot = '\\hub\docker-images'
$localCacheDir = Get-AlfaWindowsDockerImagesCacheDir
$tarballsForHost = @()

$hubLoaderPath = Join-Path $CommonDir 'load-hub-tarball.ps1'
if (-not (Get-Command Invoke-AlfaHubTarballLoad -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath $hubLoaderPath) { . $hubLoaderPath }
}
if (Get-Command Invoke-AlfaHubTarballLoad -ErrorAction SilentlyContinue) {
    foreach ($tb in $tarballsForHost) {
        Write-Host "  -- $tb --" -ForegroundColor Cyan
        $null = Invoke-AlfaHubTarballLoad -Tarball $tb -HubRoot $hubImagesRoot -LocalCacheDir $localCacheDir
    }
} else {
    Write-Host '  SKIP: hub tarball loader not available' -ForegroundColor Yellow
}
Write-Host ''

Write-Host '== 3. Docker network ==' -ForegroundColor Cyan
$prevEA = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
try {
    $netExists = (docker network ls --filter name=tunnel_network --format '{{.Name}}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Docker engine unreachable' }
    if (-not $netExists) {
        docker network create tunnel_network 2>&1 | Out-Null
        Write-Host '  Created tunnel_network'
    } else {
        Write-Host '  tunnel_network exists'
    }
} finally {
    $ErrorActionPreference = $prevEA
}
Write-Host ''

Write-Host '== 4. Primary Dockge UI (alfa-dockge) ==' -ForegroundColor Cyan
$dockgeCompose = Join-Path $DockgeDir 'docker-compose.dockge.yml'
$dockgeEnvFile = Join-Path $DockgeDir 'dockge.local.env'
$dockgeDataDir = 'C:\alfa-ai-dockge\data'
$dockgePort    = Read-DeployEnvPort (Join-Path $DeployDir '.env') 'ALFA_DOCKGE_HOST_PORT' '5002'

if (-not (Test-Path $dockgeCompose)) {
    Write-Host "  SKIP: $dockgeCompose missing" -ForegroundColor Yellow
} else {
    if (-not (Test-Path $dockgeDataDir)) {
        New-Item -ItemType Directory -Path $dockgeDataDir -Force | Out-Null
    }
    $stacksNorm = ConvertTo-AlfaDockerHostPath -Path $StacksDir
    $dataNorm   = ConvertTo-AlfaDockerHostPath -Path $dockgeDataDir
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($dockgeEnvFile, @(
        "DOCKGE_HOST_PORT=$dockgePort"
        "DOCKGE_DATA_HOST=$dataNorm"
        "DOCKGE_STACKS_HOST=$stacksNorm"
    ), $utf8NoBom)

    Push-Location $DockgeDir
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker rm -f alfa-dockge 2>&1 | Out-Null
        & docker compose -f docker-compose.dockge.yml --env-file dockge.local.env down 2>&1 | Out-Null
        & docker compose -f docker-compose.dockge.yml --env-file dockge.local.env up -d 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Primary Dockge: http://127.0.0.1:${dockgePort}/" -ForegroundColor Green
        } else {
            Write-Host '  WARN: Dockge compose up failed' -ForegroundColor Yellow
        }
    } finally {
        $ErrorActionPreference = $prev
        Pop-Location
    }
}
Write-Host ''

Write-Host '== 5. Remote Dockge agents ==' -ForegroundColor Cyan
$agents = @(
    @{ name = 'brain-111';    url = 'http://hub/' },
    @{ name = 'apps-105';     url = 'http://apps/'  },
    @{ name = 'ai-148';       url = 'http://orchestrator/'  },
    @{ name = 'gaming-worker-b-249';    url = 'http://orchestrator/'  },
    @{ name = 'gaming-worker-c-59';   url = 'http://orchestrator/'   },
    @{ name = 'gaming-worker-a-219';url = 'http://orchestrator/'  }
)
if (Get-Command Register-AlfaDockgeAgents -ErrorAction SilentlyContinue) {
    Register-AlfaDockgeAgents -PrimaryUrl "http://127.0.0.1:$dockgePort" -Agents $agents
} else {
    Write-Host '  Register these in Dockge UI -> Settings -> Remote agents:' -ForegroundColor Yellow
    $agents | ForEach-Object { Write-Host "    $($_.name)  $($_.url)" }
}
Write-Host ''

Write-Host '== orchestrator Deploy Complete ==' -ForegroundColor Green
Write-Host ''
Write-Host "  Role:    primary Dockge UI + llama.cpp RPC / Ollama CPU tiers"
Write-Host "  Brain:   http://hub"
Write-Host "  Dockge:  http://127.0.0.1:$dockgePort/"
Write-Host "  RPC:     deploy-llamacpp-rpc.ps1 (inference shards; see docs/LLAMACPP_RPC_OPERATOR.md)"
Write-Host ''
