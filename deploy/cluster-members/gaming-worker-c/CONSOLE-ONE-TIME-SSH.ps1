#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-time SSH bootstrap on gaming-worker-c (gaming-c) so orchestrator never needs the console again.

.DESCRIPTION
  Run this ONCE from Administrator PowerShell on gaming-c (physical console or RDP).
  Installs OpenSSH Server if needed and adds the orchestrator agent public key for Colin.

  After success, from orchestrator:
    ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_59 -o BatchMode=yes Colin@orchestrator hostname

  Official: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse

.EXAMPLE
  cd C:\Users\Colin\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\CONSOLE-ONE-TIME-SSH.ps1
#>
[CmdletBinding()]
param(
    [string]$TargetUser = 'Colin'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MemberDir = $PSScriptRoot
$EnableScript = Join-Path $MemberDir 'enable-agent-ssh-from-93.ps1'
$PubKey = Join-Path $MemberDir 'id_ed25519_93_59.pub'

Write-Host ''
Write-Host '== gaming-worker-c (gaming-c) one-time SSH setup for orchestrator agent ==' -ForegroundColor Cyan
Write-Host "  Member folder: $MemberDir"
Write-Host ''

if (-not (Test-Path -LiteralPath $EnableScript)) {
    throw "Missing $EnableScript. Copy deploy\cluster-members\gaming-worker-c from orchestrator or git pull."
}
if (-not (Test-Path -LiteralPath $PubKey)) {
    throw "Missing $PubKey. On orchestrator run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md). and copy the .pub here."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $EnableScript -TargetUser $TargetUser

Write-Host ''
Write-Host 'Done. Tell orchestrator to run smoke:' -ForegroundColor Green
Write-Host '  ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_59 -o BatchMode=yes Colin@orchestrator hostname'
