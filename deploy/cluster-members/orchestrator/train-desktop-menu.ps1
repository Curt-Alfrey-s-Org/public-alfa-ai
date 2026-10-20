#Requires -Version 5.1
<#
.SYNOPSIS
  Desktop control panel for the 7B QLoRA trainer (train island gaming-c + gaming-b).

.DESCRIPTION
  WinForms trainer-only GUI:
  - Train island SSH badges (TCP :22 for gaming-c / gaming-b)
  - Start 7B QLoRA / Stop trainer / Open TensorBoard / Refresh
  - Production train is always 2-node DDP + continue v2 LoRA when present.
    Use Start-AlfaTrain7bQlora.ps1 CLI for -SingleHost59 / -FreshAdapter / -Include219.
  - Status line (LAUNCHING / STARTING / TRAINING / FAILED / FINISHED / JOB ENDED / IDLE)
  - Terminal log panel
  Inference models have their own GUI: models-desktop-menu.ps1 (see docs/CLUSTER_START_STOP_OPERATOR.md).
  This GUI never starts or stops the cluster.
  Official Panel: https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.panel
  Official Process.SynchronizingObject: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.synchronizingobject
  Official Timer: https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.timer
  Docs: docs/operations/TRAIN_7B_QLORA_GUI.md
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$LlcDir = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$TrainLockPath = Join-Path $LlcDir 'alfa-train.lock'
$jobLockHelper = Join-Path $PSScriptRoot 'AlfaDesktopJobLock.ps1'
. $jobLockHelper
$TrainStartScript = Join-Path $PSScriptRoot 'Start-AlfaTrain7bQlora.ps1'
$TrainStopScript = Join-Path $PSScriptRoot 'Stop-AlfaTrain7bQlora.ps1'
$TrainTensorBoardScript = Join-Path $PSScriptRoot 'Start-AlfaTrainTensorBoard.ps1'

$Ip59 = 'orchestrator'
$Ip249 = 'orchestrator'

$script:TrainProc = $null
$script:LogExpanded = $false
$script:FormHeightCollapsed = 660
$script:FormHeightExpanded = 880
$script:LogPanelHeight = 220
$script:StatusLights = @{}
$script:KillGuiJobsOnExit = $false
$script:LastTrainExitCode = $null
$script:RunningTrainMode = $null
$script:TrainContainerProbeResult = $null
$script:TrainHubLogPhase = $null
$script:TrainHubLogBlob = $null
$script:TrainContainerProbeAt = [datetime]::MinValue
$script:TrainProbeInFlight = $false
$script:TrainProbeCacheSec = 30
$script:TrainProbeLastError = $null
$script:GuiMenuRev = 'r8'
$script:JobIoUntil = [datetime]::MinValue
$btnTrainStart = $null
$btnTrainStop = $null

# Professional palette (ASCII-only source)
$ColorHeader = [System.Drawing.Color]::FromArgb(28, 40, 56)
$ColorHeaderText = [System.Drawing.Color]::FromArgb(245, 247, 250)
$ColorMuted = [System.Drawing.Color]::FromArgb(120, 130, 140)
$ColorFormBg = [System.Drawing.Color]::FromArgb(236, 239, 243)
$ColorPanel = [System.Drawing.Color]::White
$ColorBorder = [System.Drawing.Color]::FromArgb(210, 216, 224)
$ColorGreen = [System.Drawing.Color]::FromArgb(34, 139, 70)
$ColorGreenBg = [System.Drawing.Color]::FromArgb(220, 242, 226)
$ColorRed = [System.Drawing.Color]::FromArgb(180, 45, 45)
$ColorRedBg = [System.Drawing.Color]::FromArgb(248, 224, 224)
$ColorYellow = [System.Drawing.Color]::FromArgb(160, 120, 20)
$ColorYellowBg = [System.Drawing.Color]::FromArgb(252, 242, 210)
$ColorGray = [System.Drawing.Color]::FromArgb(130, 138, 148)
$ColorGrayBg = [System.Drawing.Color]::FromArgb(232, 235, 239)
$ColorBtnStop = [System.Drawing.Color]::FromArgb(160, 55, 55)
$ColorBtnFlat = [System.Drawing.Color]::FromArgb(248, 249, 251)

function Test-AlfaGuiProcAlive {
    param($Proc)
    if ($null -eq $Proc) { return $false }
    try {
        return (-not $Proc.HasExited)
    } catch {
        return $false
    }
}

function Test-AlfaGuiTrainBusy {
    return (Test-AlfaGuiProcAlive $script:TrainProc)
}

function Update-AlfaGuiJobButtons {
    # Official Process events marshal via SynchronizingObject on the Form:
    # https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.synchronizingobject
    if ($null -eq $btnTrainStart) { return }
    $trainBusy = Test-AlfaGuiTrainBusy
    $locked = Test-AlfaTrainLockPresent
    $peerMsg = Get-AlfaDesktopJobPeerMessage -SelfKind train -RepoDir $RepoDir
    $peerBusy = -not [string]::IsNullOrWhiteSpace($peerMsg)
    $btnTrainStart.Enabled = (-not $trainBusy) -and (-not $locked) -and (-not $peerBusy)
    # Stop must stay available during cluster Start/Stop while train lock/containers are up.
    $btnTrainStop.Enabled = $locked -or (-not $peerBusy)
}

function Clear-AlfaGuiLogIfIdle {
    if (-not (Test-AlfaGuiTrainBusy)) {
        $txtLog.Clear()
    }
}

function Update-AlfaGuiJobIoAfterExit {
    if (Test-AlfaGuiTrainBusy) {
        return
    }
    Set-AlfaGuiBadge -Key 'jobio' -State 'gray'
}

