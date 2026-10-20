#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = 'C:/Users/operator\alfa-ai'
$StackDir   = Join-Path $RepoRoot 'deploy\aria2'
$EnvFile    = Join-Path $StackDir '.env'
$Downloads  = 'C:/Users/operator\AppData\Local\alfa-ai\aria2-downloads'
$Smoke      = Join-Path $RepoRoot 'deploy\cluster-members\orchestrator\aria2-smoke.ps1'
$EnvScript  = Join-Path $RepoRoot 'deploy\cluster-members\orchestrator\aria2-env.ps1'
$Compose    = Join-Path $StackDir 'docker-compose.yml'

function Step([string]$msg) {
    Write-Host "== $msg ==" -ForegroundColor Cyan
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-Path([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        throw "$Label not found: $Path"
    }
}

function Test-DockerCli {
    cmd /c 'docker --version >nul 2>nul'
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerComposeV2 {
    cmd /c 'docker compose version >nul 2>nul'
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerEngine {
    cmd /c 'docker version --format "{{.Server.Version}}" >nul 2>nul'
    return ($LASTEXITCODE -eq 0)
}

function Install-DockerDesktopIfMissing {
    if (Test-DockerCli) { return }

    Step 'Docker CLI missing; attempting Docker Desktop install'

    if (Test-Command 'winget') {
        & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) {
            throw "winget install Docker.DockerDesktop failed (exit $LASTEXITCODE)."
        }
    } elseif (Test-Command 'choco') {
        & choco install docker-desktop -y
        if ($LASTEXITCODE -ne 0) {
            throw "choco install docker-desktop failed (exit $LASTEXITCODE)."
        }
    } else {
        throw 'Docker CLI not found and neither winget nor choco is available. Install Docker Desktop manually, then rerun.'
    }

    if (-not (Test-DockerCli)) {
        throw 'Docker CLI still unavailable after install. Open a new PowerShell session and rerun.'
    }
}

function Ensure-DockerCompose {
    if (Test-DockerComposeV2) { return }
    throw 'Docker Compose v2 is unavailable (`docker compose`). Update Docker Desktop, then rerun.'
}

function Ensure-DockerEngine {
    if (Test-DockerEngine) { return }

    $desktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $desktopExe) {
        Write-Host 'Docker engine not ready; starting Docker Desktop...' -ForegroundColor Yellow
        Start-Process -FilePath $desktopExe | Out-Null
    } else {
        Write-Host 'Docker Desktop executable not found in Program Files; waiting for docker engine...' -ForegroundColor Yellow
    }

    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        if (Test-DockerEngine) {
            Write-Host 'Docker engine is ready.' -ForegroundColor Green
            return
        }
    }

    throw 'Docker engine is not reachable (npipe dockerDesktopLinuxEngine). Start Docker Desktop and rerun.'
}

Step 'Preflight checks'
if ([string]::IsNullOrWhiteSpace($env:ARIA2_RPC_KEY)) {
    throw 'ARIA2_RPC_KEY is not set. Set it first (same value as the hub aria2 stack), e.g. $env:ARIA2_RPC_KEY = ''<secret>'', then rerun. See deploy/aria2/README.md.'
}
Ensure-Path $RepoRoot 'Repo root'
Ensure-Path $StackDir 'aria2 stack directory'
Ensure-Path $Compose 'Compose file'
Ensure-Path $Smoke 'Smoke script'
Ensure-Path $EnvScript 'Env script'

Install-DockerDesktopIfMissing
Ensure-DockerCompose
Ensure-DockerEngine

Step 'Prepare downloads dir and stack env'
New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
@"
ARIA2_RPC_KEY=$($env:ARIA2_RPC_KEY)
ARIA2_DOWNLOADS_HOST_PATH=C:/Users/operator/AppData/Local/alfa-ai/aria2-downloads
TZ=UTC
PUID=1000
PGID=1000
"@ | Set-Content -Path $EnvFile -Encoding ascii

Step 'Compose up'
Push-Location $StackDir
try {
    & docker compose -f $Compose up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (exit $LASTEXITCODE)" }

    & docker compose -f $Compose ps
    if ($LASTEXITCODE -ne 0) { throw "docker compose ps failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

Step 'Smoke check'
& $Smoke
if ($LASTEXITCODE -ne 0) { throw "aria2 smoke check failed (exit $LASTEXITCODE)" }

. $EnvScript
Write-Host ''
Write-Host 'Bootstrap complete for orchestrator.' -ForegroundColor Green
