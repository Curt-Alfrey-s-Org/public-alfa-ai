#Requires -Version 5.1
<#
.SYNOPSIS
    Wait for llama.cpp rpc-server TCP accept (WSL Docker; any LAN host).
#>
Set-StrictMode -Version Latest

function Wait-AlfaRpcServerPort {
    [CmdletBinding()]
    param(
        [int]$Port = 31350,
        [string]$HostName = '127.0.0.1',
        [string]$ContainerName = 'llamacpp-rpc-server',
        [int]$TimeoutSec = 300,
        [int]$IntervalSec = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Host "Polling rpc-server ${HostName}:$Port (timeout ${TimeoutSec}s)..." -ForegroundColor Cyan

    while ((Get-Date) -lt $deadline) {
        # nc -z prints "Connection to ... succeeded!" to stderr even on success;
        # under a caller's $ErrorActionPreference = 'Stop' that native stderr
        # write becomes a terminating error. Guard locally so this function is
        # safe regardless of caller context.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = wsl.exe -d Ubuntu bash -lc "nc -z -w 3 $HostName $Port" 2>&1
            $ncExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($ncExit -eq 0) {
            Write-Host "rpc-server ready on ${HostName}:$Port" -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds $IntervalSec
    }

    throw "rpc-server :$Port not ready after ${TimeoutSec}s (check: wsl -d Ubuntu docker logs $ContainerName)"
}
