#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Download and install Docker Desktop with WSL2 backend.
.DESCRIPTION
    Downloads the official Docker Desktop installer and runs a silent install
    with the WSL2 backend (no Hyper-V required -- works on Windows 10 Home).
    Requires a log-out or reboot after completion.
    Reference: https://docs.docker.com/desktop/setup/install/windows-install/
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '== Step 2: Install Docker Desktop ==' -ForegroundColor Cyan
Write-Host ''

# --- Check if Docker is already installed ------------------------------------
$dockerPath = Get-Command docker.exe -ErrorAction SilentlyContinue
if ($dockerPath) {
    try {
        $ver = & docker.exe version --format '{{.Client.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0 -and $ver) {
            Write-Host "Docker is already installed: v$ver" -ForegroundColor Yellow
            Write-Host "If Docker Desktop is running, skip to 03-verify-docker.ps1."
            exit 0
        }
    } catch {}
}

# --- Check WSL2 is present ---------------------------------------------------
$wslPath = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslPath) {
    Write-Host "FAIL: WSL2 not found. Run 01-install-wsl2.ps1 first and reboot." -ForegroundColor Red
    exit 1
}

# --- Download Docker Desktop -------------------------------------------------
$installerUrl = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
$installerPath = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'

if (Test-Path $installerPath) {
    Write-Host "Installer already downloaded at $installerPath" -ForegroundColor Yellow
} else {
    Write-Host "Downloading Docker Desktop installer..."
    Write-Host "URL: $installerUrl"
    Write-Host ''
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    Write-Host "Downloaded to $installerPath" -ForegroundColor Green
}

# --- Silent install with WSL2 backend ----------------------------------------
Write-Host ''
Write-Host 'Installing Docker Desktop (silent, WSL2 backend)...' -ForegroundColor Cyan
Write-Host 'This may take several minutes.'
Write-Host ''

$installArgs = 'install', '--quiet', '--accept-license', '--backend=wsl-2'
Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -NoNewWindow

Write-Host ''
Write-Host '== Docker Desktop install complete ==' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Log out and log back in (or reboot)'
Write-Host '  2. Open Docker Desktop from the Start menu and let it finish initializing'
Write-Host '  3. Then run 03-verify-docker.ps1'
Write-Host ''