function Append-AlfaGuiLog {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    if ($txtLog.IsDisposed) { return }
    $txtLog.AppendText($Text + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    Set-AlfaGuiBadge -Key 'jobio' -State 'green'
    $script:JobIoUntil = [datetime]::UtcNow.AddMilliseconds(600)
}

function Test-AlfaTrainLockPresent {
    return (Test-Path -LiteralPath $TrainLockPath)
}

function Get-AlfaTrainLockLogDir {
    if (-not (Test-Path -LiteralPath $TrainLockPath)) {
        return $null
    }
    foreach ($line in @(Get-Content -LiteralPath $TrainLockPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^LOGDIR=(.+)$') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Get-AlfaTrainHubLogPhaseFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'starting'
    }
    # Rank-0 LOG_MISSING must not hide rank-1 completion in the same probe blob.
    if ($Text -match 'LOG_MISSING' -and $Text -notmatch 'LOG=OK|LOG249=OK') {
        return 'starting'
    }
    # Order: failed | finished | training | starting. PEFT UserWarning is not failed.
    if ($Text -match 'DistNetworkError|DistStoreError|timed out after|ChildFailedError|RendezvousTimeoutError|RendezvousConnectionError|CUDA out of memory|device not ready|CUDA driver error|PermissionError|bus error|insufficient shared memory|Traceback \(most recent call last\)') {
        return 'failed'
    }
    # Axolotl/HF TrainOutput: https://huggingface.co/docs/transformers/main_classes/trainer
    if ($Text -match 'Training completed|Model successfully saved|train_runtime') {
        return 'finished'
    }
    if ($Text -match '(?i)\bloss\b|Total train batch') {
        return 'training'
    }
    return 'starting'
}

function ConvertTo-AlfaGuiRemoteBase64 {
    param([Parameter(Mandatory)][string]$BashBody)
    # Same quote-avoidance as Start-AlfaTrain7bQlora.ps1: PS -> ssh -> wsl -> bash.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BashBody)
    return [Convert]::ToBase64String($bytes)
}

function Invoke-AlfaTrainContainerProbe59 {
    # docker ps + hub log tail so GUI does not show TRAINING on a silent wedge.
    # docker ps: https://docs.docker.com/reference/cli/docker/container/ps/
    $sshTarget = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
    $keyPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
    $script:TrainHubLogPhase = $null
    $script:TrainProbeLastError = $null
    if (-not (Test-Path -LiteralPath $keyPath)) {
        $script:TrainProbeLastError = 'missing SSH key id_ed25519_93_59'
        return $null
    }
    $logDir = Get-AlfaTrainLockLogDir
    $logPath = if ($logDir) { "$logDir/alfa-train-7b-59.log" } else { '' }
    try {
        $bashLines = @(
            'set +e',
            'out=$(timeout -k 2 8 docker ps -q -f name=alfa-train-7b-59)',
            'st=$?',
            'if [ $st -eq 0 ]; then',
            '  if [ -n "$out" ]; then echo CONTAINER=UP; else echo CONTAINER=DOWN; fi',
            'else',
            '  echo CONTAINER=PROBE_TIMEOUT',
            'fi'
        )
        if ($logPath) {
            $bashLines += ('f="{0}"' -f $logPath)
            $bashLines += 'if [ -f "$f" ]; then echo LOG=OK; timeout -k 2 8 tail -c 65536 "$f"; else echo LOG_MISSING; fi'
            $log249 = "$logDir/alfa-train-7b-249.log"
            $bashLines += ('f249="{0}"' -f $log249)
            $bashLines += 'if [ -f "$f249" ]; then echo LOG249=OK; timeout -k 2 8 tail -c 65536 "$f249"; fi'
        } else {
            $bashLines += 'echo LOGDIR_MISSING'
        }
        $bashBody = ($bashLines -join "`n")
        $b64 = ConvertTo-AlfaGuiRemoteBase64 -BashBody $bashBody
        $remote = ('wsl -d Ubuntu -- bash -lc ''echo {0} | base64 -d | bash''' -f $b64)

        $sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
        if (-not (Test-Path -LiteralPath $sshExe)) {
            $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
            if ($null -eq $sshCmd) {
                $script:TrainProbeLastError = 'ssh.exe not found'
                return $null
            }
            $sshExe = $sshCmd.Source
        }

        # ProcessStartInfo.Arguments: quote the remote command (spaces)
        # https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.arguments
        # Do not use Start-Process -ArgumentList (extra quoting breaks ssh).
        # Read both streams with ReadToEndAsync tasks (no PowerShell scriptblock
        # callbacks). OutputDataReceived/ErrorDataReceived handlers run on thread-pool
        # threads with no runspace and terminate powershell.exe silently (exit 2).
        # https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.standardoutput
        # https://learn.microsoft.com/en-us/dotnet/api/system.io.streamreader.readtoendasync
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $sshExe
        $psi.Arguments = ('-o BatchMode=yes -o ConnectTimeout=8 -i "{0}" {1} "{2}"' -f $keyPath, $sshTarget, $remote)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $probeProc = New-Object System.Diagnostics.Process
        $probeProc.StartInfo = $psi
        [void]$probeProc.Start()
        $outTask = $probeProc.StandardOutput.ReadToEndAsync()
        $errTask = $probeProc.StandardError.ReadToEndAsync()
        $exited = $probeProc.WaitForExit(20000)
        if (-not $exited) {
            try { $probeProc.Kill() } catch { }
            try { [void]$probeProc.WaitForExit(2000) } catch { }
        }
        [void][System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 5000)
        $blob = ''
        $errText = ''
        if ($outTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $blob = $outTask.Result }
        if ($errTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $errText = $errTask.Result }
        $exitCode = -1
        try { $exitCode = $probeProc.ExitCode } catch { }
        try { $probeProc.Close() } catch { }

        if (-not [string]::IsNullOrWhiteSpace($errText)) {
            $trimErr = $errText.Trim()
            if ($trimErr.Length -gt 400) { $trimErr = $trimErr.Substring(0, 400) }
            $script:TrainProbeLastError = $trimErr
        } elseif (-not $exited) {
            $script:TrainProbeLastError = 'ssh probe exceeded 20s (killed)'
        }

        $script:TrainHubLogBlob = $blob
        $up = $false
        $down = $false
        $probeTimeout = $false
        if ($blob -match 'CONTAINER=UP') { $up = $true }
        if ($blob -match 'CONTAINER=DOWN') { $down = $true }
        if ($blob -match 'CONTAINER=PROBE_TIMEOUT') { $probeTimeout = $true }
        $script:TrainHubLogPhase = Get-AlfaTrainHubLogPhaseFromText -Text $blob
        if (-not ($up -or $down -or $probeTimeout)) {
            if ([string]::IsNullOrWhiteSpace($script:TrainProbeLastError)) {
                $script:TrainProbeLastError = ('ssh exit {0}, no CONTAINER= line, stdout {1} chars' -f $exitCode, $blob.Length)
            }
        }
        if ($up) { return $true }
        if ($down) { return $false }
        return $null
    } catch {
        $script:TrainHubLogBlob = $null
        $script:TrainProbeLastError = $_.Exception.Message
        return $null
    }
}

function Get-AlfaTrainContainerRunningCached {
    param([switch]$Force)
    $now = [datetime]::UtcNow
    if ($script:TrainProbeInFlight) {
        return $script:TrainContainerProbeResult
    }
    if (-not $Force) {
        if ($script:TrainContainerProbeAt -ne [datetime]::MinValue) {
            $ageSec = ($now - $script:TrainContainerProbeAt).TotalSeconds
            if ($ageSec -lt $script:TrainProbeCacheSec) {
                return $script:TrainContainerProbeResult
            }
        }
    }
    $script:TrainProbeInFlight = $true
    try {
        # Do not call Application.DoEvents here: it re-enters Click/Timer while SSH runs
        # https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.application.doevents
        $script:TrainContainerProbeResult = Invoke-AlfaTrainContainerProbe59
        $script:TrainContainerProbeAt = $now
        return $script:TrainContainerProbeResult
    } finally {
        $script:TrainProbeInFlight = $false
    }
}

function Reset-AlfaTrainContainerProbeCache {
    $script:TrainContainerProbeResult = $null
    $script:TrainHubLogPhase = $null
    $script:TrainHubLogBlob = $null
    $script:TrainProbeLastError = $null
    $script:TrainContainerProbeAt = [datetime]::MinValue
}

function Show-AlfaTrainHubLogTail {
    param([int]$MaxLines = 40)
    Append-AlfaGuiLog ''
    $blob = $script:TrainHubLogBlob
    if ([string]::IsNullOrWhiteSpace($blob)) {
        Append-AlfaGuiLog '== Refresh: no hub rank-0 log (probe failed, no lock LOGDIR, or LOG_MISSING) =='
        return
    }
    Append-AlfaGuiLog '== Refresh hub rank-0 log (tail) =='
    $nl = [char]10
    $parts = @($blob -split $nl)
    $lines = @()
    foreach ($p in $parts) {
        $lines += ([string]$p).TrimEnd([char]13)
    }
    $count = $lines.Count
    $start = 0
    if ($count -gt $MaxLines) {
        $start = $count - $MaxLines
    }
    for ($i = $start; $i -lt $count; $i++) {
        Append-AlfaGuiLog $lines[$i]
    }
}

function Invoke-AlfaGuiTrainRefresh {
    $lblStatus.Text = 'Refreshing train status...'
    Update-AlfaGuiTrainSshLights
    Reset-AlfaTrainContainerProbeCache
    [void](Get-AlfaTrainContainerRunningCached -Force)
    Update-AlfaTrainLockUi
    Show-AlfaTrainHubLogTail
    $logDirNow = Get-AlfaTrainLockLogDir
    $blobLen = 0
    if (-not [string]::IsNullOrEmpty($script:TrainHubLogBlob)) {
        $blobLen = $script:TrainHubLogBlob.Length
    }
    $logDirText = 'NONE'
    if ($logDirNow) { $logDirText = $logDirNow }
    Append-AlfaGuiLog ('== probe {0} LOGDIR={1} stdout={2} chars ==' -f $script:GuiMenuRev, $logDirText, $blobLen)
    if (-not [string]::IsNullOrWhiteSpace($script:TrainProbeLastError)) {
        Append-AlfaGuiLog ('== probe stderr == {0}' -f $script:TrainProbeLastError)
    }
    if (-not $script:LogExpanded) {
        Set-AlfaGuiLogExpanded -Expand $true
    }
    $lblStatus.Text = 'Ready'
}

function Update-AlfaTrainLockUi {
    param([switch]$SkipProbe)
    $locked = Test-AlfaTrainLockPresent
    $busy = Test-AlfaGuiTrainBusy
    $trainLaunching = $busy -and ($script:RunningTrainMode -eq 'start')
    # Lock means Start already wrote alfa-train.lock; probe hub log even if the
    # launcher process is still up. Sticky LAUNCHING skipped the probe (Refresh no-op).
    if ($trainLaunching -and (-not $locked)) {
        $stateText = 'LAUNCHING -- Start script still running. Wait for launcher exit, then Refresh Status.'
        $lblTrainHint.ForeColor = $ColorYellow
        $lblTrainHint.Text = $stateText
    } elseif ($locked) {
        if ($SkipProbe) {
            $stateText = 'TRAIN LOCK on -- trainer holds the lock. Click Refresh to probe status. inference core inference may still start from ALFa Models; Pool72/Pool80 are blocked while training.'
            $lblTrainHint.ForeColor = $ColorYellow
            $lblTrainHint.Text = $stateText
        } else {
            $containerUp = Get-AlfaTrainContainerRunningCached
            $phase = $script:TrainHubLogPhase
            if ($containerUp -eq $true -and $phase -eq 'failed') {
                $stateText = 'FAILED -- hub log has DistNetworkError/timeout/traceback. Click Stop trainer, then fix NFS/DNS/firewall before Start 7B.'
                $lblTrainHint.ForeColor = $ColorRed
            } elseif ($containerUp -eq $true -and $phase -eq 'finished') {
                $stateText = 'FINISHED -- hub log shows Training completed; waiting for --rm. Click Refresh, then Stop trainer to clear lock.'
                $lblTrainHint.ForeColor = $ColorGreen
            } elseif ($containerUp -eq $true -and $phase -eq 'training') {
                $stateText = 'TRAINING -- hub log shows loss / Total train batch. Curves = TensorBoard.'
                $lblTrainHint.ForeColor = $ColorGreen
            } elseif ($containerUp -eq $true) {
                $stateText = 'STARTING -- containers Up, no loss/Total train batch in hub log yet (load or first eval). Not green TRAINING.'
                $lblTrainHint.ForeColor = $ColorYellow
            } elseif ($containerUp -eq $false -and $phase -eq 'failed') {
                $stateText = 'FAILED -- container gone; hub log has an error. Click Stop trainer before retrain.'
                $lblTrainHint.ForeColor = $ColorRed
            } elseif ($containerUp -eq $false -and $phase -eq 'finished') {
                $stateText = 'FINISHED -- Training completed; containers gone (--rm). Click Stop trainer to clear lock. Adapter on hub v2.'
                $lblTrainHint.ForeColor = $ColorGreen
            } elseif ($containerUp -eq $false) {
                $stateText = 'JOB ENDED -- Containers gone (--rm) with no completion marker. Click Stop trainer to clear lock before retrain.'
                $lblTrainHint.ForeColor = $ColorYellow
            } else {
                $stateText = 'TRAIN LOCK on (could not probe gaming-c docker) -- job may still be running. Click Refresh; do not Stop trainer unless the job is finished. inference core inference may still start from ALFa Models; Pool72/Pool80 are blocked.'
                $lblTrainHint.ForeColor = $ColorRed
            }
            $lblTrainHint.Text = $stateText
        }
    } else {
        $lblTrainHint.ForeColor = $ColorMuted
        $stateText = 'IDLE -- trainer idle. Start 7B QLoRA when ready.'
        if ($null -ne $script:LastTrainExitCode -and $script:LastTrainExitCode -ne 0) {
            $stateText = ("Last Start 7B FAILED (exit {0}). See terminal. Trainer idle." -f $script:LastTrainExitCode)
            $lblTrainHint.ForeColor = $ColorRed
        }
        $lblTrainHint.Text = $stateText
    }
    Update-AlfaGuiJobButtons
    if (-not $locked) {
        $peerMsg = Get-AlfaDesktopJobPeerMessage -SelfKind train -RepoDir $RepoDir
        if (-not [string]::IsNullOrWhiteSpace($peerMsg)) {
            $lblTrainHint.Text = $peerMsg
            $lblTrainHint.ForeColor = $ColorYellow
        }
    }
}

function Set-AlfaGuiLogExpanded {
    param([bool]$Expand)
    $script:LogExpanded = $Expand
    $panelLog.Visible = $Expand
    $w = $form.ClientSize.Width
    if ($Expand) {
        $btnToggleLog.Text = 'Hide terminal'
        $form.ClientSize = New-Object System.Drawing.Size($w, $script:FormHeightExpanded)
    } else {
        $btnToggleLog.Text = 'Show terminal'
        $form.ClientSize = New-Object System.Drawing.Size($w, $script:FormHeightCollapsed)
    }
}

function Stop-AlfaGuiProcess {
    if ($null -eq $script:TrainProc) { return }
    try {
        if (-not $script:TrainProc.HasExited) {
            $script:TrainProc.Kill()
        }
    } catch {
    }
    $script:TrainProc = $null
}

function Test-AlfaGuiTcpOk {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 800
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close() } catch { }
        }
    }
}

