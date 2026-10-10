#Requires -Version 5.1
<#
.SYNOPSIS
    Offline-friendly prep for inference gaming hosts (gaming-c / gaming-b / gaming-a).
.DESCRIPTION
    Run on the gaming PC when it wakes (before opt-in at Start-Stop-AlfaAi.ps1 start).
    Does NOT start the rpc-server shard (coordinator must be down for first smoke, or
    use the full orchestrator opt-in path).

    Steps:
      1. git pull --ff-only in the local alfa-ai clone (if .git present)
      2. Ensure <Get-AlfaWindowsCacheRoot>\docker-images\
      3. Copy alfa-llamacpp-rpc-cuda128-b10355.tar.gz from hub SMB if missing/stale
      4. Optional: docker load into WSL Docker Engine (-LoadImage)

    Official Docker load: https://docs.docker.com/reference/cli/docker/image/load/
.PARAMETER RepoDir
    Path to alfa-ai clone (default: parent of this script's repo root).
.PARAMETER LoadImage
    Run docker load into WSL after cache promote.
.PARAMETER SkipGit
    Skip git pull (use when clone is missing or offline).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\Prep-GamingHostinferenceReady.ps1 -LoadImage
#>
[CmdletBinding()]
param(
    [string]$RepoDir = '',
    [switch]$LoadImage,
    [switch]$SkipGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) {
    $RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

$cacheRootScript = Join-Path $PSScriptRoot 'Get-AlfaWindowsCacheRoot.ps1'
if (-not (Test-Path -LiteralPath $cacheRootScript)) {
    throw "Missing shared cache helper: $cacheRootScript (run Get-AlfaWindowsCacheRoot or set ALFA_WINDOWS_CACHE_ROOT)"
}
. $cacheRootScript
$wslDockerHelper = Join-Path $PSScriptRoot 'wsl-docker.ps1'
if (Test-Path -LiteralPath $wslDockerHelper) {
    . $wslDockerHelper
}

$Tarball = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
$ImageTag = 'alfa-llamacpp-rpc:cuda128'
Assert-AlfaWindowsCacheRootHelperLoaded
$LocalCache = Get-AlfaWindowsDockerImagesCacheDir
$HubImage = Join-Path '\\hub\docker-images' $Tarball
$StageImage = Join-Path '\\hub\temp\cluster_members\_common\docker-images' $Tarball

Write-Host '== Prep-GamingHostinferenceReady ==' -ForegroundColor Cyan
Write-Host "  RepoDir: $RepoDir"

if (-not $SkipGit) {
    $gitDir = Join-Path $RepoDir '.git'
    if (Test-Path -LiteralPath $gitDir) {
        Write-Host '== git pull --ff-only origin main ==' -ForegroundColor Cyan
        Push-Location $RepoDir
        try {
            & git pull --ff-only origin main
            if ($LASTEXITCODE -ne 0) {
                throw "git pull failed (exit $LASTEXITCODE)"
            }
            & git log -1 --oneline
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "WARN: no .git at $RepoDir - clone or copy from SMB staging, then re-run." -ForegroundColor Yellow
        Write-Host '  git clone https://github.com/example/alfa-ai.git <path>' -ForegroundColor DarkGray
        Write-Host '  Or: robocopy \\hub\temp\cluster_members\_common\repo C:\Users\<you>\alfa-ai /E' -ForegroundColor DarkGray
    }
}

if (-not (Test-Path -LiteralPath $LocalCache)) {
    New-Item -ItemType Directory -Path $LocalCache -Force | Out-Null
    Write-Host "  Created $LocalCache"
}

$dest = Join-Path $LocalCache $Tarball
$src = $null
foreach ($cand in @($HubImage, $StageImage)) {
    if (Test-Path -LiteralPath $cand) {
        $src = $cand
        break
    }
}
if (-not $src) {
    throw "Missing hub tarball. Need $HubImage or $StageImage (run stage-cluster-members.ps1 on orchestrator)."
}

$needCopy = $true
if (Test-Path -LiteralPath $dest) {
    $srcLen = (Get-Item -LiteralPath $src).Length
    $dstLen = (Get-Item -LiteralPath $dest).Length
    if ($srcLen -eq $dstLen) {
        $needCopy = $false
        Write-Host ("  Cache OK ({0} MB): $dest" -f [int]($dstLen / 1MB)) -ForegroundColor Green
    }
}
if ($needCopy) {
    Write-Host "  Copying $src -> $dest (once; local SSD warm path)..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $src -Destination "$dest.tmp" -Force
    Move-Item -LiteralPath "$dest.tmp" -Destination $dest -Force
    Write-Host ("  OK ({0} MB)" -f [int]((Get-Item -LiteralPath $dest).Length / 1MB)) -ForegroundColor Green
}

$manifestSrc = Join-Path (Split-Path -Parent $src) 'images.json'
$manifestDst = Join-Path $LocalCache 'images.json'
if ((Test-Path -LiteralPath $manifestSrc) -and -not (Test-Path -LiteralPath $manifestDst)) {
    Copy-Item -LiteralPath $manifestSrc -Destination $manifestDst -Force
}

if ($LoadImage) {
    Write-Host "== docker load $ImageTag (WSL) ==" -ForegroundColor Cyan
    $tarballWin = Join-Path $LocalCache $Tarball
    if (Get-Command ConvertTo-AlfaWslPath -ErrorAction SilentlyContinue) {
        $wslTar = ConvertTo-AlfaWslPath -Path $tarballWin
    } else {
        $wslTar = ConvertTo-AlfaWindowsCacheWslPath -WinPath $tarballWin
    }
    wsl.exe -d Ubuntu docker load -i $wslTar
    if ($LASTEXITCODE -ne 0) {
        throw "docker load failed (exit $LASTEXITCODE). Is WSL Docker Engine up?"
    }
    wsl.exe -d Ubuntu docker image inspect $ImageTag --format '{{.Id}}'
    if ($LASTEXITCODE -ne 0) {
        throw "image missing after load: $ImageTag"
    }
    Write-Host "  Loaded $ImageTag" -ForegroundColor Green
}
else {
    Write-Host '  Skip docker load (pass -LoadImage when WSL Docker is up).' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '== Prep done. Next when ready to join pool ==' -ForegroundColor Green
Write-Host '  1. WSL Docker + nvidia-smi OK'
Write-Host '  2. Smoke (coordinator DOWN): deploy-grev27-pool-shard.ps1 on this host'
Write-Host '  3. From orchestrator: Start-Stop-AlfaAi.ps1 stop then start; answer Y for this host'
Write-Host '  Docs: docs/inference_GAMING_HOST_JOIN.md'
