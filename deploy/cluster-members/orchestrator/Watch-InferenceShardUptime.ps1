#Requires -Version 5.1
<#
.SYNOPSIS
    Poll inference shard/coordinator TCP ports and report uptime until a port drops.
.EXAMPLE
    powershell -NoProfile -File Watch-inferenceShardUptime.ps1 -IntervalSec 30 -MaxMinutes 30
#>
param(
    [int]$IntervalSec = 30,
    [int]$MaxMinutes = 30
)

Set-StrictMode -Version Latest

$targets = @(
    @{ Host = 'orchestrator'; Port = 31350; Name = 'orchestrator shard' },
    @{ Host = 'orchestrator'; Port = 31356; Name = 'inference 3060' },
    @{ Host = 'orchestrator'; Port = 31357; Name = 'inference 5060' },
    @{ Host = 'hub'; Port = 31353; Name = 'hub 3050' },
    @{ Host = 'hub'; Port = 31360; Name = 'hub coord' }
)

$start = Get-Date
$deadline = $start.AddMinutes($MaxMinutes)
$firstUp = @{}
$downAt = @{}

Write-Host ("inference uptime watch started {0} (interval {1}s, max {2} min)" -f $start, $IntervalSec, $MaxMinutes)

while ((Get-Date) -lt $deadline) {
    $now = Get-Date
    $line = @()
    foreach ($t in $targets) {
        $r = Test-NetConnection -ComputerName $t.Host -Port $t.Port -WarningAction SilentlyContinue
        $up = $r.TcpTestSucceeded
        $key = "{0}:{1}" -f $t.Host, $t.Port
        if ($up -and -not $firstUp.ContainsKey($key)) {
            $firstUp[$key] = $now
        }
        if (-not $up -and $firstUp.ContainsKey($key) -and -not $downAt.ContainsKey($key)) {
            $downAt[$key] = $now
            $dur = ($now - $firstUp[$key]).TotalSeconds
            Write-Host ("CRASH {0} {1} up_for_sec={2:N0}" -f $t.Name, $key, $dur) -ForegroundColor Red
        }
        $state = if ($up) { 'OPEN' } else { 'down' }
        if ($firstUp.ContainsKey($key)) {
            $age = ((Get-Date) - $firstUp[$key]).TotalSeconds
            $line += ("{0}={1}({2:N0}s)" -f $t.Name, $state, $age)
        } else {
            $line += ("{0}={1}" -f $t.Name, $state)
        }
    }
    Write-Host ("{0}  {1}" -f ($now.ToString('HH:mm:ss')), ($line -join '  '))
    Start-Sleep -Seconds $IntervalSec
}

Write-Host "watch ended"
foreach ($key in $firstUp.Keys) {
    $end = if ($downAt.ContainsKey($key)) { $downAt[$key] } else { Get-Date }
    $sec = ($end - $firstUp[$key]).TotalSeconds
    Write-Host ("SUMMARY {0} up_sec={1:N0}" -f $key, $sec)
}