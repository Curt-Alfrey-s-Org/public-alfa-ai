<#
.SYNOPSIS
    Fail loud when cluster deploy ports on Windows are blocked by the wrong process.

.DESCRIPTION
    Authoritative port map: docs/PORT_ASSIGNMENTS.md (Windows orchestrator section).
    deploy.ps1 on operator-93 calls this before compose up.

    Allows listeners owned by Docker/WSL (redeploy). Fails on unexpected occupiers on critical ports.

.EXAMPLE
    . .\deploy\cluster-members\_common\Test-AlfaWindowsDeployPortPreflight.ps1
    Test-AlfaWindowsDeployPortPreflight -Profile gaming-worker-a-219
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-AlfaWindowsPortListeners {
    param([int]$Port)

    $rows = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $rows = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    }
    if (@($rows).Count -eq 0) {
        $netstat = netstat -ano 2>$null | Select-String (":$Port\s+.*LISTENING")
        foreach ($line in $netstat) {
            if ($line -match '\s(\d+)\s*$') {
                $rows += [pscustomobject]@{ OwningProcess = [int]$Matches[1] }
            }
        }
    }

    $out = @()
    foreach ($row in $rows) {
        $listenerPid = [int]$row.OwningProcess
        if ($listenerPid -le 4) { continue }
        $proc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        $name = if ($proc) { $proc.ProcessName } else { 'unknown' }
        $out += [pscustomobject]@{
            Port    = $Port
            Pid     = $listenerPid
            Process = $name
        }
    }
    return @($out | Sort-Object Port, Pid -Unique)
}

function Test-AlfaWindowsPortProcessAllowed {
    param(
        [string]$ProcessName,
        [string[]]$ForbiddenProcessNames
    )

    if (-not $ProcessName) { return $false }
    foreach ($bad in $ForbiddenProcessNames) {
        if ($ProcessName -eq $bad) { return $false }
    }
    if ($ProcessName -match '^(wsl|wslhost|docker|vmwp|com\.docker|System)$') {
        return $true
    }
    if ($ProcessName -match '^Cursor$|^Code$|^devenv$') {
        return $false
    }
    return $false
}

function Test-AlfaWindowsDeployPortPreflight {
    [CmdletBinding()]
    param(
        [ValidateSet('operator-93', 'gaming-worker-a-219', 'gaming-worker-b-249', 'gaming-worker-c-59')]
        [string]$Profile = 'operator-93'
    )

    $forbidden = @('Cursor', 'Code')

    $profiles = @{
        'operator-93' = @(
            @{ Port = 5002;  Owner = 'alfa-dockge (primary Dockge UI)' }
            @{ Port = 31350; Owner = 'llama.cpp rpc-server inference shard (WSL Docker publish)' }
        )
        'gaming-worker-a-219' = @(
            @{ Port = 5003;  Owner = 'Dockge agent (not 5001 - GT3 mobile on Win10)' }
        )
        'gaming-worker-b-249' = @(
            @{ Port = 31360; Owner = 'llama.cpp RPC coordinator (tier 3b)' }
        )
        'gaming-worker-c-59' = @(
            @{ Port = 31351; Owner = 'llama.cpp rpc-server (tier 3b shard)' }
            @{ Port = 11434; Owner = 'Ollama embed + CPU chat' }
        )
    }

    if (-not $profiles.ContainsKey($Profile)) {
        throw "Unknown preflight profile: $Profile"
    }

    Write-Host "== Port preflight ($Profile) ==" -ForegroundColor Cyan
    Write-Host '  See docs/PORT_ASSIGNMENTS.md and docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md' -ForegroundColor DarkGray

    $failed = $false
    foreach ($entry in $profiles[$Profile]) {
        $port = [int]$entry.Port
        $listeners = @(Get-AlfaWindowsPortListeners -Port $port)
        if ($listeners.Count -eq 0) {
            Write-Host ("  OK   :{0,-5} free" -f $port) -ForegroundColor Green
            continue
        }

        foreach ($l in $listeners) {
            $allowed = Test-AlfaWindowsPortProcessAllowed -ProcessName $l.Process -ForbiddenProcessNames $forbidden
            if ($allowed) {
                Write-Host ("  OK   :{0,-5} {1} (PID {2}) - Docker/WSL (redeploy will replace)" -f $port, $l.Process, $l.Pid) -ForegroundColor DarkGreen
            } else {
                $failed = $true
                Write-Host ("  FAIL :{0,-5} {1} (PID {2}) blocks {3}" -f $port, $l.Process, $l.Pid, $entry.Owner) -ForegroundColor Red
            }
        }
    }

    if ($failed) {
        Write-Host ''
        Write-Host 'Port preflight FAILED. Free the ports above before deploy.' -ForegroundColor Red
        Write-Host '  Doc: docs/PORT_ASSIGNMENTS.md -> Windows orchestrator port ownership' -ForegroundColor DarkGray
        Write-Host '  Tip: see docs/PORT_ASSIGNMENTS.md (Windows orchestrator port ownership).' -ForegroundColor DarkGray
        return $false
    }

    Write-Host '  Port preflight passed.' -ForegroundColor Green
    return $true
}
