#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only WOLF1 (orchestrator) network layout check vs docs/WOLF1_92_X540_BRIDGE.md.

.DESCRIPTION
    Production: orchestrator + gateway + DNS on 10G Network Bridge (X540 members).
    Realtek 5GbE is optional and may stay uncabled.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Verify-Wolf1NetworkLayout.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Mac92A = '98-B7-85-21-1F-D7'
$Mac92B = '98-B7-85-21-1F-D8'
$MacRt  = 'BC-FC-E7-E9-44-A7'

function Get-AdapterByMac {
    param([string]$Mac)
    $norm = ($Mac -replace '-', '').ToUpperInvariant()
    Get-NetAdapter | Where-Object {
        ($_.MacAddress -replace '-', '').ToUpperInvariant() -eq $norm
    } | Select-Object -First 1
}

$fail = 0
Write-Host '== Verify-Wolf1NetworkLayout (read-only) =='

$a92A = Get-AdapterByMac $Mac92A
$a92B = Get-AdapterByMac $Mac92B
$aRt  = Get-AdapterByMac $MacRt

if (-not $a92A) { Write-Host 'FAIL: 92A X540 MAC not found'; $fail++ }
else { Write-Host ("OK  92A: {0} status={1} speed={2}" -f $a92A.Name, $a92A.Status, $a92A.LinkSpeed) }

if (-not $a92B) { Write-Host 'FAIL: 92B X540 MAC not found'; $fail++ }
else { Write-Host ("OK  92B: {0} status={1} speed={2}" -f $a92B.Name, $a92B.Status, $a92B.LinkSpeed) }

if (-not $aRt) { Write-Host 'WARN: Realtek 5GbE MAC not found (optional NIC)'; }
else { Write-Host ("OK  Realtek (optional): {0} status={1} speed={2}" -f $aRt.Name, $aRt.Status, $aRt.LinkSpeed) }

$bridge = Get-NetAdapter -Name 'Network Bridge' -ErrorAction SilentlyContinue
if (-not $bridge) {
    Write-Host 'FAIL: Network Bridge missing (X540 spine down)'
    $fail++
}
else {
    Write-Host ("OK  Network Bridge status={0} speed={1}" -f $bridge.Status, $bridge.LinkSpeed)
}

$ip93 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq 'orchestrator' }

$gwBridge = $null
try {
    $gwBridge = (Get-NetIPConfiguration -InterfaceAlias 'Network Bridge' -ErrorAction Stop).IPv4DefaultGateway
} catch { }

Write-Host 'Mode: PRIMARY -- orchestrator on 10G Network Bridge (production)'

if (-not $ip93 -or $ip93.InterfaceAlias -ne 'Network Bridge') {
    if ($ip93) {
        Write-Host ("FAIL: orchestrator on {0}; production expects Network Bridge (10G)" -f $ip93.InterfaceAlias)
    }
    else {
        Write-Host 'FAIL: orchestrator missing'
    }
    $fail++
}

if ($aRt -and $aRt.Status -eq 'Up' -and $ip93 -and $ip93.InterfaceAlias -eq $aRt.Name) {
    Write-Host 'WARN: orchestrator on Realtek 5GbE (legacy split) -- production doc prefers orchestrator on Network Bridge at 10G'
}

if (-not $gwBridge) {
    Write-Host 'FAIL: no default gateway on Network Bridge (expect orchestrator)'
    $fail++
}

$dnsBridge = Get-DnsClientServerAddress -InterfaceAlias 'Network Bridge' -AddressFamily IPv4 -ErrorAction SilentlyContinue
if ($dnsBridge -and $dnsBridge.ServerAddresses -contains 'orchestrator') {
    Write-Host 'OK  DNS on Network Bridge: orchestrator'
}
elseif ($dnsBridge) {
    Write-Host ("WARN: Network Bridge DNS not .1 only: {0}" -f ($dnsBridge.ServerAddresses -join ','))
}

$wifiDns = Get-DnsClientServerAddress -InterfaceAlias 'Wi-Fi 2' -AddressFamily IPv4 -ErrorAction SilentlyContinue
if ($wifiDns -and $wifiDns.ServerAddresses.Count -gt 0) {
    Write-Host ("WARN: Wi-Fi DNS {0} (cluster policy: .1 only; disable Wi-Fi or fix as operator)" -f ($wifiDns.ServerAddresses -join ','))
}

$prof = Get-NetConnectionProfile -InterfaceAlias 'Network Bridge' -ErrorAction SilentlyContinue
if ($prof -and $prof.NetworkCategory -eq 'Private') {
    Write-Host 'OK  Network Bridge profile: Private (inbound LAN ping OK)'
}
elseif ($prof) {
    Write-Host ("WARN: Network Bridge profile {0} (set Private as operator for LAN ICMP)" -f $prof.NetworkCategory)
}

if ($a92A -and $a92B -and ($a92A.Status -ne 'Up' -or $a92B.Status -ne 'Up')) {
    Write-Host 'FAIL: one or both X540 ports not Up (island spine broken)'
    $fail++
}

foreach ($x540 in @($a92A, $a92B)) {
    if (-not $x540) { continue }
    $lsoProps = @(Get-NetAdapterAdvancedProperty -Name $x540.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Large Send Offload V2*' })
    if ($lsoProps.Count -lt 1) {
        Write-Host ("WARN: no Large Send Offload V2 properties on {0}" -f $x540.Name)
        continue
    }
    foreach ($lsoProp in $lsoProps) {
        if ($lsoProp.DisplayValue -eq 'Disabled') {
            Write-Host ("OK  {0} {1} Disabled" -f $x540.Name, $lsoProp.DisplayName)
        } else {
            Write-Host ("FAIL: {0} {1} is {2}; set Disabled (WOLF1 bridge upload)" -f $x540.Name, $lsoProp.DisplayName, $lsoProp.DisplayValue)
            $fail++
        }
    }
}

if ($fail -eq 0) {
    Write-Host 'PASS Verify-Wolf1NetworkLayout'
    exit 0
}
Write-Host "FAIL Verify-Wolf1NetworkLayout ($fail hard check(s))"
exit 1
