#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-time SSH bootstrap on gaming-worker-b (gaming-b) so orchestrator never needs the console again.

.DESCRIPTION
  Run this ONCE from Administrator PowerShell on gaming-b (physical console or RDP).
  Installs OpenSSH Server if needed and adds the orchestrator agent public key.

  After success, from orchestrator:
    ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_249 -o BatchMode=yes cody@orchestrator hostname

  Official: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse

.EXAMPLE
  cd C:/Users/operator\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-b\CONSOLE-ONE-TIME-SSH.ps1
#>
[CmdletBinding()]
param(
    [string]$TargetUser = 'cody'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MemberDir = $PSScriptRoot
$EnableScript = Join-Path $MemberDir 'enable-agent-ssh-from-93.ps1'
$PubKey = Join-Path $MemberDir 'id_ed25519_93_249.pub'

Write-Host ''
Write-Host '== gaming-worker-b (gaming-b) one-time SSH setup for orchestrator agent ==' -ForegroundColor Cyan
Write-Host "  Member folder: $MemberDir"
Write-Host ''

if (-not (Test-Path -LiteralPath $EnableScript)) {
    throw "Missing $EnableScript. Copy deploy\cluster-members\gaming-worker-b from orchestrator or git pull."
}
if (-not (Test-Path -LiteralPath $PubKey)) {
    throw "Missing $PubKey. On orchestrator run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md). and copy the .pub here."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $EnableScript -TargetUser $TargetUser

Write-Host ''
Write-Host 'Done. Tell orchestrator to run smoke:' -ForegroundColor Green
Write-Host ("  ssh -i `$env:USERPROFILE\.ssh\id_ed25519_93_249 -o BatchMode=yes {0}@orchestrator hostname" -f $TargetUser)
