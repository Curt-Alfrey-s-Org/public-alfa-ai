<#
.SYNOPSIS
    Self-healing environment readiness for ALFa AI Windows workers.
    Auto-installs missing prerequisites, auto-starts Docker Desktop, waits
    for the engine, verifies SMB hub reachability. Throws only when a
    problem is outside the script's authority to fix.
.DESCRIPTION
    Call Ensure-AlfaWorkerEnvironment at the very top of any worker deploy
    path. It is idempotent and safe to call repeatedly. Behaviour:

      Ensure-AlfaGitInstalled
        - If `git` is on PATH, no-op.
        - Else `winget install --id Git.Git -e` (non-interactive),
          refreshes session PATH so subsequent `git` calls work without
          opening a new shell.

      Ensure-AlfaDockerDesktop -TimeoutSec N
        - If `docker info` succeeds, no-op.
        - Else find Docker Desktop.exe in the standard locations and start
          it hidden if not already running, then poll `docker info` up
          to N seconds. First-ever start can take 60-120s while WSL2
          spins up; we wait and report progress, not fail instantly.
        - If Docker Desktop is not installed, attempts a winget install.

      Ensure-AlfaHubReachable -HubHost H
        - Pings the hub hub with a cheap TCP probe on SMB (445) to
          catch "DNS works but host is down" before the first robocopy.

    Returns nothing. Throws on a failure that user intervention is
    actually required for.

.EXAMPLE
    . "$PSScriptRoot\ensure-worker-environment.ps1"
    Ensure-AlfaWorkerEnvironment
#>

Set-StrictMode -Version Latest

function Test-AlfaDockerReady {
    [CmdletBinding()]
    param()
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Update-AlfaSessionPath {
    [CmdletBinding()]
    param()
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path','User')
    $combined    = @($machinePath, $userPath) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd(';') }
    $env:Path = ($combined -join ';')
}

function Ensure-AlfaGitInstalled {
    [CmdletBinding()]
    param()
    if (Get-Command git -ErrorAction SilentlyContinue) { return }

    Write-Host '  git missing on PATH. Installing via winget...' -ForegroundColor Yellow
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "git is missing and winget is unavailable. Install git manually (https://git-scm.com/download/win) and retry."
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & winget install --id Git.Git -e --source winget `
            --accept-source-agreements --accept-package-agreements `
            --silent | Out-Null
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($exit -ne 0) {
        throw "winget install Git.Git failed (exit $exit). Install git manually from https://git-scm.com/download/win."
    }
    Update-AlfaSessionPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git installed but not on PATH for this session. Close and re-open PowerShell, then retry."
    }
    Write-Host "  git installed: $((& git --version) 2>&1)" -ForegroundColor Green
}