function Set-AlfaGuiBadge {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][ValidateSet('gray', 'green', 'red', 'yellow')][string]$State
    )
    if (-not $script:StatusLights.ContainsKey($Key)) { return }
    $badge = $script:StatusLights[$Key].Badge
    switch ($State) {
        'green' {
            $badge.Text = 'UP'
            $badge.ForeColor = $ColorGreen
            $badge.BackColor = $ColorGreenBg
        }
        'red' {
            $badge.Text = 'DN'
            $badge.ForeColor = $ColorRed
            $badge.BackColor = $ColorRedBg
        }
        'yellow' {
            $badge.Text = '..'
            $badge.ForeColor = $ColorYellow
            $badge.BackColor = $ColorYellowBg
        }
        default {
            $badge.Text = '--'
            $badge.ForeColor = $ColorGray
            $badge.BackColor = $ColorGrayBg
        }
    }
}

function Add-AlfaGuiBadge {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Parent,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [string]$Caption = ''
    )
    $badge = New-Object System.Windows.Forms.Label
    $badge.Location = New-Object System.Drawing.Point($X, ($Y + 1))
    $badge.Size = New-Object System.Drawing.Size(28, 16)
    $badge.Text = '--'
    $badge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $badge.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
    $badge.ForeColor = $ColorGray
    $badge.BackColor = $ColorGrayBg
    $badge.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Parent.Controls.Add($badge)

    $capW = 0
    if (-not [string]::IsNullOrEmpty($Caption)) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Location = New-Object System.Drawing.Point(($X + 30), $Y)
        $lbl.Size = New-Object System.Drawing.Size(58, 18)
        $lbl.Text = $Caption
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(70, 78, 88)
        $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $Parent.Controls.Add($lbl)
        $capW = 60
        $script:StatusLights[$Key] = @{ Badge = $badge; Label = $lbl }
    } else {
        $script:StatusLights[$Key] = @{ Badge = $badge; Label = $null }
    }
    return (28 + 2 + $capW)
}

