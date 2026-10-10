#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstall Docker Desktop after WSL Docker Engine is verified.

.DESCRIPTION
    Stops Docker Desktop, unregisters docker-desktop WSL distros (DESTROYS Desktop
    images/volumes), runs the official uninstaller if present.

    Run ONLY after:
      - wsl docker ps works
      - Petals/gateway stacks run from WSL compose
      - Hub tarballs / registry mirror available for rebuild

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\wsl-docker\99-uninstall-docker-desktop.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '== Uninstall Docker Desktop ==' -ForegroundColor Cyan
Write-Host 'WARNING: This removes Docker Desktop WSL data (images/volumes in docker-desktop distros).' -ForegroundColor Yellow
Write-Host 'Press Ctrl+C within 10s to abort...'
Start-Sleep -Seconds 10

Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process 'com.docker.backend' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

wsl.exe --shutdown
Start-Sleep -Seconds 3

foreach ($distro in @('docker-desktop', 'docker-desktop-data')) {
    $listed = wsl.exe -l -v 2>&1 | Out-String
    if ($listed -match $distro) {
        Write-Host "Unregistering WSL distro: $distro" -ForegroundColor Yellow
        wsl.exe --unregister $distro
    }
}

$installer = Join-Path ${env:ProgramFiles} 'Docker\Docker\Docker Desktop Installer.exe'
if (Test-Path -LiteralPath $installer) {
    Write-Host "Running Docker Desktop uninstaller..."
    Start-Process -FilePath $installer -ArgumentList 'uninstall', '--quiet' -Wait -NoNewWindow
} else {
    Write-Host "Installer not found at $installer - remove Docker Desktop from Settings > Apps if still listed."
}

Write-Host ''
Write-Host '== Docker Desktop removal complete ==' -ForegroundColor Green
Write-Host 'Use WSL for all docker commands:'
Write-Host '  wsl -d Ubuntu docker ps'
Write-Host 'Or set alias in PowerShell profile: function docker { wsl -d Ubuntu docker @args }'
