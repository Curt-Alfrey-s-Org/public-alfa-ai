<#
.SYNOPSIS
    Host orchestrator - single entry point to start primary Dockge UI on orchestrator.

.DESCRIPTION
    Runs deploy.ps1 in this folder (Dockge UI, tunnel_network, agent registration).
    Brain API / LiteLLM stay on hub. llama.cpp RPC shards use deploy-llamacpp-rpc.ps1.

.PARAMETER SkipPull
    Forwarded to deploy.ps1 - skips git pull.

.EXAMPLE
    cd C:/Users/operator\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\build-start-alfa-ai-93.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$deploy = Join-Path $PSScriptRoot 'deploy.ps1'
if (-not (Test-Path -LiteralPath $deploy)) {
    throw "Missing sibling deploy.ps1: $deploy"
}

Write-Host ''
Write-Host '== build-start-alfa-ai-93 -> deploy.ps1 ==' -ForegroundColor Cyan
Write-Host '   Primary Dockge UI + llama.cpp RPC host (no Petals)' -ForegroundColor DarkGray
Write-Host ''

& $deploy -SkipPull:$SkipPull
