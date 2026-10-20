#Requires -Version 5.1
<#
.SYNOPSIS
    Win11 orchestrator client env for model downloads via hub (hub) aria2 RPC.
.DESCRIPTION
    This host should route large HTTP downloads through hub instead of direct
    internet fallback. `ARIA2_MODE=rpc` enforces RPC-only behavior.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:ALFA_AI_REPO      = 'C:/Users/operator\alfa-ai'
$env:ARIA2_MODE         = 'rpc'
$env:ARIA2_RPC_URL      = 'http://hub/jsonrpc'
# ARIA2_RPC_KEY is not stored in the repo. Set it first (same value as the
# hub aria2 stack), e.g. $env:ARIA2_RPC_KEY = '<secret>' or a user env var.
if ([string]::IsNullOrWhiteSpace($env:ARIA2_RPC_KEY)) {
    Write-Warning 'ARIA2_RPC_KEY is not set; aria2 RPC calls will be rejected until you set it (see deploy/aria2/README.md).'
}
$env:ARIA2_RPC_DIR      = '/downloads'
# SMB share path on hub dataset (must be mapped/reachable from this host).
$env:ARIA2_HOST_STAGING = '\\hub\temp\models\downloads'

Write-Host 'aria2 env set for orchestrator (operator-93):' -ForegroundColor Cyan
Write-Host "  ALFA_AI_REPO      = $($env:ALFA_AI_REPO)"
Write-Host "  ARIA2_MODE        = $($env:ARIA2_MODE)"
Write-Host "  ARIA2_RPC_URL     = $($env:ARIA2_RPC_URL)"
Write-Host "  ARIA2_HOST_STAGING= $($env:ARIA2_HOST_STAGING)"
