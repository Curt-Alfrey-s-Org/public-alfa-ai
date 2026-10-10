#Requires -Version 5.1
<#
.SYNOPSIS
  Pull latest brain_redeploy_missions log from hub to this host (orchestrator).

.DESCRIPTION
  hub often cannot open TCP/22 to Windows orchestrator (firewall / OpenSSH inbound).
  Agents on orchestrator should pull logs instead (scp-direction: diagnostic host initiates).

  Official OpenSSH scp: https://man.openbsd.org/scp.1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pull-brain-redeploy-log-from-111.ps1
#>
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DestDir = Join-Path $RepoRoot "logs\brain-redeploy"
$Key = Join-Path $env:USERPROFILE ".ssh\id_ed25519_93_111"
$RemoteHost = "operator@hub"
$RemoteGlob = "/mnt/HDDs/Alfa-AI/agent-audit-logs/brain-redeploy/brain-redeploy-missions-*.log"

if (-not (Test-Path -LiteralPath $Key)) {
  throw "Missing SSH key: $Key"
}

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

$latest = & ssh.exe -i $Key -o BatchMode=yes $RemoteHost "ls -1t $RemoteGlob 2>/dev/null | head -1"
if ([string]::IsNullOrWhiteSpace($latest)) {
  throw "No brain-redeploy-missions-*.log found on hub under agent-audit-logs/brain-redeploy/"
}

$latest = $latest.Trim()
Write-Host "Pulling $latest"
& scp.exe -i $Key -o BatchMode=yes "${RemoteHost}:${latest}" $DestDir
if ($LASTEXITCODE -ne 0) {
  throw "scp failed exit=$LASTEXITCODE"
}

$base = Split-Path -Leaf $latest
$local = Join-Path $DestDir $base
Write-Host "OK $local"
Write-Host "Hard errors:"
Select-String -Path $local -Pattern "FAIL |ERROR:|hard error|brain_verify FAILED" | Select-Object -Last 20
