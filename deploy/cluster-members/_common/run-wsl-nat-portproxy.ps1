<#
.SYNOPSIS
    Refresh WSL NAT portproxy rules (scheduled task / manual re-run).

.DESCRIPTION
    Called at user logon and after deploy on Win10 hosts. Idempotent.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\run-wsl-nat-portproxy.ps1 -TcpPorts 31330,31331,5003
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TcpPorts,
    [string]$Distro = 'Ubuntu',
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'install-wsl-nat-portproxy.ps1'
. $helper

$ports = @($TcpPorts -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
if ($ports.Count -eq 0) {
    throw 'No valid ports in -TcpPorts'
}

if (-not (Test-AlfaWslNatPortProxyRequired)) {
    if (-not $Quiet) {
        Write-Host 'run-wsl-nat-portproxy: mirrored mode - no portproxy needed.' -ForegroundColor DarkGray
    }
    exit 0
}

Set-AlfaWslNatPortProxy -TcpPorts $ports -Distro $Distro
if (-not $Quiet) {
    Write-Host 'run-wsl-nat-portproxy: OK' -ForegroundColor Green
}