function Add-AlfaGuiHostRow {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Parent,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][string]$HostText,
        [Parameter(Mandatory)][string]$SshKey,
        [object[]]$IoItems = @(),
        [bool]$AltRow = $false
    )
    if ($AltRow) {
        $rowBg = New-Object System.Windows.Forms.Panel
        $rowBg.Location = New-Object System.Drawing.Point(4, ($Y - 1))
        $rowBg.Size = New-Object System.Drawing.Size(($Parent.Width - 20), 20)
        $rowBg.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
        $Parent.Controls.Add($rowBg)
        $rowBg.SendToBack()
    }

    $lblHost = New-Object System.Windows.Forms.Label
    $lblHost.Location = New-Object System.Drawing.Point(12, $Y)
    $lblHost.Size = New-Object System.Drawing.Size(200, 18)
    $lblHost.Text = $HostText
    $lblHost.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $Parent.Controls.Add($lblHost)

    if ($SshKey -eq '-') {
        # no SSH cell
    } else {
        [void](Add-AlfaGuiBadge -Parent $Parent -Key $SshKey -X 220 -Y $Y)
    }

    $x = 270
    if ($null -eq $IoItems) { $IoItems = @() }
    foreach ($item in $IoItems) {
        $w = Add-AlfaGuiBadge -Parent $Parent -Key $item.Key -X $x -Y $Y -Caption $item.Caption
        $x += [int]$w
    }
}

