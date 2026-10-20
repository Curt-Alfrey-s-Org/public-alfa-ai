<#
.SYNOPSIS
    Verify Docker Desktop and WSL2 are working correctly.
.DESCRIPTION
    Checks docker, docker compose, and WSL2 backend. Does NOT require admin.
    Run after Docker Desktop has been opened at least once and is running.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '== Step 3: Verify Docker + WSL2 ==' -ForegroundColor Cyan
Write-Host ''

$failed = $false

# --- Docker CLI --------------------------------------------------------------
Write-Host 'Checking docker...' -NoNewline
try {
    $dockerVer = & docker version --format '{{.Client.Version}}' 2>&1
    if ($LASTEXITCODE -eq 0 -and $dockerVer) {
        Write-Host " v$dockerVer" -ForegroundColor Green
    } else {
        Write-Host ' FAIL' -ForegroundColor Red
        Write-Host "  docker version returned exit code $LASTEXITCODE"
        Write-Host '  Is Docker Desktop running?'
        $failed = $true
    }
} catch {
    Write-Host ' FAIL' -ForegroundColor Red
    Write-Host "  docker not found. Is Docker Desktop installed and in PATH?"
    $failed = $true
}

# --- Docker Compose ----------------------------------------------------------
Write-Host 'Checking docker compose...' -NoNewline
try {
    $composeVer = & docker compose version --short 2>&1
    if ($LASTEXITCODE -eq 0 -and $composeVer) {
        Write-Host " v$composeVer" -ForegroundColor Green
    } else {
        Write-Host ' FAIL' -ForegroundColor Red
        $failed = $true
    }
} catch {
    Write-Host ' FAIL' -ForegroundColor Red
    Write-Host "  docker compose not found."
    $failed = $true
}

# --- WSL2 backend ------------------------------------------------------------
Write-Host 'Checking WSL2 backend...' -NoNewline
try {
    $wslList = & wsl -l -v 2>&1 | Out-String
    if ($wslList -match 'docker-desktop.*2') {
        Write-Host ' WSL2' -ForegroundColor Green
    } elseif ($wslList -match 'docker-desktop') {
        Write-Host ' WARNING: docker-desktop distro found but not confirmed as version 2' -ForegroundColor Yellow
        Write-Host "  Output: $wslList"
    } else {
        Write-Host ' WARNING: docker-desktop WSL distro not found' -ForegroundColor Yellow
        Write-Host '  Docker Desktop may be using a different backend.'
    }
} catch {
    Write-Host ' SKIP (wsl not available)' -ForegroundColor Yellow
}

# --- Docker pull test --------------------------------------------------------
if (-not $failed) {
    Write-Host 'Testing docker pull (hello-world)...' -NoNewline
    & docker pull hello-world 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ' OK' -ForegroundColor Green
    } else {
        Write-Host ' FAIL (network or daemon issue)' -ForegroundColor Red
        $failed = $true
    }
}

# --- Summary -----------------------------------------------------------------
Write-Host ''
if ($failed) {
    Write-Host 'RESULT: Some checks failed. Fix the issues above before proceeding.' -ForegroundColor Red
    exit 1
} else {
    Write-Host 'RESULT: Docker + WSL2 verified. Ready for llama.cpp RPC deploy.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Next: run worker deploy or llama.cpp RPC scripts:' -ForegroundColor Yellow
    Write-Host '  wsl -d Ubuntu docker ps'
    Write-Host ''
}
