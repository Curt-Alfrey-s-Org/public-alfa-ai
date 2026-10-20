#Requires -Version 5.1
<#
.SYNOPSIS
    Stop LiteLLM on hub during G-rev model load (avoids probe traffic to half-loaded servers).
.DESCRIPTION
    LiteLLM health probes and client traffic during llama-server init can destabilize
    first load. Stop alfa-ai-litellm on the brain host before coordinator/local deploy.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$brainUrl = 'http://hub/health/liveliness'
Write-Host "Checking LiteLLM at $brainUrl ..." -ForegroundColor Cyan

$alive = $false
try {
    curl.exe -fsS --max-time 5 $brainUrl 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $alive = $true }
} catch {
    $alive = $false
}

if (-not $alive) {
    Write-Host 'LiteLLM already down or unreachable (OK for load).' -ForegroundColor Green
    exit 0
}

Write-Host 'LiteLLM is UP. Stop it on hub before model load:' -ForegroundColor Yellow
Write-Host '  From hub (operator): sudo docker stop alfa-ai-litellm'
Write-Host ''
Write-Host 'Or SSH from inference/ansible if configured. Continuing without remote stop.'
