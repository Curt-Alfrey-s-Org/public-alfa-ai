#Requires -Version 5.1
<#
.SYNOPSIS
    Load louislam/dockge:1 from the hub tarball and start primary Dockge on orchestrator.
    Does not start or restart llamacpp-rpc / inference containers.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CommonDir = Join-Path $PSScriptRoot '..\_common'
. (Join-Path $CommonDir 'initialize-windows-deploy.ps1')
. (Join-Path $CommonDir 'load-hub-tarball.ps1')
. (Join-Path $CommonDir 'sync-dockge-stacks-windows.ps1')
. (Join-Path $CommonDir 'Wait-AlfaHttpPoll.ps1')

if (-not (Initialize-AlfaDockerCli)) {
    throw 'Docker engine not reachable. Run: wsl -d Ubuntu sudo service docker start'
}

$loaded = Invoke-AlfaHubTarballLoad -Tarball 'louislam-dockge-1.tar.gz' -ImageTag 'louislam/dockge:1'
if (-not $loaded) {
    throw 'Failed to load louislam/dockge:1 from hub tarball louislam-dockge-1.tar.gz'
}

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$DockgeDir = Join-Path $CommonDir 'dockge'
$dockgePort = '5002'

Write-Host ''
Write-Host '== orchestrator primary Dockge (UI only; no inference) ==' -ForegroundColor Cyan

$stacksDir = Sync-Alfaoperator93DockgeStacks -RepoDir $RepoDir

$dockgeCompose = Join-Path $DockgeDir 'docker-compose.dockge.yml'
$dockgeEnvFile = Join-Path $DockgeDir 'dockge.local.env'
$dockgeDataDir = 'C:\alfa-ai-dockge\data'
if (-not (Test-Path $dockgeDataDir)) {
    New-Item -ItemType Directory -Path $dockgeDataDir -Force | Out-Null
}

$stacksNorm = ConvertTo-AlfaDockerHostPath -Path $stacksDir
$dataNorm = ConvertTo-AlfaDockerHostPath -Path $dockgeDataDir
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($dockgeEnvFile, @(
    "DOCKGE_HOST_PORT=$dockgePort"
    "DOCKGE_DATA_HOST=$dataNorm"
    "DOCKGE_STACKS_HOST=$stacksNorm"
), $utf8NoBom)

Push-Location $DockgeDir
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker rm -f alfa-dockge 2>&1 | Out-Null
    & docker compose -f docker-compose.dockge.yml --env-file dockge.local.env up -d 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "alfa-dockge up failed (exit $LASTEXITCODE)" }
} finally {
    $ErrorActionPreference = $prevEAP
    Pop-Location
}

$url = "http://127.0.0.1:${dockgePort}/"
$ready = Wait-AlfaHttpPoll -Url $url -TimeoutSec 60
if (-not $ready) {
    throw "Dockge UI did not respond at $url"
}
Write-Host "  Primary Dockge: $url" -ForegroundColor Green
Write-Host "  Stacks folder:  $stacksDir" -ForegroundColor Green
Write-Host '  Remote agents: Settings -> add http://<lan-ip>:5001/ (see DOCKGE_AGENTS_WORKERS.md)' -ForegroundColor Cyan
