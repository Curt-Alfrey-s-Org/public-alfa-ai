#Requires -Version 5.1
<#
.SYNOPSIS
    Follow the newest cluster start/stop orchestrator log (errors and phases).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Tail-AlfaClusterLog.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    Write-Host "Log dir missing: $logDir" -ForegroundColor Red
    exit 1
}

Write-Host "Watching cluster-*.log under:" -ForegroundColor Cyan
Write-Host "  $logDir"
Write-Host "Stop this tail with Ctrl+C." -ForegroundColor DarkGray
Write-Host ""

$activePath = $null
$lastSize = 0

while ($true) {
    $latest = Get-ChildItem -Path $logDir -Filter 'cluster-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] waiting for cluster-*.log ..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
        continue
    }

    if (-not $activePath -or $activePath -ne $latest.FullName) {
        $activePath = $latest.FullName
        $lastSize = 0
        Write-Host ""
        Write-Host "=== $($latest.Name) ===" -ForegroundColor Magenta
        Write-Host ""
    }

    $info = Get-Item -LiteralPath $activePath
    if ($info.Length -gt $lastSize) {
        $stream = [System.IO.File]::Open($activePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $null = $stream.Seek($lastSize, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($stream)
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                if ($line -match '\[(ERROR|FAIL|WARN)\s*\]' -or $line -match 'TerminatingError|failed|throw') {
                    Write-Host $line -ForegroundColor Red
                } elseif ($line -match '\[STEP\s*\]' -or $line -match 'PHASE:') {
                    Write-Host $line -ForegroundColor Cyan
                } elseif ($line -match '\[OK\s*\]') {
                    Write-Host $line -ForegroundColor Green
                } else {
                    Write-Host $line
                }
            }
            $lastSize = $stream.Position
        } finally {
            $stream.Close()
        }
    }

    Start-Sleep -Milliseconds 800
}
