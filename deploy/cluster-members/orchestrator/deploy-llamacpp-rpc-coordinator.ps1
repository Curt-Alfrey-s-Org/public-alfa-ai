#Requires -Version 5.1
<#
.SYNOPSIS
    Bring up llama.cpp coordinator (llama-server) on orchestrator:31360 for the frontier pool.
.PARAMETER Profile
    Chat (future 122B), Code (80B tier-3 coding), or Code27 (optional 27B).
#>
param(
    [ValidateSet('Chat', 'Code', 'Code27')]
    [string]$Profile = 'Chat',
    [switch]$SkipLiteLLMGuard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$CommonDir = Join-Path $PSScriptRoot '..\_common'
$Common  = Join-Path $CommonDir 'deploy-llamacpp-rpc.ps1'
. $Common
. (Join-Path $CommonDir 'Get-AlfaWindowsCacheRoot.ps1')
. (Join-Path $CommonDir 'wsl-docker.ps1')
$modelsWin = Join-Path (Get-AlfaWindowsCacheRoot) 'llama-cpp\models'

$targetEnv = Join-Path $RepoDir 'deploy\llamacpp-rpc\.env.rpc'
if (-not (Test-Path $targetEnv)) {
    throw "Missing $targetEnv - run switch-coordinator-profile.ps1 -Profile $Profile first."
}

Write-Host "== orchestrator llama.cpp RPC coordinator (:31360) profile=$Profile ==" -ForegroundColor Cyan
Write-Host "  Repo: $RepoDir"

$modelsWsl = ConvertTo-AlfaWslPath -Path $modelsWin
if ($Profile -eq 'Chat') {
    $check = wsl.exe -d Ubuntu bash -lc "test -f '$modelsWsl/Q3_K_M/Qwen3.5-122B-A10B-Q3_K_M-00001-of-00003.gguf' && echo MODEL_OK || echo MODEL_MISSING"
    if ($check -notmatch 'MODEL_OK') {
        throw @"
Hub chat GGUF not visible in WSL at $modelsWsl.
Mount NFS or copy from hub first.
"@
    }
}
elseif ($Profile -eq 'Code27') {
    if (-not $SkipLiteLLMGuard) {
        $guardScript = Join-Path $PSScriptRoot 'Test-Code27LiteLLMProbeGuard.ps1'
        if (Test-Path -LiteralPath $guardScript) {
            . $guardScript
            Test-Code27LiteLLMProbeGuard
        }
    }
    $resetScript = Join-Path $PSScriptRoot 'reset-code27-rpc-pool.ps1'
    if (Test-Path -LiteralPath $resetScript) {
        & powershell -ExecutionPolicy Bypass -File $resetScript
    }
    $syncNative = Join-Path $PSScriptRoot 'sync-code27-gguf-wsl-native.sh'
    if (Test-Path -LiteralPath $syncNative) {
        Write-Host '== Code27: ensure GGUF on WSL ext4 (not Drvfs) ==' -ForegroundColor DarkGray
        wsl.exe -d Ubuntu bash -lc "bash '/mnt/c/Users/operator/alfa-ai/deploy/cluster-members/orchestrator/sync-code27-gguf-wsl-native.sh'"
        if ($LASTEXITCODE -ne 0) { throw "WSL native GGUF sync failed ($LASTEXITCODE)" }
    }
    $modelsWsl = (wsl.exe -d Ubuntu bash -lc 'printf %s "$HOME/alfa-ai-cache/llama-cpp/models"').Trim()
    $check = wsl.exe -d Ubuntu bash -lc "test -f '$modelsWsl/Qwen3.6-27B-Q4_K_M.gguf' && echo MODEL_OK || echo MODEL_MISSING"
    if ($check -notmatch 'MODEL_OK') {
        throw @"
Code27 GGUF not visible in WSL at $modelsWsl/Qwen3.6-27B-Q4_K_M.gguf.
Run: .\deploy\cluster-members\orchestrator\sync-frontier-code-gguf-from-hub.ps1
"@
    }
}
else {
    $lead = "$modelsWsl/Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf"
    $check = wsl.exe -d Ubuntu bash -lc "test -f '$lead' && echo MODEL_OK || echo MODEL_MISSING"
    if ($check -notmatch 'MODEL_OK') {
        throw @"
Code 80B GGUF not visible in WSL at $lead.
Stage from hub (agentic profile) before deploy.
"@
    }
}

Invoke-AlfaLlamacppRpcDeploy -Role Coordinator -RepoDir $RepoDir -EnvFileRpc $targetEnv

$waitScript = Join-Path $PSScriptRoot '..\_common\Wait-AlfaHttpPoll.ps1'
if ($Profile -eq 'Code27') {
    $code27Wait = Join-Path $PSScriptRoot 'Wait-Code27ModelLoad.ps1'
    if (Test-Path -LiteralPath $code27Wait) {
        & powershell -ExecutionPolicy Bypass -File $code27Wait
    } elseif (Test-Path -LiteralPath $waitScript) {
        . $waitScript
        Wait-AlfaHttpPoll -Url 'http://127.0.0.1:31360/health' -TimeoutSec 1200 -IntervalSec 10
    }
} elseif (Test-Path -LiteralPath $waitScript) {
    . $waitScript
    Wait-AlfaHttpPoll -Url 'http://127.0.0.1:31360/health' -TimeoutSec 900 -IntervalSec 10
} else {
    Write-Host 'WARN: Wait-AlfaHttpPoll.ps1 missing; poll /health manually.' -ForegroundColor Yellow
}

if ($Profile -eq 'Code27') {
    $report = Join-Path $PSScriptRoot 'report-code27-vram-budget.ps1'
    if (Test-Path -LiteralPath $report) {
        & powershell -ExecutionPolicy Bypass -File $report
    }
    $verify = Join-Path $PSScriptRoot 'verify-code27-no-local-weights.ps1'
    if (Test-Path -LiteralPath $verify) {
        & powershell -ExecutionPolicy Bypass -File $verify
    }
}

Write-Host '== coordinator deploy complete ==' -ForegroundColor Green