function Set-AlfaGuiProbeResult {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][bool]$Ok
    )
    if ($Ok) {
        Set-AlfaGuiBadge -Key $Key -State 'green'
    } else {
        Set-AlfaGuiBadge -Key $Key -State 'red'
    }
}

function Update-AlfaGuiJobIoLight {
    $busy = Test-AlfaGuiTrainBusy
    if (-not $busy) {
        Set-AlfaGuiBadge -Key 'jobio' -State 'gray'
        return
    }
    if ([datetime]::UtcNow -lt $script:JobIoUntil) {
        Set-AlfaGuiBadge -Key 'jobio' -State 'green'
    } else {
        Set-AlfaGuiBadge -Key 'jobio' -State 'yellow'
    }
}

function Update-AlfaGuiTrainSshLights {
    # TCP :22 only -- not shard RPC ports (rpc-server is single-client).
    $tcpMs = 700
    Set-AlfaGuiBadge -Key 'tssh59' -State 'yellow'
    Set-AlfaGuiProbeResult -Key 'tssh59' -Ok (Test-AlfaGuiTcpOk -HostName $Ip59 -Port 22 -TimeoutMs $tcpMs)
    Set-AlfaGuiBadge -Key 'tssh249' -State 'yellow'
    Set-AlfaGuiProbeResult -Key 'tssh249' -Ok (Test-AlfaGuiTcpOk -HostName $Ip249 -Port 22 -TimeoutMs $tcpMs)
}

