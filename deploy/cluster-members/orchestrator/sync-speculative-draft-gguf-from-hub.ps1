<#
.SYNOPSIS
    Copy Qwen2.5-0.5B-Instruct Q4_K_M draft GGUF from hub to orchestrator (hub-first).
.DESCRIPTION
    Reads from inference NFS export via scp (hub at /mnt/cluster/llama-cpp/models/).
    Destination: <Get-AlfaWindowsCacheRoot>\llama-cpp\models\Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
.EXAMPLE
    .\sync-speculative-draft-gguf-from-hub.ps1
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_common\Get-AlfaWindowsCacheRoot.ps1')
$DestDir = Join-Path (Get-AlfaWindowsCacheRoot) 'llama-cpp\models'
$DestFile = Join-Path $DestDir 'Qwen2.5-0.5B-Instruct-Q4_K_M.gguf'
$HubHost = 'operator@orchestrator'
$HubPath = '/mnt/cluster/llama-cpp/models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf'

if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

if (Test-Path $DestFile) {
    $size = (Get-Item $DestFile).Length
    if ($size -gt 300000000) {
        Write-Host "Already present: $DestFile ($([math]::Round($size/1MB, 1)) MB)" -ForegroundColor Green
        exit 0
    }
    Write-Host "Removing incomplete file ($size bytes)..." -ForegroundColor Yellow
    Remove-Item -Force $DestFile
}

Write-Host "Copying from $HubHost`:$HubPath -> $DestFile (~400 MB)..." -ForegroundColor Cyan
& scp -o BatchMode=yes "${HubHost}:${HubPath}" $DestFile
if ($LASTEXITCODE -ne 0) {
    throw "scp failed (exit $LASTEXITCODE). Seed draft GGUF on hub first (PHASE_E2_SPECULATIVE_OPERATOR.md E2a)."
}

Write-Host "Done: $DestFile ($([math]::Round((Get-Item $DestFile).Length/1MB, 1)) MB)" -ForegroundColor Green
