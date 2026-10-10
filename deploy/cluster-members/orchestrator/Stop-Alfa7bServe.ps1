#Requires -Version 5.1
<#
.SYNOPSIS
    Stop standalone 7B llama-server on gaming-c and clear alfa-7b-serve.lock on orchestrator.
.EXAMPLE
    cd C:/Users/operator\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Stop-Alfa7bServe.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ServeLock = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-7b-serve.lock'

$Ssh59 = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'

$stopped = $false
if (Test-Path -LiteralPath $Key59) {
    # Stop only the 7B container by name. Do not `compose down --remove-orphans`
    # from deploy/llamacpp-rpc (default project name would be llamacpp-rpc and
    # would kill a live gaming-c inference shard). Official:
    # https://docs.docker.com/reference/cli/docker/compose/down/
    # https://docs.docker.com/reference/cli/docker/container/rm/
    # Remote default shell is PS 5.1: quoted bash -lc with ";" is split locally
    # on gaming-c. Use wsl -- with no statement separators.
    # https://learn.microsoft.com/en-us/windows/wsl/basic-commands
    $remoteCmd = 'wsl.exe -d Ubuntu -- docker rm -f llamacpp-7b-serve'
    Write-Host '== SSH gaming-c: stop 7B llama-server ==' -ForegroundColor Cyan
    ssh -i $Key59 -o BatchMode=yes -o ConnectTimeout=15 $Ssh59 $remoteCmd
    if ($LASTEXITCODE -eq 0) {
        $stopped = $true
    } else {
        Write-Host "WARN: remote stop returned exit $LASTEXITCODE (continuing lock clear)" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARN: missing SSH key $Key59 -- clearing local lock only" -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $ServeLock) {
    Remove-Item -LiteralPath $ServeLock -Force
    Write-Host "Removed $ServeLock" -ForegroundColor Green
} elseif (-not $stopped) {
    Write-Host "No serve lock present" -ForegroundColor DarkGray
}

Write-Host 'OK: 7B serve stopped (or was not running)' -ForegroundColor Green