function Get-AlfaDockerDesktopExe {
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Ensure-AlfaDockerEngine {
    [CmdletBinding()]
    param(
        [int]$TimeoutSec = 180,
        [int]$PollSec    = 3
    )

    $requireWslEngine = $false
    $wslDockerScript = Join-Path $PSScriptRoot 'wsl-docker.ps1'
    if (Test-Path -LiteralPath $wslDockerScript) {
        . $wslDockerScript
        $requireWslEngine = Test-AlfaRequireWslDockerEngine
        if (-not (Initialize-AlfaDockerCli)) {
            if ($requireWslEngine) {
                Write-Host '  WSL Docker Engine not initialized (Win10 NAT requires WSL, not Docker Desktop).' -ForegroundColor Yellow
            }
        }
    }

    if (Test-AlfaDockerReady) {
        Write-Host '  Docker engine reachable.' -ForegroundColor Green
        return
    }

    if (Get-Command Start-AlfaWslDockerService -ErrorAction SilentlyContinue) {
        Start-AlfaWslDockerService
        $waited = 0
        while (-not (Test-AlfaDockerReady)) {
            if ($waited -ge $TimeoutSec) { break }
            Start-Sleep -Seconds $PollSec
            $waited += $PollSec
            if (($waited % 15) -eq 0) {
                Write-Host "    still waiting for WSL Docker ($waited / $TimeoutSec s)..." -ForegroundColor Yellow
            }
        }
        if (Test-AlfaDockerReady) {
            Write-Host '  Docker engine reachable (WSL Ubuntu).' -ForegroundColor Green
            return
        }
    }

    if ($requireWslEngine) {
        throw "WSL Docker Engine required (Win10 NAT portproxy) but not ready after ${TimeoutSec}s. From PowerShell: wsl -d Ubuntu sudo service docker start"
    }

    if (Get-AlfaDockerDesktopExe) {
        Ensure-AlfaDockerDesktop -TimeoutSec $TimeoutSec -PollSec $PollSec
    } else {
        throw @"
Docker engine not reachable. Docker Desktop is not installed on this host.
Use WSL Ubuntu:
  wsl --shutdown
  wsl -d Ubuntu sudo service docker start
  wsl -d Ubuntu docker ps
Then dot-source initialize-windows-deploy.ps1 and run Initialize-AlfaDockerCli before deploy scripts.
"@
    }
}

function Ensure-AlfaDockerDesktop {
    [CmdletBinding()]
    param(
        [int]$TimeoutSec = 180,
        [int]$PollSec    = 3
    )

    $dockerExe = Get-AlfaDockerDesktopExe
    if (-not $dockerExe) {
        Write-Host '  Docker Desktop not installed. Installing via winget...' -ForegroundColor Yellow
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "Docker Desktop missing and winget unavailable. Install manually: https://www.docker.com/products/docker-desktop/"
        }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & winget install --id Docker.DockerDesktop -e --source winget `
                --accept-source-agreements --accept-package-agreements `
                --silent | Out-Null
            $exit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($exit -ne 0) {
            throw "winget install Docker.DockerDesktop failed (exit $exit). Install manually: https://www.docker.com/products/docker-desktop/"
        }
        $dockerExe = Get-AlfaDockerDesktopExe
        if (-not $dockerExe) {
            throw 'Docker Desktop install reported success but executable not found. A reboot may be required; reboot and re-run this script.'
        }
        Write-Host '  Docker Desktop installed. A reboot may be required on first install.' -ForegroundColor Green
    }

    $proc = Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "  Starting Docker Desktop ($dockerExe)..." -ForegroundColor Cyan
        # -ArgumentList '' keeps the spawned process unattached; no console window.
        Start-Process -FilePath $dockerExe -WindowStyle Hidden | Out-Null
    } else {
        Write-Host '  Docker Desktop process already running; waiting for engine to accept connections...' -ForegroundColor Cyan
    }

    $waited = 0
    $startTs = Get-Date -Format 'HH:mm:ss'
    Write-Host "    [$startTs] waiting for Docker engine (poll every ${PollSec}s, timeout ${TimeoutSec}s)..." -ForegroundColor Yellow
    while (-not (Test-AlfaDockerReady)) {
        if ($waited -ge $TimeoutSec) {
            throw "Docker engine still not ready after ${TimeoutSec}s. Open Docker Desktop's UI and check the engine status (Settings -> General)."
        }
        Start-Sleep -Seconds $PollSec
        $waited += $PollSec
        # Heartbeat every 15s so a slow WSL2 spin-up is visibly non-hung.
        if (($waited % 15) -eq 0) {
            $ts = Get-Date -Format 'HH:mm:ss'
            Write-Host "    [$ts] still waiting for Docker engine ($waited / $TimeoutSec s, no hang)..." -ForegroundColor Yellow
        }
    }
    $readyTs = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$readyTs] Docker engine ready after ${waited}s." -ForegroundColor Green
}

function Ensure-AlfaHubReachable {
    [CmdletBinding()]
    param(
        [string]$HubHost = 'hub',
        [int]$TimeoutMs  = 2000
    )
    # Cheap TCP probe on SMB (445). Gives a clear error up front instead of
    # making robocopy hang for 30+s on a down hub.
    $reachable = $false
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HubHost, 445, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($connected -and $client.Connected) {
            $client.EndConnect($iar)
            $reachable = $true
        }
        $client.Close()
    } catch {
        $reachable = $false
    }

    if ($reachable) {
        Write-Host "  hub hub ${HubHost}:445 reachable." -ForegroundColor Green
        return
    }

    $hubUnc = "\\${HubHost}"
    if (Get-Command Assert-AlfaHubFallbackProceed -ErrorAction SilentlyContinue) {
        Assert-AlfaHubFallbackProceed `
            -Context 'hub-smb' `
            -HubPath $hubUnc `
            -FallbackDescription 'Continue deploy; hub-specific steps will prompt again before any PyPI/HF/Docker Hub downloads.'
    }

    Write-Host "  WARN: hub hub ${HubHost}:445 not reachable; continuing (operator approved)." -ForegroundColor Yellow
}

function Ensure-AlfaWorkerEnvironment {
    [CmdletBinding()]
    param(
        [switch]$SkipDocker,
        [switch]$SkipHubProbe,
        [string]$HubHost = 'hub',
        [int]$DockerTimeoutSec = 180
    )

    $hubPrompt = Join-Path $PSScriptRoot 'hub-fallback-prompt.ps1'
    if ((Test-Path -LiteralPath $hubPrompt) -and -not (Get-Command Request-AlfaHubFallback -ErrorAction SilentlyContinue)) {
        . $hubPrompt
    }

    Write-Host ''
    Write-Host '== Environment readiness ==' -ForegroundColor Cyan

    Ensure-AlfaGitInstalled

    if (-not $SkipHubProbe) {
        Ensure-AlfaHubReachable -HubHost $HubHost
    }

    if (-not $SkipDocker) {
        Ensure-AlfaDockerEngine -TimeoutSec $DockerTimeoutSec
    }
    Write-Host ''
}
