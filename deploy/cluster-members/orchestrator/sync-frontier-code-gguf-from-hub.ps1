<#
.SYNOPSIS
    Copy Qwen3.8-27B Q8_0 GGUF from hub to orchestrator local cache (hub-first, no internet).
.DESCRIPTION
    Reads from inference NFS export via scp (hub at /mnt/cluster/llama-cpp/models/).
    Destination: <Get-AlfaWindowsCacheRoot>\llama-cpp\models\Qwen3.8-27B-Q8_0.gguf
    Rollback: set inference_MODEL_FILE=Qwen3.6-27B-Q8_0.gguf
.EXAMPLE
    .\sync-frontier-code-gguf-from-hub.ps1
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_common\Get-AlfaWindowsCacheRoot.ps1')
$DestDir = Join-Path (Get-AlfaWindowsCacheRoot) 'llama-cpp\models'
$ModelFile = if ($env:inference_MODEL_FILE) { $env:inference_MODEL_FILE } else { 'Qwen3.8-27B-Q8_0.gguf' }
$DestFile = Join-Path $DestDir $ModelFile
$HubHost = 'operator@orchestrator'
$HubPath = "/mnt/cluster/llama-cpp/models/$ModelFile"

if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

if (Test-Path $DestFile) {
    $size = (Get-Item $DestFile).Length
    if ($size -gt 25000000000) {
        Write-Host "Already present: $DestFile ($([math]::Round($size/1GB, 2)) GB)" -ForegroundColor Green
        exit 0
    }
    Write-Host "Removing incomplete file ($size bytes)..." -ForegroundColor Yellow
    Remove-Item -Force $DestFile
}

Write-Host "Copying from $HubHost`:$HubPath -> $DestFile (~29 GB, may take several minutes)..." -ForegroundColor Cyan
& scp -o BatchMode=yes "${HubHost}:${HubPath}" $DestFile
if ($LASTEXITCODE -ne 0) {
    throw "scp failed (exit $LASTEXITCODE). Ensure SSH key auth to inference works."
}

Write-Host "Done: $DestFile ($([math]::Round((Get-Item $DestFile).Length/1GB, 2)) GB)" -ForegroundColor Green
