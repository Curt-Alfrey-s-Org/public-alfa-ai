#Requires -Version 5.1
<#
.SYNOPSIS
    One-command worker deploy for gaming-worker-c (gaming-c).

.DESCRIPTION
    Captures transcript + SCPs docker logs to inference hub automatically. See README.md.

    Local:  deploy\cluster-members\gaming-worker-c\logs\build-start-<UTC>.log
    Remote: operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/

.EXAMPLE
    cd C:\Users\YOURUSER\alfa-ai
    git pull --ff-only origin main
    powershell -NoProfile -ExecutionPolicy Bypass -File `
        .\deploy\cluster-members\gaming-worker-c\build-start-gaming-worker-c-59.ps1
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
    [switch]$ForceBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MemberDir = $PSScriptRoot
. (Join-Path $MemberDir '..\_common\invoke-build-start-worker.ps1')

Invoke-AlfaBuildStartWorker `
    -MemberDir          $MemberDir `
    -MemberFolder       'gaming-worker-c-59' `
    -MachineName        'gaming-worker-c' `
    -MachineIP          'orchestrator' `
    -FirewallPrefix     'ALFa gaming-worker-c-59' `
    -FirewallTcpPorts   @(31330, 31331, 31351, 11434) `
    -SkipPull:$SkipPull `
    -SkipMirror:$SkipMirror `
    -SkipFirewall:$SkipFirewall `
    -SkipAutoBootstrap:$SkipAutoBootstrap `
    -SkipSmoke:$SkipSmoke `
    -SkipLogUpload:$SkipLogUpload `
    -SkipPrep:$SkipPrep `
    -ForceBuild:$ForceBuild
