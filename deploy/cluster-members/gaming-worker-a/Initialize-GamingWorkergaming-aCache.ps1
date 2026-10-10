#Requires -Version 5.1
<#
.SYNOPSIS
    Pick and export ALFA_WINDOWS_CACHE_ROOT for gaming-worker-a-219 deploy scripts.

.DESCRIPTION
    Dot-source at the start of gaming-worker-a-219 deploy/prep entry points. Calls
    Get-AlfaWindowsCacheRoot.ps1 and sets ALFA_WINDOWS_CACHE_ROOT for
    deploy-llamacpp-rpc.ps1 (docker tarball promote/load).

    When no NTFS drive is eligible (<80% used and >=30 GB free) but WSL Docker
    already has alfa-llamacpp-rpc:cuda128, skip the picker so inference shard deploy
    can use the warm-image path. Official inspect:
    https://docs.docker.com/reference/cli/docker/image/inspect/

.EXAMPLE
    . .\deploy\cluster-members\gaming-worker-a\Initialize-GamingWorkerCache.ps1
    Initialize-GamingWorkerWindowsCache | Out-Null
#>
Set-StrictMode -Version Latest

function Test-GamingWorkerRpcImageLoaded {
    [CmdletBinding()]
    param()

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe -d Ubuntu docker image inspect alfa-llamacpp-rpc:cuda128 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Initialize-GamingWorkerWindowsCache {
    [CmdletBinding()]
    param()

    $commonDir = Join-Path $PSScriptRoot '..\_common'
    $picker = Join-Path $commonDir 'Get-AlfaWindowsCacheRoot.ps1'
    if (-not (Test-Path -LiteralPath $picker)) {
        throw "Missing shared cache picker: $picker"
    }
    . $picker
    try {
        $root = Get-AlfaWindowsCacheRoot
        $env:ALFA_WINDOWS_CACHE_ROOT = $root
        Write-Host ("  Windows cache root: {0}" -f $root) -ForegroundColor DarkGray
        return $root
    } catch {
        $pickerError = $_.Exception.Message
        if (Test-GamingWorkerRpcImageLoaded) {
            Write-Host ("  WARN: cache root picker failed ({0}); using existing docker image alfa-llamacpp-rpc:cuda128" -f $pickerError) -ForegroundColor Yellow
            return $null
        }
        throw
    }
}
