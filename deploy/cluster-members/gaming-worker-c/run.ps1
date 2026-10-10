<#
.SYNOPSIS
    One-command entry point for gaming-worker-c (gaming-c, Blackwell-class GPU worker).
    Git-pulls, maps SMB drives, and brings up the Dockge agent. (Petals workers
    are retired; the inference shard is deploy-grev27-pool-shard.ps1.) No manual steps.
.EXAMPLE
    # Elevated PowerShell:
    cd $HOME\alfa-ai
    git pull
    .\deploy\cluster-members\gaming-worker-c\run.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$SkipMirror,
    [switch]$SkipAutoBootstrap,
    [switch]$ForceBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_common\invoke-worker-oneshot.ps1')

Invoke-AlfaWorkerOneshot `
    -MachineName       'gaming-worker-c' `
    -MachineIP         'orchestrator' `
    -MemberFolder      'gaming-worker-c-59' `
    -DockgePortDefault '5001' `
    -SkipPull:$SkipPull `
    -SkipMirror:$SkipMirror `
    -SkipAutoBootstrap:$SkipAutoBootstrap `
    -ForceBuild:$ForceBuild
