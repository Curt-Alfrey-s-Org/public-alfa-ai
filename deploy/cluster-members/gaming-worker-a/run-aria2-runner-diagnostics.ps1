#Requires -Version 5.1
# Diagnostics wrapper: runs run-aria2-bootstrap-with-log.ps1 through the shared
# Invoke-WithLog helper so its output is captured as UTF-8 with no spurious
# NativeCommandError termination on native-tool stderr.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$hostFolder = 'gaming-worker-a-219'
$root       = Join-Path $PSScriptRoot ''
$runner     = Join-Path $root 'run-aria2-bootstrap-with-log.ps1'
$helper     = Join-Path $PSScriptRoot '..\_common\Invoke-WithLog.ps1'
$logsDir    = Join-Path $root 'logs'
$null = New-Item -ItemType Directory -Force -Path $logsDir

$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$manualLog = Join-Path $logsDir ("manual-launch-{0}-{1}.log" -f $env:COMPUTERNAME, $ts)

Write-Host "== Runner diagnostics for $hostFolder ==" -ForegroundColor Cyan
Write-Host "Runner path: $runner"
Write-Host "Runner exists: $(Test-Path $runner)"

if (-not (Test-Path $runner)) {
    Write-Host "Runner script missing: $runner" -ForegroundColor Red
    exit 2
}

& $helper -ScriptPath $runner -LogPath $manualLog
$exit = $LASTEXITCODE

$share = "\\hub\temp\cluster_members\$hostFolder\logs"
try {
    $null = New-Item -ItemType Directory -Force -Path $share -ErrorAction Stop
    Copy-Item -LiteralPath $manualLog -Destination $share -Force -ErrorAction Stop
    Write-Host "COPIED TO: $share" -ForegroundColor Green
} catch {
    Write-Host "WARN: could not copy log to $share : $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "MANUAL LOG: $manualLog" -ForegroundColor Green
exit $exit
