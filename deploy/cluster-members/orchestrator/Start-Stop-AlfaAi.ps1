#Requires -Version 5.1
<#
.SYNOPSIS
    Start or stop ALFa AI from orchestrator - use ONLY this wrapper (two commands total).

.DESCRIPTION
    stop  - run stop (protected apps DBs + inference edge stay up); stops embed on pool-opt-in :11435; paste ONE hub command when orchestrator prompts; wait for CLUSTER Stop COMPLETE
    start - run start; starts embed on pool-opt-in :11435 after pool verify; paste ONE hub command per prompt (pool, then brain); wait for CLUSTER Start COMPLETE

    STEP 0 starts error-only log capture on all hosts (hub command prompted first)
    Do NOT run piecemeal deploy-grev27-* scripts for routine ops.

    hub script: deploy/cluster-members/hub/operator-cluster-111.sh
    If start says cluster still up, run stop first.

.EXAMPLE
    cd C:/Users/operator\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'Start', 'Stop')]
    [string]$Mode,

    [switch]$SkipPull,
    [switch]$SkipEdge,
    [switch]$SkipVerify,

    # Gaming-host membership for THIS start (see docs/CLUSTER_START_STOP_OPERATOR.md).
    [ValidateSet('Ask', 'Flags', 'Last', 'None')]
    [string]$GamingMode = 'Ask',
    [switch]$Include59,
    [switch]$Include219,
    [switch]$Include249,
    [switch]$Include248,
    [switch]$Include100,

    # inference = Qwen3.8-27B Q8 (production). inference_38 = legacy alias (same as inference).
    # Pool72 = exclusive Qwen2.5-72B Q5. Pool80 = exclusive Qwen3-Coder-Next Q5.
    [ValidateSet('inference', 'inference_38', 'Pool72', 'Pool80')]
    [string]$InferenceMode = 'inference',

    # 0 means the pool script default (inference 262144/5, Pool72 and Pool80 86016/1).
    [int]$CtxSize = 0,
    [int]$ParallelSlots = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$action = switch ($Mode.ToLower()) {
    'start' { 'Start' }
    'stop'  { 'Stop' }
}

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$jobLockHelper = Join-Path $PSScriptRoot 'AlfaDesktopJobLock.ps1'
if (-not (Test-Path -LiteralPath $jobLockHelper)) {
    throw "Missing $jobLockHelper"
}
. $jobLockHelper

$orchestrator = Join-Path $PSScriptRoot 'Invoke-AlfaAiCluster.ps1'
if (-not (Test-Path -LiteralPath $orchestrator)) {
    throw "Missing orchestrator: $orchestrator"
}

$heldDesktopJob = $false
try {
    Lock-AlfaDesktopJob -Kind cluster -Action $Mode.ToLower() -RepoDir $RepoDir
    $heldDesktopJob = $true
    & $orchestrator -Action $action -SkipPull:$SkipPull -SkipEdge:$SkipEdge -SkipVerify:$SkipVerify `
        -GamingMode $GamingMode -Include59:$Include59 -Include219:$Include219 `
        -Include249:$Include249 -Include248:$Include248 -Include100:$Include100 `
        -InferenceMode $InferenceMode -CtxSize $CtxSize -ParallelSlots $ParallelSlots
    exit $LASTEXITCODE
} finally {
    if ($heldDesktopJob) {
        Unlock-AlfaDesktopJob -RepoDir $RepoDir
    }
}
