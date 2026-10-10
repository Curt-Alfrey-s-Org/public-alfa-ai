<#
.SYNOPSIS
    One-command entry point for gaming-worker-a (gaming-a, Blackwell-class GPU worker).
    Git-pulls, maps SMB drives, docker-loads the hub image, brings up the
    petals-worker. No manual steps.
.EXAMPLE
    # Elevated PowerShell:
    cd $HOME\alfa-ai
    git pull
    .\deploy\cluster-members\gaming-worker-a\run.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$SkipMirror,
    [switch]$SkipAutoBootstrap,
    [switch]$ForceBuild,
    [switch]$NoTranscript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_common\invoke-worker-oneshot.ps1')

Invoke-AlfaWorkerOneshot `
    -MachineName       'gaming-worker-a' `
    -MachineIP         'orchestrator' `
    -MemberFolder      'gaming-worker-a-219' `
    -DockgePortDefault '5003' `
    -SkipPull:$SkipPull `
    -SkipMirror:$SkipMirror `
    -SkipAutoBootstrap:$SkipAutoBootstrap `
    -ForceBuild:$ForceBuild `
    -NoTranscript:$NoTranscript
