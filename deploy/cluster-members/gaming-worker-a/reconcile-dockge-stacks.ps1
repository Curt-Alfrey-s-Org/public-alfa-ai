<#
.SYNOPSIS
    Re-stage gaming-a stacks for Dockge control and restart the Dockge agent (:5003).

.EXAMPLE
    cd C:\Users\Corey\alfa-ai
    git pull --ff-only origin main
    powershell -NoProfile -ExecutionPolicy Bypass -File `
        .\deploy\cluster-members\gaming-worker-a\reconcile-dockge-stacks.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkerDir = 'C:\alfa-ai-worker',
    [switch]$IncludeLlamacppRpc,
    [switch]$SkipWorkerUp
)

$workerScript = Join-Path $PSScriptRoot '..\_common\reconcile-dockge-stacks-worker.ps1'
& $workerScript `
    -WorkerDir $WorkerDir `
    -MachineIP 'orchestrator' `
    -DockgePortDefault '5003' `
    -IncludeLlamacppRpc:$IncludeLlamacppRpc `
    -SkipWorkerUp:$SkipWorkerUp
