#Requires -Version 5.1
# Thin wrapper: runs aria2-bootstrap.ps1 via the shared Invoke-WithLog helper,
# which writes a UTF-8 (no BOM) log readable on Linux and does not mis-classify
# native-tool stderr (git fetch etc.) as terminating PowerShell errors.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$hostFolder = 'gaming-worker-b-249'
$bootstrap  = Join-Path $PSScriptRoot 'aria2-bootstrap.ps1'
$helper     = Join-Path $PSScriptRoot '..\_common\Invoke-WithLog.ps1'
$logsDir    = Join-Path $PSScriptRoot 'logs'
$null = New-Item -ItemType Directory -Force -Path $logsDir

$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logsDir ("aria2-bootstrap-{0}-{1}.log" -f $env:COMPUTERNAME, $ts)

Write-Host "Running bootstrap with log capture..." -ForegroundColor Cyan
Write-Host "Log file: $log"

& $helper -ScriptPath $bootstrap -LogPath $log
$exit = $LASTEXITCODE

$share = "\\hub\temp\cluster_members\$hostFolder\logs"
try {
    $null = New-Item -ItemType Directory -Force -Path $share -ErrorAction Stop
    Copy-Item -LiteralPath $log -Destination $share -Force -ErrorAction Stop
    Write-Host "COPIED TO: $share" -ForegroundColor Green
} catch {
    Write-Host "WARN: could not copy log to $share : $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "LOG FILE: $log" -ForegroundColor Green
exit $exit
