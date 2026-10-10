#requires -Version 5.1
<#
.SYNOPSIS
    Copy hub llama.cpp.tar.gz into deploy\llamacpp-rpc\vendor\ (LAN-first).
.DESCRIPTION
    Source: \\hub\temp\cluster_members\_common\source-tarballs\llama.cpp.tar.gz
    When the UNC path is inaccessible (common over OpenSSH on gaming hosts), skip
    sync if a local vendor copy already exists. inference deploy prefers the hub
    Docker image (alfa-llamacpp-rpc:cuda128) and does not require a rebuild.

    Official: Test-Path may throw UnauthorizedAccessException on UNC without
    credentials (https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/test-path).
    Use try/catch + -ErrorAction Stop so StrictMode does not abort the deploy.
.PARAMETER RepoDir
    Git root (e.g. C:/Users/operator\alfa-ai).
#>
param(
    [Parameter(Mandatory)]
    [string]$RepoDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hubTar = '\\hub\temp\cluster_members\_common\source-tarballs\llama.cpp.tar.gz'
$vendor = Join-Path $RepoDir 'deploy\llamacpp-rpc\vendor'
$dest = Join-Path $vendor 'llama.cpp.tar.gz'

$commonDir = Join-Path $RepoDir 'deploy\cluster-members\_common'
$hubPrompt = Join-Path $commonDir 'hub-fallback-prompt.ps1'
if ((Test-Path -LiteralPath $hubPrompt) -and -not (Get-Command Assert-AlfaHubFallbackProceed -ErrorAction SilentlyContinue)) {
    . $hubPrompt
}

$hubReadable = $false
try {
    $hubReadable = [bool](Test-Path -LiteralPath $hubTar -ErrorAction Stop)
} catch {
    Write-Warning ("Hub vendor UNC not readable ({0}): {1}" -f $hubTar, $_.Exception.Message)
    $hubReadable = $false
}

if (-not $hubReadable) {
    if (Test-Path -LiteralPath $dest) {
        Write-Host ("Skip hub vendor sync - using local copy: {0}" -f $dest) -ForegroundColor Yellow
        return
    }
    # Do not prompt (Read-Host hangs under OpenSSH). inference deploy loads
    # alfa-llamacpp-rpc:cuda128 from C:\alfa-ai-cache\docker-images next.
    Write-Warning "Hub tarball missing or inaccessible: $hubTar (continuing; prefer docker load of alfa-llamacpp-rpc:cuda128)."
    return
}

New-Item -ItemType Directory -Force -Path $vendor | Out-Null
# Test-Path can succeed on UNC while Copy-Item still gets Access Denied
# (OpenSSH / ACL). Never abort pool deploy for vendor - runtime uses hub image.
try {
    Copy-Item -Force -Path $hubTar -Destination $dest -ErrorAction Stop
    Write-Host "Synced llama.cpp vendor: $hubTar -> $dest" -ForegroundColor Green
} catch {
    Write-Warning ("Hub vendor copy failed ({0}): {1}" -f $hubTar, $_.Exception.Message)
    if (Test-Path -LiteralPath $dest) {
        Write-Host ("Using existing local vendor: {0}" -f $dest) -ForegroundColor Yellow
        return
    }
    Write-Warning "Continuing without vendor sync; prefer docker load of alfa-llamacpp-rpc:cuda128."
    return
}
