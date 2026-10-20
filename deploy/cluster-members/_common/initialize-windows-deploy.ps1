<#
.SYNOPSIS
    Shared bootstrap for all Windows cluster-member deploy entry points.

.DESCRIPTION
    Dot-source once from deploy.ps1, run.ps1 / invoke-worker-oneshot.ps1, and
    focused deploy helpers (gateway, llama.cpp RPC).

    Loads:
      - hub-fallback-prompt.ps1 (operator gate before PyPI / source builds)
      - wsl-docker.ps1 (route docker CLI through WSL Ubuntu when Desktop absent)
      - load-hub-tarball.ps1 (optional; call Import-AlfaHubTarballLoader)

    See docs/WINDOWS_WSL_DOCKER_ENGINE.md and ALFA_HUB_FALLBACK env var.
#>

Set-StrictMode -Version Latest

$script:AlfaWindowsDeployCommonDir = $PSScriptRoot

foreach ($helper in @('hub-fallback-prompt.ps1', 'wsl-docker.ps1', 'Get-AlfaWindowsCacheRoot.ps1')) {
    $path = Join-Path $PSScriptRoot $helper
    if (Test-Path -LiteralPath $path) {
        . $path
    }
}

function Import-AlfaHubTarballLoader {
    if (Get-Command Invoke-AlfaHubTarballLoad -ErrorAction SilentlyContinue) {
        return
    }
    $loader = Join-Path $script:AlfaWindowsDeployCommonDir 'load-hub-tarball.ps1'
    if (-not (Test-Path -LiteralPath $loader)) {
        throw "Hub tarball loader missing: $loader (git pull --ff-only origin main)"
    }
    . $loader
    if (-not (Get-Command Invoke-AlfaHubTarballLoad -ErrorAction SilentlyContinue)) {
        throw "Failed to define Invoke-AlfaHubTarballLoad after dot-sourcing: $loader"
    }
}

function Test-AlfaWindowsDockerEngine {
    if (Get-Command Initialize-AlfaDockerCli -ErrorAction SilentlyContinue) {
        return Initialize-AlfaDockerCli
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = docker.exe version 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
}

function Initialize-AlfaWindowsDockerMirror {
    param(
        [string]$MirrorUrl = 'http://hub'
    )

    $mirrorScript = Join-Path $script:AlfaWindowsDeployCommonDir 'configure-docker-mirror.ps1'
    if (-not (Test-Path -LiteralPath $mirrorScript)) {
        return
    }
    . $mirrorScript
    if (Get-Command Test-AlfaNativeDockerEngine -ErrorAction SilentlyContinue) {
        if (Test-AlfaNativeDockerEngine) {
            Configure-AlfaDockerMirror -MirrorUrl $MirrorUrl
        } else {
            Write-Host '[docker-mirror] skip Windows daemon.json (WSL Engine uses /etc/docker/daemon.json)' -ForegroundColor DarkGray
        }
    } else {
        Configure-AlfaDockerMirror -MirrorUrl $MirrorUrl
    }
}

function Assert-AlfaWindowsDockerEngine {
    if (-not (Test-AlfaWindowsDockerEngine)) {
        throw @'
Docker engine is not reachable.

WSL path:  wsl -d Ubuntu docker ps
Desktop:   start Docker Desktop and wait until Engine running
'@
    }
}
