<#
.SYNOPSIS
    LAN bandwidth inventory for Windows cluster workers (orchestrator, gaming-b, gaming-c, gaming-a).

.DESCRIPTION
    Reports Get-NetAdapter link speed, status, and unused/disconnected adapters.
    Reminds that WSL mirrored .92 is the same host as orchestrator -- not extra bandwidth.

    Read-only and idempotent. Does not require Administrator for adapter listing;
    some properties may be limited without elevation.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\lan-bandwidth-inventory.ps1

.NOTES
    PowerShell 5.1 safe (no && / ||). ASCII-only.
    See docs/LAN_BANDWIDTH_UTILIZATION.md for P0 cabling checklist.
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hostLabel = $env:COMPUTERNAME
Write-Host "=== LAN bandwidth inventory: $hostLabel ==="
Write-Host "Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Host ""

$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object InterfaceDescription)
if ($adapters.Count -eq 0) {
    Write-Host 'ERROR: Get-NetAdapter returned no adapters.' -ForegroundColor Red
    exit 1
}

Write-Host '--- adapters ---'
foreach ($a in $adapters) {
    $speed = if ($a.LinkSpeed) { $a.LinkSpeed } else { 'unknown' }
    Write-Host ("name={0} status={1} speed={2} mac={3}" -f $a.Name, $a.Status, $speed, $a.MacAddress)
}

$up = @($adapters | Where-Object { $_.Status -eq 'Up' })
$down = @($adapters | Where-Object { $_.Status -ne 'Up' })

Write-Host ''
Write-Host '=== summary ==='
Write-Host "Host: $hostLabel"
Write-Host 'UP adapters:'
foreach ($a in $up) {
    Write-Host ("  {0}: {1}" -f $a.Name, $a.LinkSpeed)
}

if ($down.Count -gt 0) {
    Write-Host 'DOWN / disconnected (idle until cabled -- e.g. Intel X540 10GbE on orchestrator):'
    foreach ($a in $down) {
        Write-Host ("  - {0} ({1})" -f $a.Name, $a.InterfaceDescription)
    }
} else {
    Write-Host 'No DOWN adapters detected.'
}

$oneGUp = @($up | Where-Object { $_.LinkSpeed -match '^1 Gbps$' })
if ($oneGUp.Count -gt 0) {
    Write-Host 'Adapters linked at 1 Gbps (cluster iperf often caps here):'
    foreach ($a in $oneGUp) {
        Write-Host ("  - {0}" -f $a.Name)
    }
}

Write-Host ''
Write-Host 'Reminder: WSL .92 and Windows orchestrator are the same physical host -- not duplicate bandwidth.'
Write-Host 'Cable Intel X540 10GbE for 10G path to hub; see docs/LAN_BANDWIDTH_UTILIZATION.md'
