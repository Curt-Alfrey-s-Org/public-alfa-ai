<#
.SYNOPSIS
    One-command entry point for orchestrator (operator-93, Win11, primary Dockge host).
    Git-pulls, maps SMB drives, docker-loads the hub image, brings up the
    petals-worker and Dockge on this host. No manual steps.

.DESCRIPTION
    Matches the worker one-shot pattern used by gaming-worker-b-249 / gaming-worker-c-59 /
    gaming-worker-a-219 so every cluster member has a uniform entry point with
    auto-transcript, per-phase timing and heartbeats on long native ops.

    Port note: orchestrator is the primary Dockge host. Its local Dockge runs on
    5002 (same port deploy.ps1 uses), so the workers on 5001 / 5002 / 5003
    can register as agents against it. This run.ps1 brings up the local
    Dockge on 5002 and the petals-worker on this host; it does NOT handle
    remote-agent registration. For the full primary-Dockge-with-remote-
    agent-registration flow (which calls Register-AlfaDockgeAgents against
    apps / hub / gaming-b / gaming-c / gaming-a), use deploy.ps1 in this folder.

.EXAMPLE
    # Elevated PowerShell:
    cd C:\alfa-ai
    git pull
    .\deploy\cluster-members\orchestrator\run.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipPull,
    [switch]$SkipMirror,
    [switch]$SkipAutoBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_common\invoke-worker-oneshot.ps1')

Invoke-AlfaWorkerOneshot `
    -MachineName       'operator-93' `
    -MachineIP         'orchestrator' `
    -MemberFolder      'operator-93' `
    -DockgePortDefault '5002' `
    -SkipPull:$SkipPull `
    -SkipMirror:$SkipMirror `
    -SkipAutoBootstrap:$SkipAutoBootstrap
