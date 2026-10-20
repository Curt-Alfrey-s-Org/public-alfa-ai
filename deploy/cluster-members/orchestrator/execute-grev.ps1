#Requires -Version 5.1
<#
.SYNOPSIS
    G-rev cutover orchestration from orchestrator (operator runbook helper).
.DESCRIPTION
    1) LiteLLM probe guard (stop hub :8413 during load)
    2) Deploy orchestrator 35B RPC shard :31350
    3) Print next steps for inference (27B) and hub (coordinator + LiteLLM)
.EXAMPLE
    .\execute-grev.ps1 -Step Shard93
    .\execute-grev.ps1 -Step All
#>
[CmdletBinding()]
param(
    [ValidateSet('Shard93', 'Print', 'All')]
    [string]$Step = 'Print'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

function Invoke-GrevLiteLLMGuard {
    $guard = Join-Path $PSScriptRoot 'Test-GrevLiteLLMProbeGuard.ps1'
    if (Test-Path -LiteralPath $guard) {
        & $guard
    } else {
        Write-Host 'WARN: Test-GrevLiteLLMProbeGuard.ps1 missing; stop LiteLLM on hub manually during load' -ForegroundColor Yellow
    }
}

switch ($Step) {
    'Shard93' {
        Invoke-GrevLiteLLMGuard
        & (Join-Path $PSScriptRoot 'deploy-grev35-shard.ps1')
    }
    'All' {
        Invoke-GrevLiteLLMGuard
        & (Join-Path $PSScriptRoot 'deploy-grev35-shard.ps1')
        Write-Host ''
        Write-Host '== Next: From inference (SSH) ==' -ForegroundColor Cyan
        Write-Host 'bash deploy/cluster-members/inference-coordinator/deploy-grev27-local.sh'
        Write-Host ''
        Write-Host '== Next: From hub (operator) ==' -ForegroundColor Cyan
        Write-Host 'sudo bash deploy/cluster-members/hub/deploy-llamacpp-rpc-shard.sh'
        Write-Host 'sudo bash deploy/cluster-members/hub/deploy-grev35-coordinator.sh'
        Write-Host 'bash deploy/cluster-members/_common/wait-http.sh http://127.0.0.1:31360/health 900'
        Write-Host ''
        Write-Host '== Then: update deploy/.env on hub and recreate LiteLLM ==' -ForegroundColor Cyan
        Write-Host 'LLAMACPP_35B_URL=http://hub/v1'
        Write-Host 'LLAMACPP_CODE27_URL=http://orchestrator/v1'
    }
    default {
        Write-Host 'G-rev rollout order:' -ForegroundColor Cyan
        Write-Host '  1) orchestrator:  .\execute-grev.ps1 -Step Shard93'
        Write-Host '  2) inference: bash deploy/cluster-members/inference-coordinator/deploy-grev27-local.sh'
        Write-Host '  3) apps: bash deploy/cluster-members/apps/deploy-llamacpp-rpc-shard.sh'
        Write-Host '  4) hub: deploy-llamacpp-rpc-shard.sh then deploy-grev35-coordinator.sh'
        Write-Host '  5) hub: git pull; set LLAMACPP_* in deploy/.env; recreate alfa-ai-litellm'
    }
}
