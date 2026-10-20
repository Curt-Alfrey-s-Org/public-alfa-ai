<#
.SYNOPSIS
    Idempotent iperf3 server bootstrap for ALFa AI Windows cluster members.

.DESCRIPTION
    Prepares a Win11 host (operator-93, gaming-worker-b-249, gaming-worker-c-59, gaming-worker-a-219)
    to RECEIVE iperf3 throughput tests from any other cluster node:

      1. Ensures Docker Desktop is running -- piggybacks on the shared
         Ensure-AlfaWorkerEnvironment helper when available, so a cold box
         auto-starts Docker and waits up to 180s for the engine.
      2. Creates (or refreshes) a Windows Defender Firewall rule named
         'alfa-iperf3-<port>' allowing inbound TCP on the chosen port.
      3. Launches a detached 'iperf3-server' container with
         --restart unless-stopped so it survives Docker restarts and reboots.
      4. Verifies the container is Up and performs a localhost TCP probe.

    Safe to run repeatedly. Re-running tears down the old container first.

.PARAMETER Port
    TCP port iperf3 listens on. Default 5201.

.PARAMETER Stop
    Remove the container AND delete the firewall rule. Use when done testing.

.PARAMETER Status
    Report state only (container + firewall). No changes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1 -Stop

.NOTES
    Requires an elevated PowerShell for the firewall rule. The script warns
    (does not abort) if it cannot create the rule, so a non-admin run still
    gets a running container; the operator can add the rule manually.
#>

[CmdletBinding()]
param(
    [int]$Port = 5201,
    [switch]$Stop,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ContainerName = 'iperf3-server'
$FirewallRule  = "alfa-iperf3-$Port"
$Tag           = '[iperf3-bootstrap]'

function Write-Tag([string]$msg, [string]$color = 'Gray') {
    Write-Host "$Tag $msg" -ForegroundColor $color
}

function Test-DockerReady {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-IPerfContainer {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $line = & docker ps -a --filter "name=^$ContainerName$" --format '{{.Names}}|{{.Status}}|{{.Ports}}' 2>$null
        return $line
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Remove-AlfaFirewallRule {
    $existing = Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Remove-NetFirewallRule -DisplayName $FirewallRule -ErrorAction Stop
            Write-Tag "Removed firewall rule '$FirewallRule'." 'Yellow'
        } catch {
            Write-Tag "Could not remove firewall rule: $_" 'Yellow'
        }
    }
}

function Ensure-AlfaFirewallRule {
    Remove-AlfaFirewallRule
    try {
        New-NetFirewallRule -DisplayName $FirewallRule `
            -Direction Inbound -Protocol TCP -LocalPort $Port `
            -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-Tag "Firewall rule '$FirewallRule' active (inbound TCP $Port)." 'Green'
    } catch {
        Write-Tag "WARN: could not create firewall rule '$FirewallRule' ($_)." 'Yellow'
        Write-Tag "    Re-run this script from an Administrator PowerShell, or add manually:" 'Yellow'
        Write-Tag "    New-NetFirewallRule -DisplayName '$FirewallRule' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" 'Yellow'
    }
}

Write-Host ''
Write-Tag "iperf3 bootstrap (port $Port)" 'Cyan'

# --- STATUS MODE ----------------------------------------------------------
if ($Status) {
    if (Test-DockerReady) {
        $c = Get-IPerfContainer
        if ($c) {
            Write-Tag "Container: $c" 'Green'
        } else {
            Write-Tag "Container: NOT RUNNING" 'Yellow'
        }
    } else {
        Write-Tag "Docker engine unreachable; cannot inspect container." 'Yellow'
    }
    $r = Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue
    if ($r) {
        Write-Tag "Firewall rule '$FirewallRule': active" 'Green'
    } else {
        Write-Tag "Firewall rule '$FirewallRule': NOT SET" 'Yellow'
    }
    exit 0
}

# --- STOP MODE ------------------------------------------------------------
if ($Stop) {
    if (Test-DockerReady) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & docker rm -f $ContainerName 2>$null | Out-Null
        } finally {
            $ErrorActionPreference = $prev
        }
        Write-Tag "Removed container $ContainerName (if it existed)." 'Yellow'
    } else {
        Write-Tag "Docker engine unreachable; skipping container removal." 'Yellow'
    }
    Remove-AlfaFirewallRule
    exit 0
}

# --- START MODE (default) -------------------------------------------------
# 1. Environment readiness (auto-start Docker Desktop if needed)
$envScript = Join-Path $PSScriptRoot '..\deploy\cluster-members\_common\ensure-worker-environment.ps1'
if (Test-Path $envScript) {
    . $envScript
    # Only need Docker for this bootstrap; hub reachability + git are irrelevant.
    Ensure-AlfaWorkerEnvironment -SkipHubProbe
} else {
    if (-not (Test-DockerReady)) {
        throw "Docker engine not reachable and ensure-worker-environment.ps1 not found. Start Docker Desktop manually, then retry."
    }
    Write-Tag "Docker engine reachable." 'Green'
}

# 2. Firewall rule
Ensure-AlfaFirewallRule

# 3. Container
Write-Tag "Launching container '$ContainerName' (networkstatic/iperf3 -s -p $Port)..." 'Cyan'
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker rm -f $ContainerName 2>$null | Out-Null
    & docker run -d `
        --name $ContainerName `
        --restart unless-stopped `
        -p "${Port}:${Port}" `
        networkstatic/iperf3 `
        -s -p $Port | Out-Null
    $runExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prev
}
if ($runExit -ne 0) {
    throw "[iperf3-bootstrap] docker run failed (exit $runExit). Check 'docker logs $ContainerName' and Docker Desktop status."
}

Start-Sleep -Seconds 2
$c = Get-IPerfContainer
if (-not $c -or $c -notlike "*Up*") {
    Write-Tag "WARN: unexpected container state: $c" 'Yellow'
    Write-Tag "Recent container logs:" 'Yellow'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker logs $ContainerName 2>&1 | Select-Object -Last 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    } finally {
        $ErrorActionPreference = $prev
    }
    throw "[iperf3-bootstrap] '$ContainerName' did not come up healthy."
}
Write-Tag "Container: $c" 'Green'

# 4. Localhost TCP probe sanity check
try {
    $probe = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -WarningAction SilentlyContinue -ErrorAction Stop
    if ($probe.TcpTestSucceeded) {
        Write-Tag "Local TCP probe OK (127.0.0.1:$Port)." 'Green'
    } else {
        Write-Tag "Local TCP probe FAILED. vpnkit may still be binding -- wait 10s and retry from peer." 'Yellow'
    }
} catch {
    Write-Tag "Local probe skipped (Test-NetConnection unavailable)." 'Yellow'
}

# 5. Report the LAN IP a client should use.
$lanIp = $null
try {
    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.IPAddress -notlike '172.*' -and
            $_.IPAddress -notlike '10.*' -or
            $_.IPAddress -like 'orchestrator*'
        } |
        Where-Object { $_.IPAddress -like 'orchestrator*' } |
        Select-Object -First 1).IPAddress
} catch { }
if (-not $lanIp) { $lanIp = '<your LAN IP>' }

Write-Host ''
Write-Tag "Ready. Test from another cluster node:" 'Green'
Write-Host "    iperf3 -c $lanIp -p $Port -t 10 -P 4" -ForegroundColor Cyan
Write-Host ''
Write-Tag "When done:   powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1 -Stop" 'Gray'
