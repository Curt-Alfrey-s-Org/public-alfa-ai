#Requires -Version 5.1
<#
.SYNOPSIS
    Remove retired qwen3:4b, qwen3:8b, and qwen3-coder:30b-a3b-q4_K_M from local Ollama.

.DESCRIPTION
    June 2026: these tags are hub-archive only (hub LEGACY_OLLAMA_TAGS).
    Fleet routing uses qwen3.5:27b / qwen3.6:35b-a3b / frontier pool instead.

    Does NOT delete hub blobs on \\hub\ollama\.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy\cluster-members\_common\remove-ollama-qwen3-4b-8b.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$tags = @('qwen3:4b', 'qwen3:8b', 'qwen3-coder:30b-a3b-q4_K_M', 'qwen3.5:27b')

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host 'ollama not on PATH - nothing to remove.'
    exit 0
}

try {
    $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5
} catch {
    Write-Host 'Ollama not reachable on :11434 - nothing to remove.'
    exit 0
}

foreach ($tag in $tags) {
    $listed = & ollama list 2>$null
    if ($listed -match [regex]::Escape($tag)) {
        Write-Host "Removing $tag ..."
        & ollama rm $tag
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ollama rm $tag exited $LASTEXITCODE"
        }
    } else {
        Write-Host "Skip $tag (not installed locally)"
    }
}

Write-Host ''
Write-Host 'Remaining Ollama models:'
& ollama list
