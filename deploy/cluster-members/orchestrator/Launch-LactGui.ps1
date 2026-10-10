#Requires -Version 5.1
<#
.SYNOPSIS
  Open LACT GTK GUI from WSL, connected to a remote lactd host.

.DESCRIPTION
  LACT has no browser UI. This launches lact gui over TCP to inference or pool-opt-in.
  Official: https://github.com/ilya-zlobintsev/LACT#remote-management

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-LactGui.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-LactGui.ps1 -TcpHost orchestrator
#>
param(
    [ValidateSet('orchestrator', 'orchestrator')]
    [string]$TcpHost = 'orchestrator'
)

$ErrorActionPreference = 'Stop'
$port = 12853
$bashCmd = "export DISPLAY=:0; exec lact gui --tcp-address ${TcpHost}:$port"
& wsl.exe -d Ubuntu bash -lc $bashCmd
if ($LASTEXITCODE -ne 0) {
    throw "lact gui exited with code $LASTEXITCODE"
}
