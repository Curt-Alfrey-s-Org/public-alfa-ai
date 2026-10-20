<#
.SYNOPSIS
    Ensure passwordless SSH/SCP from this Windows worker to operator@orchestrator (cluster hub).

.DESCRIPTION
    build-start uploads logs via scp. Without a key, PowerShell hangs on password prompt.

.EXAMPLE
    . .\deploy\cluster-members\_common\ensure-ssh-to-148.ps1
    Ensure-AlfaSshTo148
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest

function Test-AlfaSshTo148 {
    param(
        [string]$SshHost = $(if ($env:SSH_HOST) { $env:SSH_HOST } else { 'operator@orchestrator' })
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new `
        $SshHost 'echo ok' 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
}

function Ensure-AlfaSshTo148 {
    [CmdletBinding()]
    param(
        [string]$SshHost = $(if ($env:SSH_HOST) { $env:SSH_HOST } else { 'operator@orchestrator' }),
        [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
    )

    if (Test-AlfaSshTo148 -SshHost $SshHost) {
        Write-Host "  SSH to $SshHost : OK (key auth)" -ForegroundColor Green
        return $true
    }

    $sshDir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Write-Host "  Generating SSH key: $KeyPath" -ForegroundColor Cyan
        ssh-keygen -t ed25519 -f $KeyPath -N '""' -C "alfa-worker@$(hostname)" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  WARN: ssh-keygen failed - log upload will use -SkipLogUpload' -ForegroundColor Yellow
            return $false
        }
    }

    $pub = Get-Content -LiteralPath "${KeyPath}.pub" -Raw
    Write-Host ''
    Write-Host '=== ONE-TIME: authorize this worker on inference hub (password once) ===' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'From THIS machine (normal PowerShell):' -ForegroundColor Cyan
    Write-Host @"
type `"$KeyPath.pub`" | ssh $SshHost "mkdir -p .ssh && chmod 700 .ssh && chmod 600 .ssh/authorized_keys 2>/dev/null; cat >> .ssh/authorized_keys && chmod 600 .ssh/authorized_keys"
"@
    Write-Host ''
    Write-Host 'Public key (for manual paste on inference if needed):' -ForegroundColor DarkGray
    Write-Host $pub.Trim()
    Write-Host ''
    return $false
}

# Back-compat aliases (deprecated Jul 2026)
function Test-AlfaSshTo148 { Test-AlfaSshTo148 @args }
function Ensure-AlfaSshTo148 { Ensure-AlfaSshTo148 @args }