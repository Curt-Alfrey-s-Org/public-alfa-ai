#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install Docker Engine inside WSL Ubuntu (replace Docker Desktop for CLI workers).

.DESCRIPTION
    1. Ensures Ubuntu WSL distro exists.
    2. Runs deploy/cluster-members/_common/wsl-docker/install-docker-engine-in-wsl.sh inside WSL.
    3. Configures WSL networking (.wslconfig):
       - Win11 22H2+: mirrored mode (RPC LAN ports)
       - Win10: NAT + portproxy (see install-wsl-nat-portproxy.ps1)

    Official refs:
      https://docs.docker.com/engine/install/ubuntu/
      https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking

.EXAMPLE
    cd C:/Users/operator\alfa-ai
    powershell -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\wsl-docker\02-install-docker-wsl-engine.ps1
#>
param(
    [string]$WslDistro = 'Ubuntu',
    [string]$RepoRoot,
    [ValidateSet('', 'operator-93', 'gaming-worker-a-219', 'gaming-worker-b-249', 'gaming-worker-c-59')]
    [string]$HostProfile = '',
    [int[]]$NatPortProxyPorts,
    [switch]$RegisterNatPortProxyTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script lives at deploy/cluster-members/_common/wsl-docker/ -- four parents to repo root.
# Official: Split-Path -Parent (https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/split-path)
if (-not $RepoRoot) {
    $repoCandidate = $PSScriptRoot
    1..4 | ForEach-Object { $repoCandidate = Split-Path -Parent $repoCandidate }
    if (-not (Test-Path -LiteralPath (Join-Path $repoCandidate '.git'))) {
        throw "Cannot locate repo root from $PSScriptRoot (resolved $repoCandidate). Pass -RepoRoot."
    }
    $RepoRoot = (Resolve-Path -LiteralPath $repoCandidate).Path
}

Write-Host '== Install Docker Engine in WSL (no Docker Desktop) ==' -ForegroundColor Cyan

function Test-WslDistroExists {
    param([string]$Name)
    wsl.exe -d $Name -e true 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-WslDistroNames {
    $raw = wsl.exe -l -q 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    $names = @($raw | ForEach-Object { ($_ -replace '\0', '').Trim() } | Where-Object { $_ })
    return ,$names
}

if (-not (Test-WslDistroExists -Name $WslDistro)) {
    $all = Get-WslDistroNames
    $ubuntuLike = $all | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1
    if ($ubuntuLike) {
        Write-Host "Using detected distro: $ubuntuLike (requested: $WslDistro)" -ForegroundColor Yellow
        $WslDistro = $ubuntuLike
    } else {
        Write-Host "Distro $WslDistro not found. Installed:" -ForegroundColor Yellow
        if ($all.Count -gt 0) { $all | ForEach-Object { Write-Host "  $_" } }
        else { Write-Host '  (none listed - run: wsl -l -v)' }
        Write-Host "Install with: wsl --install -d Ubuntu" -ForegroundColor Yellow
        exit 1
    }
}

# Derive .wslconfig owner from repo path (operator admin install must write operator's file).
$wslConfigHome = $env:USERPROFILE
if ($RepoRoot -match '\\Users\\([^\\]+)\\') {
    $repoUser = $Matches[1]
    $candidate = Join-Path 'C:\Users' $repoUser
    if ((Test-Path -LiteralPath $candidate) -and ($repoUser -ne $env:USERNAME)) {
        $wslConfigHome = $candidate
        Write-Host "WSL config target: $wslConfigHome\.wslconfig (repo owner $repoUser, installer $env:USERNAME)" -ForegroundColor Cyan
    }
}

$userCfg = Join-Path $wslConfigHome '.wslconfig'

$portProxyScript = Join-Path $RepoRoot 'deploy\cluster-members\_common\install-wsl-nat-portproxy.ps1'
if (Test-Path -LiteralPath $portProxyScript) {
    . $portProxyScript
}
$mirroredSupported = $false
if (Get-Command Test-AlfaWslMirroredNetworkingSupported -ErrorAction SilentlyContinue) {
    $mirroredSupported = Test-AlfaWslMirroredNetworkingSupported
} else {
    $mirroredSupported = ([System.Environment]::OSVersion.Version.Build -ge 22621)
}

if ($mirroredSupported) {
    $mirroredBlock = @"
[wsl2]
networkingMode=mirrored
swap=0
dnsTunneling=true
firewall=true
autoProxy=true
vmIdleTimeout=-1

[experimental]
hostAddressLoopback=true

[general]
instanceIdleTimeout=-1
"@
    if (-not (Test-Path $userCfg) -or ((Get-Content $userCfg -Raw) -notmatch 'networkingMode\s*=\s*mirrored')) {
        Write-Host "Enabling WSL mirrored networking in $userCfg (required for RPC LAN ports)." -ForegroundColor Yellow
        Add-Content -Path $userCfg -Value "`n$mirroredBlock"
        Write-Host "Run wsl --shutdown after install completes, then reopen Ubuntu." -ForegroundColor Yellow
    }
} else {
    Write-Host 'Win10 detected: mirrored WSL unavailable - using NAT + netsh portproxy path.' -ForegroundColor Yellow
    Write-Host '  Doc: docs/WINDOWS_WSL_DOCKER_ENGINE.md - Win10 NAT portproxy' -ForegroundColor DarkGray
    if ((Test-Path -LiteralPath $userCfg) -and ((Get-Content $userCfg -Raw) -match 'networkingMode\s*=\s*mirrored')) {
        Write-Host "  WARN: $userCfg still has networkingMode=mirrored (ignored on Win10)." -ForegroundColor Yellow
        Write-Host '  Replace with deploy/cluster-members/_common/wslconfig-petals-win10-nat.example' -ForegroundColor Yellow
    }
    $natBlock = @"
[wsl2]
swap=0
localhostForwarding=true
vmIdleTimeout=-1

[general]
instanceIdleTimeout=-1
"@
    if (-not (Test-Path $userCfg) -or ((Get-Content $userCfg -Raw) -notmatch 'localhostForwarding\s*=\s*true')) {
        Write-Host "Appending Win10 NAT .wslconfig block to $userCfg" -ForegroundColor Yellow
        Add-Content -Path $userCfg -Value "`n$natBlock"
    }
}

$winRepo = $RepoRoot -replace '\\', '/'
if ($winRepo -match '^([A-Za-z]):/(.*)$') {
    $wslRepo = "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
} else {
    throw "Cannot map repo to WSL path: $RepoRoot"
}

$installSh = "$wslRepo/deploy/cluster-members/_common/wsl-docker/install-docker-engine-in-wsl.sh"
Write-Host "WSL repo: $wslRepo"
Write-Host "Running: sudo bash $installSh"

$inner = "test -f '$installSh' || { echo 'Missing script - git pull in Windows repo'; exit 1; }; sudo bash '$installSh'"
wsl.exe -d $WslDistro -e bash -lc $inner
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host '== WSL Docker Engine install finished ==' -ForegroundColor Green
Write-Host "Verify: wsl -d $WslDistro docker ps"
Write-Host "Verify: wsl -d $WslDistro nvidia-smi"

if ($mirroredSupported) {
    if (-not $HostProfile -and $RepoRoot -match '\\Users\\operator\\') {
        $HostProfile = 'operator-93'
    }
    if ($HostProfile) {
        $fwInstall = Join-Path $RepoRoot 'deploy\cluster-members\_common\install-wsl-lan-firewall.ps1'
        if (Test-Path -LiteralPath $fwInstall) {
            Write-Host ''
            . $fwInstall
            Install-AlfaWslLanFirewall -Profile $HostProfile -RepoRoot $RepoRoot
        } else {
            Write-Host "WARN: missing $fwInstall - open LAN ports manually per docs/WINDOWS_WSL_DOCKER_ENGINE.md" -ForegroundColor Yellow
        }
    } else {
        Write-Host ''
        Write-Host 'Next (Administrator): install-wsl-lan-firewall.ps1 -Profile <host> per docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md Phase B' -ForegroundColor Yellow
    }
}

if (-not $mirroredSupported -and $NatPortProxyPorts -and $NatPortProxyPorts.Count -gt 0) {
    if (Get-Command Install-AlfaWslNatPortProxy -ErrorAction SilentlyContinue) {
        Write-Host ''
        Install-AlfaWslNatPortProxy `
            -DisplayNamePrefix 'ALFa WSL NAT portproxy' `
            -TcpPorts $NatPortProxyPorts `
            -Distro $WslDistro `
            -RepoRoot $RepoRoot `
            -RegisterScheduledTask:$RegisterNatPortProxyTask
    } else {
        Write-Host 'Run install-wsl-nat-portproxy.ps1 after worker deploy (Win10 NAT path).' -ForegroundColor Yellow
    }
}
