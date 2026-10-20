#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only preflight: RPC docker image or hub tarball present before shard deploy.

.DESCRIPTION
    Mirrors deploy-llamacpp-rpc.ps1 search roots. Does not docker load or copy.
    Dot-source for functions, or run with -File for a single host check.

    Docker image inspect: https://docs.docker.com/reference/cli/docker/image/inspect/

.PARAMETER Label
    Host label for error messages (e.g. orchestrator, gaming-a).

.PARAMETER ForceHubLoad
    Pool80 sets FORCE_HUB_RPC_LOAD=1; tarball required even when image exists.

.PARAMETER Pascal
    gpu-248 pascal tarball variant.

.EXAMPLE
    . .\deploy\cluster-members\_common\Test-AlfaRpcImageDepsPreflight.ps1
    Test-AlfaRpcImageDependency -Label 'orchestrator' -ForceHubLoad

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\Test-AlfaRpcImageDepsPreflight.ps1 -Label gaming-a -ForceHubLoad
#>
[CmdletBinding()]
param(
    [string]$Label = '',
    [switch]$ForceHubLoad,
    [switch]$Pascal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cacheRootScript = Join-Path $PSScriptRoot 'Get-AlfaWindowsCacheRoot.ps1'
if (-not (Test-Path -LiteralPath $cacheRootScript)) {
    throw "Missing shared cache helper: $cacheRootScript (run Get-AlfaWindowsCacheRoot or set ALFA_WINDOWS_CACHE_ROOT)"
}
. $cacheRootScript

function Resolve-AlfaRpcLocalDockerCache {
    Assert-AlfaWindowsCacheRootHelperLoaded
    return Get-AlfaWindowsDockerImagesCacheDir
}

function Get-AlfaRpcTarballSearchRoots {
    param([string]$LocalCache = '')

    if ([string]::IsNullOrWhiteSpace($LocalCache)) {
        $LocalCache = Resolve-AlfaRpcLocalDockerCache
    }

    $roots = @(
        $LocalCache,
        '\\hub\docker-images',
        '\\hub\docker-images',
        '\\hub\temp\cluster_members\_common\docker-images',
        'H:\'
    )
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (-not $r -or $seen.ContainsKey($r)) { continue }
        $seen[$r] = $true
        [void]$out.Add($r)
    }
    return @($out)
}

function Find-AlfaRpcTarballPath {
    param(
        [Parameter(Mandatory)][string]$TarballName,
        [string]$LocalCache = ''
    )

    if ([string]::IsNullOrWhiteSpace($LocalCache)) {
        $LocalCache = Resolve-AlfaRpcLocalDockerCache
    }
    foreach ($root in (Get-AlfaRpcTarballSearchRoots -LocalCache $LocalCache)) {
        $rootOk = $false
        try {
            $rootOk = Test-Path -LiteralPath $root
        } catch {
            $rootOk = $false
        }
        if (-not $rootOk) { continue }
        if ($root -match '^[A-Za-z]:\\?$') {
            $driveLetter = $root.Substring(0, 1)
            if (-not (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue)) {
                continue
            }
        }
        try {
            $candidate = Join-Path $root $TarballName
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        } catch {
            continue
        }
    }
    return $null
}

function Test-AlfaWindowsDockerImagePresent {
    param([Parameter(Mandatory)][string]$ImageTag)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $docker = Get-Command docker -ErrorAction SilentlyContinue
        if ($docker) {
            & docker image inspect $ImageTag 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl) {
            & wsl.exe -d Ubuntu docker image inspect $ImageTag 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        return $false
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-AlfaRpcImageDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [switch]$ForceHubLoad,
        [switch]$Pascal
    )

    if ($Pascal) {
        $imageTag = 'alfa-llamacpp-rpc:cuda128-pascal'
        $tarball = 'alfa-llamacpp-rpc-cuda128-pascal-b10355.tar.gz'
        $buildHint = 'sudo bash scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh'
    } else {
        $imageTag = 'alfa-llamacpp-rpc:cuda128'
        $tarball = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
        $buildHint = 'sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh'
    }

    if (-not $ForceHubLoad) {
        if (Test-AlfaWindowsDockerImagePresent -ImageTag $imageTag) {
            Write-Host ("OK: {0} docker image {1} already loaded" -f $Label, $imageTag) -ForegroundColor Green
            return
        }
    }

    $found = Find-AlfaRpcTarballPath -TarballName $tarball
    if ($found) {
        Write-Host ("OK: {0} hub tarball {1} at {2}" -f $Label, $tarball, $found) -ForegroundColor Green
        return
    }

    $localCacheHint = Resolve-AlfaRpcLocalDockerCache
    $roots = (Get-AlfaRpcTarballSearchRoots) -join '; '
    $prepHint = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\Prep-GamingHostinferenceReady.ps1'
    throw @(
        ("{0}: missing RPC dependency (image={1}, tarball={2}, force_hub={3})" -f $Label, $imageTag, $tarball, [int][bool]$ForceHubLoad),
        "  Searched: $roots",
        "  Fix: copy $tarball to $localCacheHint\ from \\hub\docker-images",
        "  If Access denied: on hub fix filesystem ACL + bash scripts/fix-hub-docker-images-smb-read.sh --apply-posix",
        "  Or on hub: $buildHint",
        "  Gaming host prep: $prepHint -LoadImage"
    ) -join [Environment]::NewLine
}

# Run only when invoked as -File (not when dot-sourced).
if ($MyInvocation.InvocationName -ne '.' -and $Label) {
    Test-AlfaRpcImageDependency -Label $Label -ForceHubLoad:$ForceHubLoad -Pascal:$Pascal
}
