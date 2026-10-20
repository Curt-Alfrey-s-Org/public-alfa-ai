#Requires -Version 5.1
<#
.SYNOPSIS
    One-command worker deploy for gaming-worker-a (gaming-a).

.DESCRIPTION
    Runs firewall + deploy + smoke checks, captures a full transcript, and SCPs
    logs to inference hub for analysis (remote building - do not paste logs into chat).

    Local transcript:
      deploy\cluster-members\gaming-worker-a\logs\build-start-<UTC>.log

    Uploaded to inference hub (automatic unless -SkipLogUpload):
      operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/
        - build-start-*.log (this run)
        - alfa-docker-<hostname>-*.log (docker containers)

    Requires: Git for Windows (bash.exe for docker log collector), SSH key to inference hub.

.EXAMPLE
    cd C:\Users\YOURUSER\alfa-ai
    git pull --ff-only origin main
    powershell -NoProfile -ExecutionPolicy Bypass -File `
        .\deploy\cluster-members\gaming-worker-a\build-start-gaming-worker-a-219.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$SkipMirror,
    [switch]$SkipFirewall,
    [switch]$SkipAutoBootstrap,
    [switch]$SkipSmoke,
    [switch]$SkipLogUpload,
    [switch]$SkipPrep,
    [switch]$ForceBuild,
    [string]$hubSmbUser = 'Corey'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MemberDir = $PSScriptRoot

. (Join-Path $MemberDir 'Initialize-GamingWorkerCache.ps1')
Initialize-GamingWorkerWindowsCache | Out-Null

. (Join-Path $MemberDir '..\_common\invoke-build-start-worker.ps1')

Invoke-AlfaBuildStartWorker `
    -MemberDir          $MemberDir `
    -MemberFolder       'gaming-worker-a-219' `
    -MachineName        'gaming-worker-a' `
    -MachineIP          'orchestrator' `
    -FirewallPrefix     'ALFa gaming-worker-a-219' `
    -FirewallTcpPorts   @(31330, 31331, 5003) `
    -hubSmbUser     $hubSmbUser `
    -SkipPull:$SkipPull `
    -SkipMirror:$SkipMirror `
    -SkipFirewall:$SkipFirewall `
    -SkipAutoBootstrap:$SkipAutoBootstrap `
    -SkipSmoke:$SkipSmoke `
    -SkipLogUpload:$SkipLogUpload `
    -SkipPrep:$SkipPrep `
    -ForceBuild:$ForceBuild