function New-AlfaGuiFlatButton {
    param(
        [string]$Text,
        [System.Drawing.Color]$Back,
        [System.Drawing.Color]$Fore
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function Start-AlfaGuiTrainer {
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'stop')][string]$Mode
    )
    if ((Test-AlfaGuiTrainBusy) -and ($Mode -ne 'stop')) {
        [System.Windows.Forms.MessageBox]::Show(
            'A trainer job is already running. Wait for it to finish, or click Stop trainer.',
            'ALFa Trainer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    if ($Mode -eq 'start') {
        $peerMsg = Get-AlfaDesktopJobPeerMessage -SelfKind train -RepoDir $RepoDir
        if (-not [string]::IsNullOrWhiteSpace($peerMsg)) {
            [System.Windows.Forms.MessageBox]::Show(
                $peerMsg,
                'ALFa Trainer',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
    }
    if ($Mode -eq 'start') {
        if (Test-AlfaTrainLockPresent) {
            [System.Windows.Forms.MessageBox]::Show(
                'Trainer lock already set. Run Stop trainer first.',
                'ALFa Trainer',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        # Axolotl 7-8B QLoRA ~10-14 GB per replica (SFT table):
        # https://docs.axolotl.ai/docs/choosing_method.html
        # DDP is default when DeepSpeed/FSDP omitted:
        # https://docs.axolotl.ai/docs/multi-gpu.html
        # Single-GPU: remove deepspeed; --launcher python:
        # https://docs.axolotl.ai/docs/faq.html
        # https://docs.axolotl.ai/docs/cli.html
        if ($chkInclude219.Checked -and $chkSingle59.Checked) {
            [System.Windows.Forms.MessageBox]::Show(
                'Include gaming-a and gaming-c only cannot both be checked.',
                'ALFa Trainer',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        $modeLine = '2-node DDP on gaming-c + gaming-b'
        if ($chkInclude219.Checked) { $modeLine = '3-node DDP on gaming-c + gaming-b + gaming-a' }
        if ($chkSingle59.Checked) { $modeLine = 'gaming-c only (no DDP rendezvous)' }
        $adapterLine = 'Continues existing pool-7b-qlora-v2 when present (Axolotl lora_model_dir). Never continues v1.'
        if ($chkFresh.Checked) { $adapterLine = 'Fresh adapter: omits lora_model_dir (new LoRA from zeros).' }
        $confirmMsg = "Start 7B QLoRA ($modeLine)?`n`nEach replica loads the full 4-bit model. Axolotl choosing method: 7-8B QLoRA is 10-14 GB per replica.`n`n$adapterLine`n`nDoes NOT stop core 27B.`nFails if those GPUs still run rpc-server.`nLocks train GPUs; Pool72/Pool80 in ALFa Models stay blocked until Stop trainer."
        $r = [System.Windows.Forms.MessageBox]::Show(
            $confirmMsg,
            'Confirm train start',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $scriptPath = $TrainStartScript
    } else {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'Stop 7B QLoRA trainer and clear Blackwell lock?',
            'Confirm train stop',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $scriptPath = $TrainStopScript
    }
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Script missing:`n$scriptPath",
            'ALFa Trainer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    $argLine = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
    if ($Mode -eq 'start') {
        if ($chkInclude219.Checked) { $argLine = $argLine + ' -Include219' }
        if ($chkSingle59.Checked) { $argLine = $argLine + ' -SingleHost59' }
        if ($chkFresh.Checked) { $argLine = $argLine + ' -FreshAdapter' }
    }
    Clear-AlfaGuiLogIfIdle
    Append-AlfaGuiLog ("== train {0} {1} ==" -f $Mode, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Append-AlfaGuiLog ("powershell.exe {0}" -f $argLine)
    Append-AlfaGuiLog ''

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellExe
    $psi.Arguments = $argLine
    $psi.WorkingDirectory = $RepoDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true
    $proc.SynchronizingObject = $form

    $proc.add_OutputDataReceived({
        param($sender, $e)
        if ($null -ne $e.Data) { Append-AlfaGuiLog $e.Data }
    })
    $proc.add_ErrorDataReceived({
        param($sender, $e)
        if ($null -ne $e.Data) { Append-AlfaGuiLog $e.Data }
    })
    $proc.add_Exited({
        param($sender, $e)
        $code = -1
        try { $code = $sender.ExitCode } catch { }
        Append-AlfaGuiLog ''
        Append-AlfaGuiLog ("== launcher finished exit={0} ==" -f $code)
        $script:TrainProc = $null
        $script:RunningTrainMode = $null
        Update-AlfaGuiJobButtons
        Update-AlfaGuiJobIoAfterExit
        Reset-AlfaTrainContainerProbeCache
        $script:LastTrainExitCode = $code
        if (Test-AlfaTrainLockPresent) {
            [void](Get-AlfaTrainContainerRunningCached -Force)
        }
        Update-AlfaTrainLockUi
        if ($code -eq 0) {
            if ((Test-AlfaTrainLockPresent) -and ($script:TrainHubLogPhase -ne 'training')) {
                $lblStatus.Text = 'Launcher finished (see Status)'
            } else {
                $lblStatus.Text = 'Train job: OK'
            }
        } else {
            $lblStatus.Text = ("Train job: FAIL (exit {0})" -f $code)
        }
    })

    $script:RunningTrainMode = $Mode
    Reset-AlfaTrainContainerProbeCache
    $lblStatus.Text = ("Running train {0}..." -f $Mode)
    if (-not $script:LogExpanded) {
        Set-AlfaGuiLogExpanded -Expand $true
    }

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $script:TrainProc = $proc
    Update-AlfaGuiJobButtons
    if ($Mode -eq 'start') {
        Update-AlfaTrainLockUi
    }
}

# --- UI ---
try {
$Margin = 16
$ContentW = 420
$LeftX = $Margin
$RowH = 22
$HeaderH = 64
$BtnW = [int]($ContentW / 2) - 4

$form = New-Object System.Windows.Forms.Form
$form.Text = ('ALFa Trainer 7B {0}' -f $script:GuiMenuRev)
$form.ClientSize = New-Object System.Drawing.Size(($Margin * 2 + $ContentW), $script:FormHeightCollapsed)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = $ColorFormBg
$form.Add_FormClosing({
    if (Test-AlfaGuiTrainBusy) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'A train job is still running.`n`nYes = kill the job and close.`nNo = close GUI and leave the job running.`nCancel = stay open.',
            'ALFa Trainer',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) {
            $_.Cancel = $true
            return
        }
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:KillGuiJobsOnExit = $true
            Stop-AlfaGuiProcess
        }
        # No: close without Kill; docker containers stay up; powershell.exe child keeps running.
    }
    $timer.Stop()
    $timerIo.Stop()
})

$panelHeader = New-Object System.Windows.Forms.Panel
$panelHeader.Location = New-Object System.Drawing.Point(0, 0)
$panelHeader.Size = New-Object System.Drawing.Size(($form.ClientSize.Width), $HeaderH)
$panelHeader.BackColor = $ColorHeader
$form.Controls.Add($panelHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point($LeftX, 10)
$lblTitle.Size = New-Object System.Drawing.Size($ContentW, 22)
$lblTitle.Text = '7B QLoRA Trainer'
$lblTitle.ForeColor = $ColorHeaderText
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.BackColor = $ColorHeader
$panelHeader.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Location = New-Object System.Drawing.Point($LeftX, 34)
$lblSubtitle.Size = New-Object System.Drawing.Size($ContentW, 18)
$lblSubtitle.Text = ('Train island gaming-c / gaming-b DDP QLoRA (menu {0})' -f $script:GuiMenuRev)
$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 200)
$lblSubtitle.BackColor = $ColorHeader
$panelHeader.Controls.Add($lblSubtitle)

$contentY = $HeaderH + 12
$contentH = 500

$panelTrain = New-Object System.Windows.Forms.Panel
$panelTrain.Location = New-Object System.Drawing.Point($LeftX, $contentY)
$panelTrain.Size = New-Object System.Drawing.Size($ContentW, $contentH)
$panelTrain.BackColor = $ColorFormBg
$form.Controls.Add($panelTrain)

$panelTrainBanner = New-Object System.Windows.Forms.Panel
$panelTrainBanner.Location = New-Object System.Drawing.Point(0, 0)
$panelTrainBanner.Size = New-Object System.Drawing.Size($ContentW, 88)
$panelTrainBanner.BackColor = $ColorPanel
$panelTrainBanner.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$panelTrain.Controls.Add($panelTrainBanner)

$lblTrainPageTitle = New-Object System.Windows.Forms.Label
$lblTrainPageTitle.Location = New-Object System.Drawing.Point(16, 10)
$lblTrainPageTitle.Size = New-Object System.Drawing.Size(($ContentW - 32), 20)
$lblTrainPageTitle.Text = 'Status'
$lblTrainPageTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblTrainPageTitle.ForeColor = [System.Drawing.Color]::FromArgb(28, 40, 56)
$panelTrainBanner.Controls.Add($lblTrainPageTitle)

$lblTrainHint = New-Object System.Windows.Forms.Label
$lblTrainHint.Location = New-Object System.Drawing.Point(16, 34)
$lblTrainHint.Size = New-Object System.Drawing.Size(($ContentW - 32), 44)
$lblTrainHint.ForeColor = $ColorMuted
$lblTrainHint.Text = 'IDLE until lock file exists (Refresh updates STARTING / TRAINING / FAILED / FINISHED / JOB ENDED).'
$panelTrainBanner.Controls.Add($lblTrainHint)

$grpTrainHosts = New-Object System.Windows.Forms.GroupBox
$grpTrainHosts.Location = New-Object System.Drawing.Point(0, 104)
$grpTrainHosts.Size = New-Object System.Drawing.Size($ContentW, 132)
$grpTrainHosts.Text = '  Train island (gaming-c + gaming-b)  '
$grpTrainHosts.BackColor = $ColorPanel
$panelTrain.Controls.Add($grpTrainHosts)

$lblTrainHostsHdr = New-Object System.Windows.Forms.Label
$lblTrainHostsHdr.Location = New-Object System.Drawing.Point(16, 22)
$lblTrainHostsHdr.Size = New-Object System.Drawing.Size(400, 18)
$lblTrainHostsHdr.Text = 'SSH reachability (not inference ports)'
$lblTrainHostsHdr.ForeColor = $ColorMuted
$grpTrainHosts.Controls.Add($lblTrainHostsHdr)

$ty = 44
Add-AlfaGuiHostRow -Parent $grpTrainHosts -Y $ty -HostText 'gaming-c gaming-worker-c (5070, rdzv)' -SshKey 'tssh59' -IoItems @()
$ty += $RowH
Add-AlfaGuiHostRow -Parent $grpTrainHosts -Y $ty -HostText 'gaming-b gaming-worker-b (5070)' -SshKey 'tssh249' -IoItems @()
$ty += $RowH + 4
Add-AlfaGuiHostRow -Parent $grpTrainHosts -Y $ty -HostText 'Job I/O (log)' -SshKey '-' -IoItems @(
    @{ Key = 'jobio'; Caption = 'stream' }
)

$grpRunSettings = New-Object System.Windows.Forms.GroupBox
$grpRunSettings.Location = New-Object System.Drawing.Point(0, 244)
$grpRunSettings.Size = New-Object System.Drawing.Size($ContentW, 104)
$grpRunSettings.Text = '  Run settings (change before Start)  '
$grpRunSettings.BackColor = $ColorPanel
$panelTrain.Controls.Add($grpRunSettings)

$chkInclude219 = New-Object System.Windows.Forms.CheckBox
$chkInclude219.Location = New-Object System.Drawing.Point(16, 22)
$chkInclude219.Size = New-Object System.Drawing.Size(($ContentW - 32), 22)
$chkInclude219.Text = 'Include gaming-a (3-node)'
$chkInclude219.Checked = $false
$grpRunSettings.Controls.Add($chkInclude219)

$chkSingle59 = New-Object System.Windows.Forms.CheckBox
$chkSingle59.Location = New-Object System.Drawing.Point(16, 46)
$chkSingle59.Size = New-Object System.Drawing.Size(($ContentW - 32), 22)
$chkSingle59.Text = 'gaming-c only'
$chkSingle59.Checked = $false
$grpRunSettings.Controls.Add($chkSingle59)

$chkFresh = New-Object System.Windows.Forms.CheckBox
$chkFresh.Location = New-Object System.Drawing.Point(16, 70)
$chkFresh.Size = New-Object System.Drawing.Size(($ContentW - 32), 22)
$chkFresh.Text = 'Fresh adapter (do not continue v2)'
$chkFresh.Checked = $false
$grpRunSettings.Controls.Add($chkFresh)

$btnTrainStart = New-AlfaGuiFlatButton -Text 'Start 7B QLoRA' -Back ([System.Drawing.Color]::FromArgb(90, 70, 140)) -Fore ([System.Drawing.Color]::White)
$btnTrainStart.Location = New-Object System.Drawing.Point(0, 352)
$btnTrainStart.Size = New-Object System.Drawing.Size($BtnW, 40)
$btnTrainStart.Add_Click({ Start-AlfaGuiTrainer -Mode 'start' })
$panelTrain.Controls.Add($btnTrainStart)

$btnTrainStop = New-AlfaGuiFlatButton -Text 'Stop trainer' -Back $ColorBtnStop -Fore ([System.Drawing.Color]::White)
$btnTrainStop.Location = New-Object System.Drawing.Point(($BtnW + 8), 352)
$btnTrainStop.Size = New-Object System.Drawing.Size($BtnW, 40)
$btnTrainStop.Add_Click({ Start-AlfaGuiTrainer -Mode 'stop' })
$panelTrain.Controls.Add($btnTrainStop)

$btnTrainTensorBoard = New-AlfaGuiFlatButton -Text 'Open TensorBoard' -Back $ColorBtnFlat -Fore ([System.Drawing.Color]::FromArgb(40, 50, 60))
$btnTrainTensorBoard.Location = New-Object System.Drawing.Point(0, 400)
$btnTrainTensorBoard.Size = New-Object System.Drawing.Size($ContentW, 36)
$btnTrainTensorBoard.FlatAppearance.BorderSize = 1
$btnTrainTensorBoard.FlatAppearance.BorderColor = $ColorBorder
$btnTrainTensorBoard.Add_Click({
    if (-not (Test-Path -LiteralPath $TrainTensorBoardScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            ("Missing script: {0}" -f $TrainTensorBoardScript),
            'ALFa Trainer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    $lblStatus.Text = 'Starting TensorBoard...'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellExe
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -SkipIfHealthy' -f $TrainTensorBoardScript)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) {
            $lblStatus.Text = ("TensorBoard failed (exit {0}). If NFS missing on gaming-c, remount /mnt/cluster then retry." -f $p.ExitCode)
        } else {
            $lblStatus.Text = 'TensorBoard: http://127.0.0.1:6006/ (gear: Reload data)'
        }
    } catch {
        $lblStatus.Text = 'TensorBoard start failed.'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ALFa Trainer', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})
$panelTrain.Controls.Add($btnTrainTensorBoard)

$lblTrainFoot = New-Object System.Windows.Forms.Label
$lblTrainFoot.Location = New-Object System.Drawing.Point(0, 444)
$lblTrainFoot.Size = New-Object System.Drawing.Size($ContentW, 48)
$lblTrainFoot.ForeColor = $ColorMuted
$lblTrainFoot.Text = 'Does not stop core 27B. Leave every checkbox off for 2-node DDP that continues pool-7b-qlora-v2. Include gaming-a and gaming-c only cannot both be on. Fails if those GPUs still run rpc-server. Inference: models-desktop-menu.ps1. TensorBoard: http://127.0.0.1:6006/.'
$panelTrain.Controls.Add($lblTrainFoot)

$footerY = $contentY + $contentH + 12
$btnToggleLog = New-AlfaGuiFlatButton -Text 'Show terminal' -Back $ColorBtnFlat -Fore ([System.Drawing.Color]::FromArgb(40, 50, 60))
$btnToggleLog.Location = New-Object System.Drawing.Point($LeftX, $footerY)
$btnToggleLog.Size = New-Object System.Drawing.Size(130, 28)
$btnToggleLog.FlatAppearance.BorderSize = 1
$btnToggleLog.FlatAppearance.BorderColor = $ColorBorder
$btnToggleLog.Add_Click({
    Set-AlfaGuiLogExpanded -Expand (-not $script:LogExpanded)
})
$form.Controls.Add($btnToggleLog)

$btnRefresh = New-AlfaGuiFlatButton -Text 'Refresh' -Back $ColorBtnFlat -Fore ([System.Drawing.Color]::FromArgb(40, 50, 60))
$btnRefresh.Location = New-Object System.Drawing.Point(($LeftX + 138), $footerY)
$btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$btnRefresh.FlatAppearance.BorderSize = 1
$btnRefresh.FlatAppearance.BorderColor = $ColorBorder
$btnRefresh.Add_Click({
    Invoke-AlfaGuiTrainRefresh
})
$form.Controls.Add($btnRefresh)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(($LeftX + 236), ($footerY + 4))
$lblStatus.Size = New-Object System.Drawing.Size(($ContentW - 236), 22)
$lblStatus.Text = 'Ready'
$lblStatus.ForeColor = $ColorMuted
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$form.Controls.Add($lblStatus)

$panelLog = New-Object System.Windows.Forms.Panel
$panelLog.Location = New-Object System.Drawing.Point($LeftX, ($footerY + 38))
$panelLog.Size = New-Object System.Drawing.Size($ContentW, $script:LogPanelHeight)
$panelLog.Visible = $false
$panelLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($panelLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Both'
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Dock = 'Fill'
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 34)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(210, 218, 226)
$panelLog.Controls.Add($txtLog)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 12000
$timer.Add_Tick({
    # WinForms Timer Tick runs on the UI thread
    # https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.timer
    Update-AlfaTrainLockUi
})

$timerIo = New-Object System.Windows.Forms.Timer
$timerIo.Interval = 400
$timerIo.Add_Tick({ Update-AlfaGuiJobIoLight })

Set-AlfaGuiLogExpanded -Expand $false
$timer.Start()
$timerIo.Start()
$form.Add_Shown({
    Update-AlfaGuiTrainSshLights
    Update-AlfaTrainLockUi -SkipProbe
    $lblStatus.Text = 'Ready'
    if (Test-Path -LiteralPath $TrainTensorBoardScript) {
        $tbPsi = New-Object System.Diagnostics.ProcessStartInfo
        $tbPsi.FileName = $PowerShellExe
        $tbPsi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoBrowser -SkipIfHealthy' -f $TrainTensorBoardScript)
        $tbPsi.UseShellExecute = $false
        $tbPsi.CreateNoWindow = $true
        try {
            [void][System.Diagnostics.Process]::Start($tbPsi)
        }
        catch {
            # Sidecar start is best-effort; Open TensorBoard retries manually.
        }
    }
})

[void]$form.ShowDialog()
$timer.Stop()
$timerIo.Stop()
if ($script:KillGuiJobsOnExit) {
    Stop-AlfaGuiProcess
}
} catch {
    $err = $_.Exception.Message
    [void][System.Windows.Forms.MessageBox]::Show(
        ("GUI failed to open:`n`n{0}" -f $err),
        'ALFa Trainer',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    throw
}
