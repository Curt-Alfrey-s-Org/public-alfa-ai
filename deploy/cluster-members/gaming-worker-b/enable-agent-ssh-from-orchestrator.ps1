#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Enable OpenSSH Server on gaming-worker-b (gaming-b) and install the orchestrator agent public key.

.DESCRIPTION
  One-time (or re-run) Admin script so Cursor on orchestrator can SSH like other cluster hosts.

  Official sources:
  - Install: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse
  - Keys: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement
  - Server config / DefaultShell:
    https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_server_configuration

  Admin accounts use C:\ProgramData\ssh\administrators_authorized_keys (not profile
  authorized_keys). Standard accounts use %USERPROFILE%\.ssh\authorized_keys.

.PARAMETER PublicKeyFile
  Path to id_ed25519_93_249.pub (default: same folder as this script).

.PARAMETER TargetUser
  Windows account that orchestrator will SSH as (default: current Admin session user).

.PARAMETER SkipDefaultShell
  Do not set HKLM OpenSSH DefaultShell to Windows PowerShell 5.1.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\gaming-worker-b\enable-agent-ssh-from-93.ps1
#>
[CmdletBinding()]
param(
    [string]$PublicKeyFile = '',
    [string]$TargetUser = $env:USERNAME,
    [switch]$SkipDefaultShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Step([string]$Msg) {
    Write-Host "== $Msg ==" -ForegroundColor Cyan
}

function Get-PubKeyLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Public key file missing: $Path. On orchestrator run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md)., copy the .pub to this folder, or git pull after commit."
    }
    $line = (Get-Content -LiteralPath $Path | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -First 1)
    if (-not $line) { throw "Public key file empty: $Path" }
    $line = $line.Trim()
    if (-not $line.StartsWith('ssh-')) {
        throw "Not an OpenSSH public key line: $Path"
    }
    return $line
}

function Ensure-OpenSshServer {
    Step 'OpenSSH Server capability'
    $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    if (-not $cap) {
        throw 'OpenSSH.Server capability not found (need Windows 10 1809+). See Microsoft OpenSSH install docs.'
    }
    if ($cap.State -ne 'Installed') {
        Write-Host "Installing $($cap.Name) ..."
        $result = Add-WindowsCapability -Online -Name $cap.Name
        Write-Host ("RestartNeeded={0}" -f $result.RestartNeeded)
    } else {
        Write-Host "Already installed: $($cap.Name)"
    }

    Step 'sshd service Automatic + Start'
    Get-Service -Name sshd | Set-Service -StartupType Automatic
    Start-Service sshd
    $svc = Get-Service -Name sshd
    if ($svc.Status -ne 'Running') {
        throw "sshd not Running (status=$($svc.Status))"
    }
    Write-Host "sshd status: $($svc.Status)"

    $fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($fw) {
        if ($fw.Enabled -ne 'True') {
            Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
            Write-Host 'Enabled firewall rule OpenSSH-Server-In-TCP'
        } else {
            Write-Host 'Firewall rule OpenSSH-Server-In-TCP already enabled'
        }
    } else {
        Write-Host 'WARN: OpenSSH-Server-In-TCP rule missing; creating ALFa rule for TCP 22' -ForegroundColor Yellow
        New-NetFirewallRule -DisplayName 'ALFa OpenSSH Server (TCP 22)' `
            -Name 'ALFa-OpenSSH-Server-In-TCP' `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    }
}

function Test-LocalUserIsAdmin([string]$UserName) {
    $localAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
    foreach ($m in $localAdmins) {
        $n = $m.Name
        if ($n -eq $UserName) { return $true }
        if ($n -like "*\$UserName") { return $true }
        if ($n -like ".\${UserName}") { return $true }
    }
    return $false
}

function Install-AuthorizedKey([string]$UserName, [string]$PubLine) {
    $isAdmin = Test-LocalUserIsAdmin -UserName $UserName
    if ($isAdmin) {
        Step "Install key for admin user $UserName -> administrators_authorized_keys"
        $dest = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $sshDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $sshDir)) {
            New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        }
        $existing = @()
        if (Test-Path -LiteralPath $dest) {
            $existing = Get-Content -LiteralPath $dest | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        if ($existing -contains $PubLine) {
            Write-Host 'Public key already present in administrators_authorized_keys'
        } else {
            Add-Content -LiteralPath $dest -Value $PubLine -Encoding ASCII
            Write-Host "Appended key to $dest"
        }
        # ACL: Administrators + SYSTEM only (use SIDs for locale-safe grants).
        # https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement
        & icacls.exe $dest /inheritance:r /grant '*S-1-5-32-544:F' /grant 'SYSTEM:F' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls failed for $dest exit=$LASTEXITCODE"
        }
        Write-Host "ACL set on $dest (Administrators+SYSTEM)"
    } else {
        Step "Install key for standard user $UserName -> profile authorized_keys"
        $profileRoot = Join-Path 'C:\Users' $UserName
        if (-not (Test-Path -LiteralPath $profileRoot)) {
            throw "Profile not found: $profileRoot"
        }
        $sshDir = Join-Path $profileRoot '.ssh'
        if (-not (Test-Path -LiteralPath $sshDir)) {
            New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        }
        $dest = Join-Path $sshDir 'authorized_keys'
        $existing = @()
        if (Test-Path -LiteralPath $dest) {
            $existing = Get-Content -LiteralPath $dest | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        if ($existing -contains $PubLine) {
            Write-Host "Public key already present in $dest"
        } else {
            Add-Content -LiteralPath $dest -Value $PubLine -Encoding ASCII
            Write-Host "Appended key to $dest"
        }
    }
    return $isAdmin
}

function Set-OpenSshDefaultShell {
    Step 'DefaultShell = Windows PowerShell 5.1'
    $path = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $shell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    New-ItemProperty -Path $path -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    Write-Host "DefaultShell=$shell"
}

# --- main ---
if (-not $PublicKeyFile) {
    $PublicKeyFile = Join-Path $PSScriptRoot 'id_ed25519_93_249.pub'
}

Step 'enable-agent-ssh-from-93 start'
Write-Host "TargetUser=$TargetUser"
Write-Host "PublicKeyFile=$PublicKeyFile"

$pub = Get-PubKeyLine -Path $PublicKeyFile
Ensure-OpenSshServer
$asAdmin = Install-AuthorizedKey -UserName $TargetUser -PubLine $pub
if (-not $SkipDefaultShell) {
    Set-OpenSshDefaultShell
}

Write-Host ''
Write-Host 'RESULT: OK' -ForegroundColor Green
Write-Host "SSH user: $TargetUser (admin_key_file=$asAdmin)"
Write-Host 'From orchestrator (operator) smoke:'
Write-Host ("  ssh -i `$env:USERPROFILE\.ssh\id_ed25519_93_249 -o BatchMode=yes {0}@orchestrator hostname" -f $TargetUser)
Write-Host 'If BatchMode fails, accept host key once interactively then rerun BatchMode.'
