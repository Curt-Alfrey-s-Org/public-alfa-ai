#Requires -Version 5.1
<#
.SYNOPSIS
  After gaming: start WSL Ubuntu. Does not deploy inference rpc-server.

.DESCRIPTION
  llama-server lists RPC hosts at start via --rpc
  (https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md).
  Local deploy-grev27-pool-shard after gaming left an orphan llamacpp-rpc-server
  that blocked 7B Train Start. This script only starts Ubuntu
  (https://learn.microsoft.com/en-us/windows/wsl/basic-commands).
  Put this GPU back in the pool from orchestrator:
  Start-Stop-AlfaAi.ps1 start, answer Y for gaming-b.

.EXAMPLE
  cd C:\Users\cody\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-b\gaming-resume-pool-shard.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '== gaming-worker-b-249: after gaming (WSL only; no shard deploy) ==' -ForegroundColor Cyan

$wslList = wsl.exe -l -v 2>&1 | Out-String
if ($wslList -notmatch 'Ubuntu\s+Running') {
    Write-Host 'Starting WSL Ubuntu...' -ForegroundColor Cyan
    wsl.exe -d Ubuntu echo WSL_OK | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'WSL Ubuntu failed to start'
    }
}

Write-Host 'WSL Ubuntu is running. This script does not start llamacpp-rpc-server.'
Write-Host 'To join inference again: from orchestrator run Start-Stop-AlfaAi.ps1 start and answer Y for gaming-b.'
Read-Host 'Press Enter to close this window'
