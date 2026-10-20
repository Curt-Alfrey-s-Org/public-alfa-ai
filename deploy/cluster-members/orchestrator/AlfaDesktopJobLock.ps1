#Requires -Version 5.1
<#
.SYNOPSIS
  One in-flight start/stop across ALFa Models and ALFa Trainer 7B.

.DESCRIPTION
  Atomic create of deploy/llamacpp-rpc/alfa-desktop-job.lock so Models Start/Stop
  cluster cannot run at the same time as Trainer Start/Stop (and CLI of those scripts).
  FileMode.CreateNew throws if the file exists:
  https://learn.microsoft.com/en-us/dotnet/api/system.io.filemode
  FileShare.Read lets the other GUI read KIND/ACTION/PID:
  https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare
  Stale PID: Get-Process -Id
  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-process?view=powershell-5.1

  Nested Stop trainer from a failed Start uses env ALFA_DESKTOP_JOB_NEST=1 (child PID)
  so cleanup does not deadlock on the parent lock.

.NOTES
  Dot-source from Start-Stop-AlfaAi.ps1, Start/Stop train scripts, and both GUIs.
#>

function Get-AlfaDesktopJobLockPath {
    param([string]$RepoDir)
    if ([string]::IsNullOrWhiteSpace($RepoDir)) {
        $RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    }
    return (Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-desktop-job.lock')
}

function Get-AlfaDesktopJobLockInfo {
    param([string]$RepoDir)
    $path = Get-AlfaDesktopJobLockPath -RepoDir $RepoDir
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $kind = ''
    $action = ''
    $ownerPid = 0
    foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if ($line -match '^KIND=(.+)$') { $kind = $Matches[1].Trim() }
        elseif ($line -match '^ACTION=(.+)$') { $action = $Matches[1].Trim() }
        elseif ($line -match '^PID=(\d+)$') { $ownerPid = [int]$Matches[1] }
    }
    if ($ownerPid -le 0) {
        return @{
            Path     = $path
            Kind     = $kind
            Action   = $action
            OwnerPid = $ownerPid
            Live     = $false
        }
    }
    $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    $live = $false
    if ($null -ne $proc) { $live = $true }
    return @{
        Path     = $path
        Kind     = $kind
        Action   = $action
        OwnerPid = $ownerPid
        Live     = $live
    }
}

function Test-AlfaTrainRuntimeLockPresent {
    param([string]$RepoDir)
    if ([string]::IsNullOrWhiteSpace($RepoDir)) {
        $RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    }
    $trainLock = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-train.lock'
    return (Test-Path -LiteralPath $trainLock)
}

function Get-AlfaDesktopJobPeerMessage {
    param(
        [Parameter(Mandatory)][ValidateSet('cluster', 'train')][string]$SelfKind,
        [string]$RepoDir
    )
    # Train containers + alfa-train.lock are independent of cluster Start/Stop orchestrator.
    # Do not block Trainer UI or Stop trainer while Models runs start/stop.
    if ($SelfKind -eq 'train' -and (Test-AlfaTrainRuntimeLockPresent -RepoDir $RepoDir)) {
        return $null
    }
    # SelfKind is the calling GUI. The lock PID is the child Start/Stop script, not
    # the WinForms process, so same-kind still counts as busy (Stop cannot FileMode.CreateNew
    # while Start holds the file).
    $info = Get-AlfaDesktopJobLockInfo -RepoDir $RepoDir
    if ($null -eq $info) { return $null }
    if (-not $info.Live) { return $null }
    if ($info.OwnerPid -eq $PID) { return $null }
    $who = 'ALFa Trainer 7B'
    if ($info.Kind -eq 'cluster') { $who = 'ALFa Models' }
    if ($info.Kind -eq $SelfKind) {
        return ('Wait: {0} {1} is already running (PID {2}).' -f $who, $info.Action, $info.OwnerPid)
    }
    return ('{0} is running {1} (PID {2}). Wait for it to finish.' -f $who, $info.Action, $info.OwnerPid)
}

function Test-AlfaDesktopJobPeerBusy {
    param(
        [Parameter(Mandatory)][ValidateSet('cluster', 'train')][string]$SelfKind,
        [string]$RepoDir
    )
    $msg = Get-AlfaDesktopJobPeerMessage -SelfKind $SelfKind -RepoDir $RepoDir
    return -not [string]::IsNullOrWhiteSpace($msg)
}

function Lock-AlfaDesktopJob {
    param(
        [Parameter(Mandatory)][ValidateSet('cluster', 'train')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('start', 'stop')][string]$Action,
        [string]$RepoDir
    )
    if ($env:ALFA_DESKTOP_JOB_NEST -eq '1') {
        return
    }
    $path = Get-AlfaDesktopJobLockPath -RepoDir $RepoDir
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        throw ("Missing lock directory: {0}" -f $dir)
    }

    # Stop trainer must work while cluster start/stop holds the desktop job lock.
    if ($Kind -eq 'train' -and $Action -eq 'stop') {
        $info = Get-AlfaDesktopJobLockInfo -RepoDir $RepoDir
        if ($null -ne $info -and $info.Live -and $info.Kind -eq 'cluster') {
            return
        }
    }

    $attempt = 0
    while ($attempt -lt 3) {
        $attempt = $attempt + 1
        $info = Get-AlfaDesktopJobLockInfo -RepoDir $RepoDir
        if ($null -ne $info) {
            if ($info.Live) {
                if ($info.OwnerPid -eq $PID) {
                    return
                }
                if ($Kind -eq 'train' -and $Action -eq 'stop' -and $info.Kind -eq 'cluster') {
                    return
                }
                $who = 'ALFa Trainer 7B'
                if ($info.Kind -eq 'cluster') { $who = 'ALFa Models' }
                throw ('{0} is running {1} (PID {2}). Wait for it to finish, then retry.' -f $who, $info.Action, $info.OwnerPid)
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }

        $fs = $null
        try {
            $fs = [System.IO.File]::Open(
                $path,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $stamp = (Get-Date).ToUniversalTime().ToString('o')
            $body = @(
                ('KIND={0}' -f $Kind)
                ('ACTION={0}' -f $Action)
                ('PID={0}' -f $PID)
                ('STARTED_UTC={0}' -f $stamp)
            ) -join "`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($body)
            $fs.Write($bytes, 0, $bytes.Length)
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 200
        } finally {
            if ($null -ne $fs) { $fs.Dispose() }
        }
    }
    throw ("Could not create desktop job lock: {0}" -f $path)
}

function Unlock-AlfaDesktopJob {
    param([string]$RepoDir)
    if ($env:ALFA_DESKTOP_JOB_NEST -eq '1') {
        return
    }
    $info = Get-AlfaDesktopJobLockInfo -RepoDir $RepoDir
    if ($null -eq $info) { return }
    if ($info.OwnerPid -ne $PID) { return }
    Remove-Item -LiteralPath $info.Path -Force -ErrorAction SilentlyContinue
}
