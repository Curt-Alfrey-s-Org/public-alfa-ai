#Requires -Version 5.1
# gaming-worker-c gaming-c client env -- route downloads through hub hub aria2 RPC.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:ALFA_AI_WORKER      = 'C:\alfa-ai-worker'
$env:ARIA2_MODE           = 'rpc'
$env:ARIA2_RPC_URL        = 'http://hub/jsonrpc'
# ARIA2_RPC_KEY is not stored in the repo. Set it first (same value as the
# hub aria2 stack), e.g. $env:ARIA2_RPC_KEY = '<secret>' or a user env var.
if ([string]::IsNullOrWhiteSpace($env:ARIA2_RPC_KEY)) {
    Write-Warning 'ARIA2_RPC_KEY is not set; aria2 RPC calls will be rejected until you set it (see deploy/aria2/README.md).'
}
$env:ARIA2_RPC_DIR        = '/downloads'
$env:ARIA2_HOST_STAGING   = '\\hub\temp\models\downloads'

Write-Host 'aria2 env set for gaming-worker-c-59 (gaming-c):' -ForegroundColor Cyan
Write-Host "  ARIA2_MODE        = $($env:ARIA2_MODE)"
Write-Host "  ARIA2_RPC_URL     = $($env:ARIA2_RPC_URL)"
Write-Host "  ARIA2_HOST_STAGING= $($env:ARIA2_HOST_STAGING)"
