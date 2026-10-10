<#
.SYNOPSIS
    Poll an HTTP URL until Invoke-WebRequest succeeds (Windows / PS 5.1).

.EXAMPLE
    . .\Wait-AlfaHttpPoll.ps1
    Wait-AlfaHttpPoll -Url 'http://127.0.0.1:8413/health' -TimeoutSec 180
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest

function Wait-AlfaHttpPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [int]$TimeoutSec = 120,
        [int]$IntervalSec = 5,
        [int]$RequestTimeoutSec = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Host "Polling $Url (timeout ${TimeoutSec}s, interval ${IntervalSec}s)..." -ForegroundColor Cyan

    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $RequestTimeoutSec
            Write-Host "HTTP OK: $Url" -ForegroundColor Green
            return $true
        } catch {
            $msg = $_.Exception.Message.Split("`n")[0]
            Write-Host "  (not ready yet: $msg)" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds $IntervalSec
    }

    Write-Host "WARN: URL did not respond within ${TimeoutSec}s ($Url)" -ForegroundColor Yellow
    return $false
}
