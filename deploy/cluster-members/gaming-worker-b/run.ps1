<#
.SYNOPSIS
    One-command entry point for gaming-worker-b (gaming-b, RTX 5070 12 GB Blackwell).
    Git-pulls, maps SMB drives, and brings up the Dockge agent. (Petals workers
    are retired; the inference shard is deploy-grev27-pool-shard.ps1.) No manual steps.
.DESCRIPTION
    Run this from the local git checkout of alfa-ai on this host. Requires:
      - Repo cloned at any local path (e.g. C:\Users\<you>\alfa-ai).
      - Docker Desktop running with WSL2 backend.
      - This host can reach \\hub (hub hub) over SMB.

    First-time only (one-time, interactive): in Docker Desktop ->
      Settings -> Resources -> File Sharing, allow Y:\ and Z:\ so worker
      containers can bind-mount the SMB HF cache.
.EXAMPLE
    # Elevated PowerShell:
    cd $HOME\alfa-ai
    git pull
    .\deploy\cluster-members\gaming-worker-b\run.ps1
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

. (Join-Path $PSScriptRoot 'Initialize-Alfa249CacheRoot.ps1')
Initialize-Alfa249CacheRoot | Out-Null

. (Join-Path $PSScriptRoot '..\_common\invoke-worker-oneshot.ps1')

Invoke-AlfaWorkerOneshot `
    -MachineName       'gaming-worker-b' `
    -MachineIP         'orchestrator' `
    -MemberFolder      'gaming-worker-b-249' `
    -DockgePortDefault '5001' `
    -SkipPull:$SkipPull `
    -SkipMirror:$SkipMirror `
    -SkipAutoBootstrap:$SkipAutoBootstrap `
    -ForceBuild:$ForceBuild
