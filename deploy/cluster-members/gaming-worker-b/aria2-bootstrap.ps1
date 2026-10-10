#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkerRoot = 'C:\\alfa-ai-worker'
$RepoUrl    = 'https://github.com/example/alfa-ai.git'
$RepoBranch = 'main'
$StackDir   = Join-Path $WorkerRoot 'deploy\\aria2'
$EnvFile    = Join-Path $StackDir '.env'
$Downloads  = 'C:\\alfa-ai-worker\\data\\aria2-downloads'
$Smoke      = Join-Path $WorkerRoot 'deploy\\cluster-members\\gaming-worker-b-249\\aria2-smoke.ps1'
$EnvScript  = Join-Path $WorkerRoot 'deploy\\cluster-members\\gaming-worker-b-249\\aria2-env.ps1'
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

function Test-GitCli {
    cmd /c 'git --version >nul 2>nul'
    return ($LASTEXITCODE -eq 0)
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

function Install-GitIfMissing {
    if (Test-GitCli) { return }

    Step 'Git missing; attempting install'
    if (Test-Command 'winget') {
        & winget install -e --id Git.Git --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "winget install Git.Git failed (exit $LASTEXITCODE)." }
    } elseif (Test-Command 'choco') {
        & choco install git -y
        if ($LASTEXITCODE -ne 0) { throw "choco install git failed (exit $LASTEXITCODE)." }
    } else {
        throw 'Git CLI not found and neither winget nor choco is available. Install Git manually, then rerun.'
    }

    if (-not (Test-GitCli)) {
        throw 'Git CLI still unavailable after install. Open a new PowerShell session and rerun.'
    }
}

function Ensure-Repo {
    Step 'Ensure repo checkout'

    if (Test-Path (Join-Path $WorkerRoot '.git')) {
        & git -C $WorkerRoot fetch origin $RepoBranch
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed in $WorkerRoot" }

        & git -C $WorkerRoot pull --ff-only origin $RepoBranch
        if ($LASTEXITCODE -ne 0) { throw "git pull failed in $WorkerRoot" }
        return
    }

    if (Test-Path $WorkerRoot) {
        $entries = Get-ChildItem -Force -Path $WorkerRoot -ErrorAction SilentlyContinue
        if ($entries.Count -gt 0) {
            throw "Worker root exists but is not a git repo: $WorkerRoot. Move/clear it, then rerun."
        }
    } else {
        New-Item -ItemType Directory -Force -Path $WorkerRoot | Out-Null
    }

    & git clone --branch $RepoBranch --single-branch $RepoUrl $WorkerRoot
    if ($LASTEXITCODE -ne 0) { throw "git clone failed: $RepoUrl -> $WorkerRoot" }
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

    $desktopExe = Join-Path $env:ProgramFiles 'Docker\\Docker\\Docker Desktop.exe'
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
if (-not (Test-Command 'wsl')) {
    Write-Host 'WARN: wsl command not found. Continuing (aria2 bootstrap itself does not require WSL).' -ForegroundColor Yellow
}

Install-GitIfMissing
Ensure-Repo
Install-DockerDesktopIfMissing
Ensure-DockerCompose
Ensure-DockerEngine

Step 'Validate repo files'
Ensure-Path $StackDir 'aria2 stack directory'
Ensure-Path $Compose 'Compose file'
Ensure-Path $Smoke 'Smoke script'
Ensure-Path $EnvScript 'Env script'

Step 'Prepare downloads dir and stack env'
New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
@"
ARIA2_RPC_KEY=$($env:ARIA2_RPC_KEY)
ARIA2_DOWNLOADS_HOST_PATH=C:/alfa-ai-worker/data/aria2-downloads
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
Write-Host 'Bootstrap complete for gaming-b.' -ForegroundColor Green
