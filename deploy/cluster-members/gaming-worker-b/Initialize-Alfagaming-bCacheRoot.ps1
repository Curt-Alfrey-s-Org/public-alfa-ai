#Requires -Version 5.1
<#
.SYNOPSIS
    Pick and export the gaming-worker-b (gaming-b) Windows alfa-ai-cache root.

.DESCRIPTION
    Dot-source at the start of gaming-worker-b-249 deploy/prep scripts. Uses the shared
    Get-AlfaWindowsCacheRoot helper and sets ALFA_WINDOWS_CACHE_ROOT for the
    process. WSL docker load paths use /mnt/<letter>/alfa-ai-cache/...

.EXAMPLE
    . .\Initialize-Alfa249CacheRoot.ps1
    Initialize-Alfa249CacheRoot | Out-Null
    $images = Get-Alfa249DockerImagesCache
#>
Set-StrictMode -Version Latest

$cacheRootScript = Join-Path $PSScriptRoot '..\_common\Get-AlfaWindowsCacheRoot.ps1'
if (-not (Test-Path -LiteralPath $cacheRootScript)) {
    throw "Missing shared cache helper: $cacheRootScript"
}
. $cacheRootScript

function Initialize-Alfa249CacheRoot {
    [CmdletBinding()]
    param(
        [uint64]$RequiredFreeBytes = 0
    )

    $root = Get-AlfaWindowsCacheRoot -RequiredFreeBytes $RequiredFreeBytes
    $env:ALFA_WINDOWS_CACHE_ROOT = $root
    Write-Host "  gaming-worker-b-249 cache root: $root" -ForegroundColor Cyan
    return $root
}

function Get-Alfa249CacheRoot {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:ALFA_WINDOWS_CACHE_ROOT)) {
        Initialize-Alfa249CacheRoot | Out-Null
    }
    return $env:ALFA_WINDOWS_CACHE_ROOT
}

function Get-Alfa249DockerImagesCache {
    [CmdletBinding()]
    param()

    $root = Get-Alfa249CacheRoot
    $dir = Join-Path $root 'docker-images'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Ensure-gaming-worker-b249RpcDockerImage {
    <#
    .SYNOPSIS
        Stage alfa-llamacpp-rpc tarball on the picked cache drive and optionally docker load (WSL).
    #>
    [CmdletBinding()]
    param(
        [switch]$LoadIfMissing
    )

    $Tarball = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
    $ImageTag = 'alfa-llamacpp-rpc:cuda128'
    $LocalCache = Get-Alfa249DockerImagesCache
    $HubImage = Join-Path '\\hub\docker-images' $Tarball
    $StageImage = Join-Path '\\hub\temp\cluster_members\_common\docker-images' $Tarball

    if ($LoadIfMissing) {
        $prevEa = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        wsl.exe -d Ubuntu docker image inspect $ImageTag --format '{{.Id}}' 2>$null | Out-Null
        $haveImage = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevEa
        if ($haveImage) {
            Write-Host "  RPC image already loaded: $ImageTag" -ForegroundColor Green
            return
        }
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
        Write-Host "  Copying $src -> $dest ..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $src -Destination "$dest.tmp" -Force
        Move-Item -LiteralPath "$dest.tmp" -Destination $dest -Force
        Write-Host ("  OK ({0} MB)" -f [int]((Get-Item -LiteralPath $dest).Length / 1MB)) -ForegroundColor Green
    }

    $manifestSrc = Join-Path (Split-Path -Parent $src) 'images.json'
    $manifestDst = Join-Path $LocalCache 'images.json'
    if ((Test-Path -LiteralPath $manifestSrc) -and -not (Test-Path -LiteralPath $manifestDst)) {
        Copy-Item -LiteralPath $manifestSrc -Destination $manifestDst -Force
    }

    if ($LoadIfMissing) {
        Write-Host "== docker load $ImageTag (WSL) ==" -ForegroundColor Cyan
        $wslTar = ConvertTo-AlfaWindowsCacheWslPath -WinPath $dest
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
}
