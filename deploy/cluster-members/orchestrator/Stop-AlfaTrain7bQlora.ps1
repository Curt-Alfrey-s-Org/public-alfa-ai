#Requires -Version 5.1
<#
.SYNOPSIS
  Stop 7B QLoRA trainer Docker jobs and clear alfa-train.lock.

.DESCRIPTION
  Stops named alfa-train-7b-* containers on gaming-c (always required) and gaming-b
  (required unless the lock has SINGLE_HOST_59=1). Start/Stop-AlfaTrain14bQlora.ps1
  are gone; docker rm still clears leftover alfa-train-14b-* names from old sessions
  on the same hosts. gaming-a is best-effort.
  Does not stop inference on inference. Clears the lock when all required hosts were killed or
  are powered off (SSH timeout/refused). gaming-a failures alone do not block lock removal.
  Missing keys or auth failure on a required host keeps the lock.

.EXAMPLE
  cd C:/Users/operator\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Stop-AlfaTrain7bQlora.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$LockPath = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-train.lock'

$Ssh59 = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
$Ssh219 = if ($env:inference_SSH_219_TARGET) { $env:inference_SSH_219_TARGET } else { 'Corey@orchestrator' }
$Ssh249 = if ($env:inference_SSH_249_TARGET) { $env:inference_SSH_249_TARGET } else { 'cody@orchestrator' }

$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
$Key219 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_219'
$Key249 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_249'

$PoweredOffPattern = 'Connection timed\s*out|Connection timedout|Connection refused|No route to host|Network is unreachable'
$AuthFailPattern = 'Permission denied|Load key|Authentication failed|Host key verification failed|Could not resolve hostname'

$jobLockHelper = Join-Path $PSScriptRoot 'AlfaDesktopJobLock.ps1'
if (-not (Test-Path -LiteralPath $jobLockHelper)) {
    throw "Missing $jobLockHelper"
}
. $jobLockHelper

$heldDesktopJob = $false
Lock-AlfaDesktopJob -Kind train -Action stop -RepoDir $RepoDir
$heldDesktopJob = $true
try {


# Docker container names only. Do not pkill -f patterns that appear in this
# SSH command line (pkill matches itself and returns non-zero).
# Do NOT docker rm alfa-train-tb here: TensorBoard sidecar stays up across Stop trainer
# so metrics remain at http://127.0.0.1:6006/ (idle, mid-run, after Stop).
# alfa-train-14b-* names: removed 14B Start/Stop scripts; rm clears leftover containers.
$KillRemoteBash = @'
docker rm -f alfa-train-7b-59 alfa-train-7b-249 alfa-train-7b-219 alfa-train-14b-59 alfa-train-14b-249 alfa-train-14b-219 >/dev/null 2>&1 || true
exit 0
'@

$script:KillProblems = New-Object System.Collections.Generic.List[string]
$script:KillRequiredProblems = New-Object System.Collections.Generic.List[string]

function ConvertTo-TrainStopBase64 {
    param([Parameter(Mandatory)][string]$BashBody)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BashBody)
    return [Convert]::ToBase64String($bytes)
}

function Test-TrainSshPoweredOff {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match $PoweredOffPattern)
}

function Test-TrainSshAuthFailure {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match $AuthFailPattern)
}

function Invoke-TrainKillWindows {
    param(
        [string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Required
    )
    if ($KeyPath -and -not (Test-Path -LiteralPath $KeyPath)) {
        $msg = ("{0}: SSH key missing ({1})" -f $Label, $KeyPath)
        Write-Host ("FAIL {0}" -f $msg)
        [void]$script:KillProblems.Add($msg)
        if ($Required) { [void]$script:KillRequiredProblems.Add($msg) }
        return
    }
    $b64 = ConvertTo-TrainStopBase64 -BashBody $KillRemoteBash
    $inner = "echo $b64 | base64 -d > /tmp/alfa-train-stop.sh; chmod +x /tmp/alfa-train-stop.sh; /tmp/alfa-train-stop.sh"
    $remote = "wsl -d Ubuntu -- bash -lc '$inner'"
    Write-Host ("== Kill train {0} ==" -f $Label)
    $out = @()
    if ($KeyPath) {
        $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $KeyPath $Target $remote 2>&1
    } else {
        $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 $Target $remote 2>&1
    }
    $blob = (@($out) | ForEach-Object { if ($null -ne $_) { [string]$_ } }) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        if (Test-TrainSshPoweredOff -Text $blob) {
            Write-Host ("OK {0}: powered off / unreachable (lock not blocked)" -f $Label)
            return
        }
        if (Test-TrainSshAuthFailure -Text $blob) {
            $msg = ("{0}: SSH auth/key failure" -f $Label)
            Write-Host ("FAIL {0}" -f $msg)
            Write-Host $blob
            [void]$script:KillProblems.Add($msg)
            if ($Required) { [void]$script:KillRequiredProblems.Add($msg) }
            return
        }
        $msg = ("{0}: SSH kill failed (exit {1})" -f $Label, $LASTEXITCODE)
        Write-Host ("FAIL {0}" -f $msg)
        if ($blob) { Write-Host $blob }
        [void]$script:KillProblems.Add($msg)
        if ($Required) { [void]$script:KillRequiredProblems.Add($msg) }
    }
}

Write-Host '== Stop 7B QLoRA trainer (gaming-c required; gaming-b required unless SINGLE_HOST_59=1; gaming-a best-effort; leftover alfa-train-14b-* from old sessions also cleared; inference not touched) =='

$singleHost59 = $false
if (Test-Path -LiteralPath $LockPath) {
    foreach ($line in (Get-Content -LiteralPath $LockPath)) {
        if ($line -match '^SINGLE_HOST_59=1$') {
            $singleHost59 = $true
            break
        }
    }
}
if ($singleHost59) {
    Write-Host '== Lock SINGLE_HOST_59=1; gaming-b kill is best-effort =='
}

Invoke-TrainKillWindows -KeyPath $Key59 -Target $Ssh59 -Label 'gaming-c' -Required
if ($singleHost59) {
    Invoke-TrainKillWindows -KeyPath $Key249 -Target $Ssh249 -Label 'gaming-b'
} else {
    Invoke-TrainKillWindows -KeyPath $Key249 -Target $Ssh249 -Label 'gaming-b' -Required
}
Invoke-TrainKillWindows -KeyPath $Key219 -Target $Ssh219 -Label 'gaming-a'

if ($script:KillRequiredProblems.Count -gt 0) {
    Write-Host '== Lock NOT removed (required train host unreachable with auth/key failure) =='
    Write-Host ("Problems: {0}" -f ($script:KillRequiredProblems -join '; '))
    Write-Host ("Fix SSH/keys or power on hosts, re-run Stop-AlfaTrain7bQlora.ps1, then Start cluster. Lock: {0}" -f $LockPath)
    throw 'Stop trainer incomplete; alfa-train.lock kept so Start cluster stays blocked.'
}

if ($script:KillProblems.Count -gt 0) {
    Write-Host ("WARN non-blocking issues (lock still cleared): {0}" -f ($script:KillProblems -join '; '))
}

if (Test-Path -LiteralPath $LockPath) {
    Remove-Item -LiteralPath $LockPath -Force
    Write-Host ("== Lock removed: {0} ==" -f $LockPath)
} else {
    Write-Host '== No lock file (already clear) =='
}

Write-Host '== 7B trainer stopped (leftover alfa-train-14b-* from old sessions cleared too); core 27B was not stopped =='
} finally {
    if ($heldDesktopJob) {
        Unlock-AlfaDesktopJob -RepoDir $RepoDir
    }
}
