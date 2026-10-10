#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install WSL2 on Windows 10 (build 18362+) or Windows 11.
.DESCRIPTION
    Uses the official Microsoft "wsl --install" method.
    Requires a reboot after completion.
    Reference: https://learn.microsoft.com/en-us/windows/wsl/install
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '== Step 1: Install WSL2 ==' -ForegroundColor Cyan
Write-Host ''

# --- Version gate -----------------------------------------------------------
$build = [System.Environment]::OSVersion.Version.Build
$major = [System.Environment]::OSVersion.Version.Major

if ($major -lt 10 -or $build -lt 18362) {
    Write-Host "FAIL: Windows 10 build 18362+ or Windows 11 is required for WSL2." -ForegroundColor Red
    Write-Host "Current build: $major.$build"
    Write-Host "Update Windows before proceeding."
    exit 1
}
Write-Host "Windows build $major.$build -- OK (18362+ required)" -ForegroundColor Green

# --- Check if WSL is already installed ---------------------------------------
$wslPath = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wslPath) {
    $wslVersion = & wsl.exe --version 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $wslVersion) {
        Write-Host "WSL is already installed: $wslVersion" -ForegroundColor Yellow
        Write-Host "If WSL2 is working, skip to 02-install-docker.ps1."
        exit 0
    }
}

# --- Install WSL2 (Microsoft official method) --------------------------------
Write-Host ''
Write-Host 'Running: wsl --install' -ForegroundColor Cyan
Write-Host 'This enables the WSL feature, Virtual Machine Platform, and installs Ubuntu by default.'
Write-Host ''

wsl --install

if ($LASTEXITCODE -ne 0) {
    Write-Host "wsl --install returned exit code $LASTEXITCODE" -ForegroundColor Red
    Write-Host "If it says 'reboot required', that is expected -- reboot and re-run this script."
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host '== WSL2 install complete ==' -ForegroundColor Green
Write-Host ''
Write-Host 'REBOOT NOW, then run 02-install-docker.ps1' -ForegroundColor Yellow
Write-Host ''
