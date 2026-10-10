#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test for Get-AlfaWindowsCacheRoot.ps1 (no physical G: required).

.DESCRIPTION
    Parser-checks exported functions and validates path helpers. Does not create
    cache directories or query live drives beyond what path validation needs.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\_test-cache-root-smoke.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'Get-AlfaWindowsCacheRoot.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "FAIL: missing $helper"
}
. $helper

$required = @(
    'Get-AlfaWindowsCacheRoot',
    'Get-AlfaWindowsDockerImagesCacheDir',
    'Assert-AlfaWindowsCacheRootHelperLoaded',
    'ConvertTo-AlfaWindowsCacheWslPath',
    'Join-AlfaRemoteWinPath',
    'Test-AlfaWindowsCacheRootPath',
    'Assert-AlfaDriveNotTooFull'
)
foreach ($name in $required) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "FAIL: missing function $name"
    }
}

try {
    Test-AlfaWindowsCacheRootPath -Path 'C:\wrong-folder'
    throw 'FAIL: Test-AlfaWindowsCacheRootPath should reject non alfa-ai-cache leaf'
}
catch {
    if ($_.Exception.Message -notmatch 'alfa-ai-cache') {
        throw "FAIL: unexpected rejection message: $($_.Exception.Message)"
    }
}

$wsl = ConvertTo-AlfaWindowsCacheWslPath -WinPath 'G:\alfa-ai-cache\docker-images\foo.tar.gz'
$expected = '/mnt/g/alfa-ai-cache/docker-images/foo.tar.gz'
if ($wsl -ne $expected) {
    throw "FAIL: ConvertTo-AlfaWindowsCacheWslPath got '$wsl' expected '$expected'"
}

$remoteJoin = Join-AlfaRemoteWinPath -Parent 'G:\alfa-ai-cache' -Child 'docker-images'
$remoteExpected = 'G:\alfa-ai-cache\docker-images'
if ($remoteJoin -ne $remoteExpected) {
    throw "FAIL: Join-AlfaRemoteWinPath got '$remoteJoin' expected '$remoteExpected'"
}

$usage = Get-AlfaWindowsCacheDriveUsagePercent -SizeBytes 100 -FreeBytes 20
if ($usage -lt 79.9 -or $usage -gt 80.1) {
    throw "FAIL: usage percent expected ~80 got $usage"
}

Write-Host 'PASS: cache-root smoke' -ForegroundColor Green
