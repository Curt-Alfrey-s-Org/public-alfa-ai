#Requires -Version 5.1
<#
.SYNOPSIS
  Desktop control panel for inference models (Run models only).

.DESCRIPTION
  WinForms UI wrapping Start-Stop-AlfaAi.ps1 for inference:
  - Pool radio: inference / Pool72 / Pool80
  - Opt-in hosts checkboxes (gaming-a/gaming-c/gaming-b/secondary/pool-opt-in)
  - Inference host matrix with status lights (SSH + network I/O)
  - Start / Stop cluster via Start-Stop-AlfaAi.ps1
  - inference metrics button opens Grafana tok/s + per-host GPU dashboard
  - Show terminal toggle for orchestrator log stream
  The 7B QLoRA trainer has its own GUI: train-desktop-menu.ps1
  (see docs/operations/TRAIN_7B_QLORA_GUI.md).
  Official Panel: https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.panel
  Official Process.SynchronizingObject: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.synchronizingobject
  Docs: docs/CLUSTER_START_STOP_OPERATOR.md
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Orchestrator = Join-Path $PSScriptRoot 'Start-Stop-AlfaAi.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$LlcDir = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$SelectionPath = Join-Path $LlcDir 'inference-gaming-selection.env'
$GuiPrefsPath = Join-Path $LlcDir 'inference-desktop-gui.env'
$TrainLockPath = Join-Path $LlcDir 'alfa-train.lock'
$SevenBServeLockPath = Join-Path $LlcDir 'alfa-7b-serve.lock'
$jobLockHelper = Join-Path $PSScriptRoot 'AlfaDesktopJobLock.ps1'
. $jobLockHelper

$Ip59 = 'orchestrator'
$Ip93 = 'orchestrator'
$Ip100 = 'orchestrator'
$Ip110 = 'orchestrator'
$Ip111 = 'hub'
$Ip148 = 'orchestrator'
$Ip219 = 'orchestrator'
$Ip248 = 'orchestrator'
$Ip249 = 'orchestrator'

$script:ClusterProc = $null
$script:LogExpanded = $false
$script:FormHeightCollapsed = 910
$script:FormHeightExpanded = 1150
$script:LogPanelHeight = 220
$script:StatusLights = @{}
$script:Polling = $false
$script:KillGuiJobsOnExit = $false
$script:GuiMenuRev = 'r4'
$script:JobIoUntil = [datetime]::MinValue
$btnStart = $null
$btnStop = $null
$grpModel = $null
$grpHosts = $null

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
$ColorBtnStart = [System.Drawing.Color]::FromArgb(40, 110, 170)
$ColorBtnFlat = [System.Drawing.Color]::FromArgb(248, 249, 251)

function Read-AlfaGuiPrefs {
    $prefs = @{
        InferenceMode = 'inference'
        Include59     = $false
        Include219    = $false
        Include249    = $false
        Include248    = $false
        Include100    = $false
        CtxSize       = 0
        ParallelSlots = 0
    }
    if (Test-Path -LiteralPath $SelectionPath) {
        foreach ($line in Get-Content -LiteralPath $SelectionPath) {
            $trim = ($line -replace '#.*$', '').Trim()
            if ($trim -match '^INCLUDE_59=(1|true|yes)$') { $prefs.Include59 = $true }
            if ($trim -match '^INCLUDE_219=(1|true|yes)$') { $prefs.Include219 = $true }
            if ($trim -match '^INCLUDE_249=(1|true|yes)$') { $prefs.Include249 = $true }
            if ($trim -match '^INCLUDE_248=(1|true|yes)$') { $prefs.Include248 = $true }
            if ($trim -match '^INCLUDE_100=(1|true|yes)$') { $prefs.Include100 = $true }
        }
    }
    if (Test-Path -LiteralPath $GuiPrefsPath) {
        foreach ($line in Get-Content -LiteralPath $GuiPrefsPath) {
            $trim = ($line -replace '#.*$', '').Trim()
            if ($trim -match '^CTX_SIZE=([0-9]+)$') { $prefs.CtxSize = [int]$Matches[1] }
            if ($trim -match '^PARALLEL=([0-9]+)$') { $prefs.ParallelSlots = [int]$Matches[1] }
            if ($trim -match '^INFERENCE_MODE=(inference|inference_38|Pool72|Pool80)$') {
                if ($Matches[1] -eq 'inference_38') {
                    $prefs.InferenceMode = 'inference'
                } else {
                    $prefs.InferenceMode = $Matches[1]
                }
            }
        }
    }
    return $prefs
}

function Test-AlfaGuiProcAlive {
    param($Proc)
    if ($null -eq $Proc) { return $false }
    try {
        return (-not $Proc.HasExited)
    } catch {
        return $false
    }
}

function Test-AlfaGuiClusterBusy {
    return (Test-AlfaGuiProcAlive $script:ClusterProc)
}

function Update-AlfaGuiJobButtons {
    # Official Process events marshal via SynchronizingObject on the Form:
    # https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.synchronizingobject
    if ($null -eq $btnStart) { return }
    $clusterBusy = Test-AlfaGuiClusterBusy
    $peerMsg = Get-AlfaDesktopJobPeerMessage -SelfKind cluster -RepoDir $RepoDir
    $peerBusy = -not [string]::IsNullOrWhiteSpace($peerMsg)

    $btnStart.Enabled = (-not $clusterBusy) -and (-not $peerBusy)
    $btnStop.Enabled = (-not $clusterBusy) -and (-not $peerBusy)
    $grpModel.Enabled = -not $clusterBusy
    $grpHosts.Enabled = -not $clusterBusy

    Update-AlfaGuiTrainLockState
    if ($peerBusy -and (-not $clusterBusy)) {
        $lblStatus.Text = $peerMsg
        $lblStatus.ForeColor = $ColorYellow
    }
}

function Clear-AlfaGuiLog {
    $txtLog.Clear()
}

function Update-AlfaGuiJobIoAfterExit {
    if (Test-AlfaGuiClusterBusy) {
        return
    }
    Set-AlfaGuiBadge -Key 'jobio' -State 'gray'
}

function Save-AlfaGuiPrefs {
    param(
        [Parameter(Mandatory)][string]$InferenceMode,
        [int]$CtxSize = 0,
        [int]$ParallelSlots = 0
    )
    $dir = Split-Path -Parent $GuiPrefsPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    @(
        '# ALFa desktop GUI prefs (gitignored runtime; local to orchestrator)'
        ("INFERENCE_MODE={0}" -f $InferenceMode)
        ("CTX_SIZE={0}" -f $CtxSize)
        ("PARALLEL={0}" -f $ParallelSlots)
    ) | Set-Content -LiteralPath $GuiPrefsPath -Encoding ASCII
}

function Get-AlfaGuiPoolRunDefaults {
    param([Parameter(Mandatory)][string]$InferenceMode)
    if ($InferenceMode -eq 'Pool72' -or $InferenceMode -eq 'Pool80') {
        return [pscustomobject]@{ Ctx = 86016; Parallel = 1 }
    }
    return [pscustomobject]@{ Ctx = 262144; Parallel = 5 }
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

function Test-Alfa7bServeLockPresent {
    return (Test-Path -LiteralPath $SevenBServeLockPath)
}

function Test-AlfaTrainLockIncludes219 {
    if (-not (Test-Path -LiteralPath $TrainLockPath)) {
        return $false
    }
    foreach ($line in @(Get-Content -LiteralPath $TrainLockPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^INCLUDE_219=1$') {
            return $true
        }
    }
    return $false
}

function Update-AlfaGuiinferenceExclusiveHosts {
    $locked = Test-AlfaTrainLockPresent
    $serveLocked = Test-Alfa7bServeLockPresent
    $busy = Test-AlfaGuiClusterBusy
    $inference = $rbinference.Checked

    if ($serveLocked) {
        $chk59.Checked = $false
        if (-not $busy) {
            $chk59.Enabled = $false
        }
        if ($inference) {
            $lblModelHint.Text = '7B serve lock: gaming-c blocked (standalone llama-server :8470). Other opt-in hosts OK.'
        }
    }

    if ($locked) {
        $chk59.Checked = $false
        $chk249.Checked = $false
        $chk59.Enabled = $false
        $chk249.Enabled = $false
        if (Test-AlfaTrainLockIncludes219) {
            $chk219.Checked = $false
            $chk219.Enabled = $false
        } elseif (-not $busy) {
            $chk219.Enabled = $true
        }
        if (-not $busy) {
            $chk248.Enabled = $true
            $chk100.Enabled = $true
        }
        if ($inference) {
            $lblModelHint.Text = 'Train lock: gaming-c/gaming-b blocked. inference opt-in: gaming-a/secondary/pool-opt-in still allowed.'
        }
        return
    }

    if ($serveLocked) {
        return
    }

    if (-not $busy) {
        $chk59.Enabled = $true
        $chk249.Enabled = $true
        $chk219.Enabled = $true
        $chk248.Enabled = $true
        $chk100.Enabled = $true
    }
    if ($inference) {
        $lblModelHint.Text = 'inference opt-in: gaming-a/gaming-c/gaming-b/secondary/pool-opt-in (never required for core green).'
    } elseif ($rbPool80.Checked) {
        $lblModelHint.Text = 'Pool80 prefers full-mesh: check all opt-in hosts.'
    } elseif ($rbPool72.Checked) {
        $lblModelHint.Text = 'Pool72 prefers full-mesh: check all opt-in hosts.'
    } else {
        $lblModelHint.Text = 'inference loads Qwen3.8-27B Q8 by default. Pool72/80: check all opt-in hosts.'
    }
}

function Update-AlfaGuiTrainLockState {
    $locked = Test-AlfaTrainLockPresent
    $clusterBusy = Test-AlfaGuiClusterBusy

    if ($locked) {
        $rbPool72.Enabled = $false
        $rbPool80.Enabled = $false
        if ($rbPool72.Checked -or $rbPool80.Checked) {
            $rbinference.Checked = $true
            Save-AlfaGuiPrefs -InferenceMode 'inference'
        }
        $lockHosts = 'gaming-c/gaming-b'
        if (Test-AlfaTrainLockIncludes219) {
            $lockHosts = 'gaming-c/gaming-b/gaming-a'
        }
        if (-not $clusterBusy) {
            $lblStatus.Text = ("Train lock on: 7B running on {0} -- inference core start allowed; Pool72/Pool80 blocked" -f $lockHosts)
            $lblStatus.ForeColor = $ColorYellow
        }
    } else {
        if (-not $clusterBusy) {
            $rbinference.Enabled = $true
            $rbPool72.Enabled = $true
            $rbPool80.Enabled = $true
            if ($lblStatus.Text -like 'Train lock on:*') {
                $lblStatus.Text = 'Ready'
                $lblStatus.ForeColor = $ColorMuted
            }
        }
    }
    Update-AlfaGuiinferenceExclusiveHosts
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
    if ($null -eq $script:ClusterProc) { return }
    try {
        if (-not $script:ClusterProc.HasExited) {
            $script:ClusterProc.Kill()
        }
    } catch {
    }
    $script:ClusterProc = $null
}

function Test-AlfaGuiHttpOk {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutMs = 1500
    )
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        try {
            $code = [int]$resp.StatusCode
            return ($code -ge 200 -and $code -lt 300)
        } finally {
            $resp.Close()
        }
    } catch {
        return $false
    }
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
    $lblHost.Size = New-Object System.Drawing.Size(140, 18)
    $lblHost.Text = $HostText
    $lblHost.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $Parent.Controls.Add($lblHost)

    if ($SshKey -eq 'local') {
        $lblNa = New-Object System.Windows.Forms.Label
        $lblNa.Location = New-Object System.Drawing.Point(156, $Y)
        $lblNa.Size = New-Object System.Drawing.Size(40, 18)
        $lblNa.Text = 'local'
        $lblNa.ForeColor = $ColorMuted
        $Parent.Controls.Add($lblNa)
    } elseif ($SshKey -eq '-') {
        # no SSH cell
    } else {
        [void](Add-AlfaGuiBadge -Parent $Parent -Key $SshKey -X 160 -Y $Y)
    }

    $x = 210
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
    if (-not (Test-AlfaGuiClusterBusy)) {
        Set-AlfaGuiBadge -Key 'jobio' -State 'gray'
        return
    }
    if ([datetime]::UtcNow -lt $script:JobIoUntil) {
        Set-AlfaGuiBadge -Key 'jobio' -State 'green'
    } else {
        Set-AlfaGuiBadge -Key 'jobio' -State 'yellow'
    }
}

function Get-AlfaGuiActiveShardPortSet {
    # inference-shards.active.env (also used for Pool72). HOST PORT ...
    $path = Join-Path $RepoDir 'deploy\llamacpp-rpc\inference-shards.active.env'
    $set = @{}
    if (-not (Test-Path -LiteralPath $path)) {
        return $set
    }
    foreach ($line in Get-Content -LiteralPath $path) {
        $trim = ($line -replace '#.*$', '').Trim()
        if (-not $trim) { continue }
        $parts = $trim -split '\s+'
        if ($parts.Count -ge 2) {
            $set[('{0}:{1}' -f $parts[0], $parts[1])] = $true
        }
    }
    return $set
}

function Set-AlfaGuiShardIoBadge {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$HostIp,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][bool]$CoordUp,
        [Parameter(Mandatory)]$ActivePorts,
        [Parameter(Mandatory)][int]$TcpMs
    )
    Set-AlfaGuiBadge -Key $Key -State 'yellow'
    $id = '{0}:{1}' -f $HostIp, $Port
    if ($CoordUp) {
        # rpc-server is single-client once the coordinator is attached. Probing the
        # shard RPC port then is racy / false DN (and can disrupt the mesh).
        # https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
        if ($ActivePorts.ContainsKey($id)) {
            Set-AlfaGuiBadge -Key $Key -State 'green'
        } else {
            Set-AlfaGuiBadge -Key $Key -State 'gray'
        }
        return
    }
    Set-AlfaGuiProbeResult -Key $Key -Ok (Test-AlfaGuiTcpOk -HostName $HostIp -Port $Port -TimeoutMs $TcpMs)
}

function Update-AlfaGuiStatusLights {
    if ($script:Polling) { return }
    if ($form.IsDisposed) { return }
    $script:Polling = $true
    try {
        Update-AlfaGuiJobIoLight
        $tcpMs = 700
        $httpMs = 1200

        Set-AlfaGuiBadge -Key 'ssh110' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh110' -Ok (Test-AlfaGuiTcpOk -HostName $Ip110 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiBadge -Key 'io110e' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'io110e' -Ok (Test-AlfaGuiHttpOk -Url ("http://{0}:11435/api/tags" -f $Ip110) -TimeoutMs $httpMs)
        Set-AlfaGuiBadge -Key 'io110r' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'io110r' -Ok (Test-AlfaGuiHttpOk -Url ("http://{0}:8360/health" -f $Ip110) -TimeoutMs $httpMs)
        [System.Windows.Forms.Application]::DoEvents()

        Set-AlfaGuiBadge -Key 'ssh111' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh111' -Ok (Test-AlfaGuiTcpOk -HostName $Ip111 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiBadge -Key 'io111c' -State 'yellow'
        $coordUp = Test-AlfaGuiHttpOk -Url ("http://{0}:31360/health" -f $Ip111) -TimeoutMs 2000
        Set-AlfaGuiProbeResult -Key 'io111c' -Ok $coordUp
        Set-AlfaGuiBadge -Key 'io111l' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'io111l' -Ok (Test-AlfaGuiHttpOk -Url ("http://{0}:8413/health/liveliness" -f $Ip111) -TimeoutMs $httpMs)
        Set-AlfaGuiBadge -Key 'io111b' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'io111b' -Ok (Test-AlfaGuiHttpOk -Url ("http://{0}:8420/health" -f $Ip111) -TimeoutMs $httpMs)
        [System.Windows.Forms.Application]::DoEvents()

        $activePorts = Get-AlfaGuiActiveShardPortSet

        Set-AlfaGuiBadge -Key 'ssh148' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh148' -Ok (Test-AlfaGuiTcpOk -HostName $Ip148 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiShardIoBadge -Key 'io148a' -HostIp $Ip148 -Port 31356 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs
        Set-AlfaGuiShardIoBadge -Key 'io148b' -HostIp $Ip148 -Port 31357 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs
        [System.Windows.Forms.Application]::DoEvents()

        Set-AlfaGuiShardIoBadge -Key 'io93' -HostIp $Ip93 -Port 31350 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs

        Set-AlfaGuiBadge -Key 'ssh100' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh100' -Ok (Test-AlfaGuiTcpOk -HostName $Ip100 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiShardIoBadge -Key 'io100' -HostIp $Ip100 -Port 31354 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs

        Set-AlfaGuiBadge -Key 'ssh219' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh219' -Ok (Test-AlfaGuiTcpOk -HostName $Ip219 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiShardIoBadge -Key 'io219' -HostIp $Ip219 -Port 31352 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs
        [System.Windows.Forms.Application]::DoEvents()

        Set-AlfaGuiBadge -Key 'ssh59' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh59' -Ok (Test-AlfaGuiTcpOk -HostName $Ip59 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiShardIoBadge -Key 'io59' -HostIp $Ip59 -Port 31351 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs

        Set-AlfaGuiBadge -Key 'ssh249' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh249' -Ok (Test-AlfaGuiTcpOk -HostName $Ip249 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiShardIoBadge -Key 'io249' -HostIp $Ip249 -Port 31358 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs

        Set-AlfaGuiBadge -Key 'ssh248' -State 'yellow'
        Set-AlfaGuiProbeResult -Key 'ssh248' -Ok (Test-AlfaGuiTcpOk -HostName $Ip248 -Port 22 -TimeoutMs $tcpMs)
        Set-AlfaGuiShardIoBadge -Key 'io248' -HostIp $Ip248 -Port 31355 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs

        Set-AlfaGuiShardIoBadge -Key 'io111s' -HostIp $Ip111 -Port 31353 -CoordUp:$coordUp -ActivePorts $activePorts -TcpMs $tcpMs

        Update-AlfaGuiJobIoLight
        Update-AlfaGuiTrainLockState
        Update-AlfaGuiJobButtons
    } finally {
        $script:Polling = $false
    }
}

function Get-AlfaGuiServicesStillUp {
    # Quick check of inference/RAG ports that must be down before Start.
    # Return the List as one object (unary comma). Do not return ,@($up.ToArray()):
    # that nests Object[] so @(Get-...) Count is 1 when empty and -f / -join print
    # "System.Object[]" (Array.ToString).
    # Comma operator: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_operators?view=powershell-5.1
    # Composite formatting: https://learn.microsoft.com/en-us/dotnet/standard/base-types/composite-formatting
    $up = New-Object System.Collections.Generic.List[string]
    $checks = @(
        @{ Name = 'orchestrator :31350'; Host = $Ip93; Port = 31350; Http = $false },
        @{ Name = 'rag embed'; Url = ("http://{0}:11435/api/tags" -f $Ip110); Http = $true },
        @{ Name = 'rag rerank'; Url = ("http://{0}:8360/health" -f $Ip110); Http = $true },
        @{ Name = 'hub coord'; Url = ("http://{0}:31360/health" -f $Ip111); Http = $true },
        @{ Name = 'hub LiteLLM'; Url = ("http://{0}:8413/health/liveliness" -f $Ip111); Http = $true },
        @{ Name = 'hub brain'; Url = ("http://{0}:8420/health" -f $Ip111); Http = $true },
        @{ Name = 'hub :31353'; Host = $Ip111; Port = 31353; Http = $false },
        @{ Name = 'inference :31356'; Host = $Ip148; Port = 31356; Http = $false },
        @{ Name = 'inference :31357'; Host = $Ip148; Port = 31357; Http = $false },
        @{ Name = 'pool-opt-in :31354'; Host = $Ip100; Port = 31354; Http = $false },
        @{ Name = 'gaming-c :31351'; Host = $Ip59; Port = 31351; Http = $false },
        @{ Name = 'gaming-b :31358'; Host = $Ip249; Port = 31358; Http = $false },
        @{ Name = 'secondary :31355'; Host = $Ip248; Port = 31355; Http = $false }
    )
    foreach ($c in $checks) {
        $ok = $false
        if ($c.Http) {
            $ok = Test-AlfaGuiHttpOk -Url $c.Url -TimeoutMs 900
        } else {
            $ok = Test-AlfaGuiTcpOk -HostName $c.Host -Port $c.Port -TimeoutMs 500
        }
        if ($ok) { [void]$up.Add($c.Name) }
    }
    return ,$up
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

function Start-AlfaGuiOrchestrator {
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'stop')][string]$Mode
    )
    if (-not (Test-Path -LiteralPath $Orchestrator)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Orchestrator missing:`n$Orchestrator`n`nRun git pull in $RepoDir",
            'ALFa Models',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    if (Test-AlfaGuiClusterBusy) {
        [System.Windows.Forms.MessageBox]::Show(
            'A cluster start/stop is already running. Wait for it to finish.',
            'ALFa Models',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    $peerMsg = Get-AlfaDesktopJobPeerMessage -SelfKind cluster -RepoDir $RepoDir
    if (-not [string]::IsNullOrWhiteSpace($peerMsg)) {
        [System.Windows.Forms.MessageBox]::Show(
            $peerMsg,
            'ALFa Models',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $inference = 'inference'
    if ($rbPool80.Checked) { $inference = 'Pool80' }
    elseif ($rbPool72.Checked) { $inference = 'Pool72' }

    $argParts = New-Object System.Collections.Generic.List[string]
    [void]$argParts.Add('-NoProfile')
    [void]$argParts.Add('-ExecutionPolicy')
    [void]$argParts.Add('Bypass')
    [void]$argParts.Add('-File')
    [void]$argParts.Add(('"{0}"' -f $Orchestrator))
    [void]$argParts.Add($Mode)

    if ($Mode -eq 'start') {
        if ((Test-AlfaTrainLockPresent) -and ($inference -eq 'Pool72' -or $inference -eq 'Pool80')) {
            [System.Windows.Forms.MessageBox]::Show(
                ("7B QLoRA trainer lock is set. Pool72/Pool80 cannot start while training.`n`n$TrainLockPath`n`nUse inference or stop the trainer first (train-desktop-menu.ps1)."),
                'Start blocked',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        if ($inference -eq 'Pool72' -or $inference -eq 'Pool80') {
            $missing = @()
            if (-not $chk59.Checked) { $missing += 'gaming-c' }
            if (-not $chk219.Checked) { $missing += 'gaming-a' }
            if (-not $chk249.Checked) { $missing += 'gaming-b' }
            if (-not $chk248.Checked) { $missing += 'secondary' }
            if (-not $chk100.Checked) { $missing += 'pool-opt-in' }
            if ($missing.Count -gt 0) {
                $msg = ("{0} prefers full-mesh opt-in. Unchecked: {1}.`n`nContinue anyway?" -f $inference, ($missing -join ', '))
                $r = [System.Windows.Forms.MessageBox]::Show(
                    $msg,
                    ("{0} hosts" -f $inference),
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
        }

        $ctxParsed = 0
        $parallelParsed = 0
        if (-not [int]::TryParse($txtCtx.Text.Trim(), [ref]$ctxParsed) -or $ctxParsed -lt 512) {
            [System.Windows.Forms.MessageBox]::Show('Context must be an integer of at least 512.', 'ALFa Models') | Out-Null
            return
        }
        if (-not [int]::TryParse($txtParallel.Text.Trim(), [ref]$parallelParsed) -or $parallelParsed -lt 1) {
            [System.Windows.Forms.MessageBox]::Show('Parallel must be an integer of at least 1.', 'ALFa Models') | Out-Null
            return
        }
        [void]$argParts.Add('-InferenceMode')
        [void]$argParts.Add($inference)
        [void]$argParts.Add('-CtxSize')
        [void]$argParts.Add([string]$ctxParsed)
        [void]$argParts.Add('-ParallelSlots')
        [void]$argParts.Add([string]$parallelParsed)
        [void]$argParts.Add('-GamingMode')
        [void]$argParts.Add('Flags')
        if ($chk219.Checked) { [void]$argParts.Add('-Include219') }
        if ($chk59.Checked) { [void]$argParts.Add('-Include59') }
        if ($chk249.Checked) { [void]$argParts.Add('-Include249') }
        if ($chk248.Checked) { [void]$argParts.Add('-Include248') }
        if ($chk100.Checked) { [void]$argParts.Add('-Include100') }
        Save-AlfaGuiPrefs -InferenceMode $inference -CtxSize $ctxParsed -ParallelSlots $parallelParsed
    }

    $argLine = ($argParts -join ' ')
    Clear-AlfaGuiLog
    Append-AlfaGuiLog ("== {0} ==" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
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
        Append-AlfaGuiLog ("== cluster finished exit={0} ==" -f $code)
        $script:ClusterProc = $null
        Update-AlfaGuiJobButtons
        Update-AlfaGuiJobIoAfterExit
        $lblStatus.Text = if ($code -eq 0) { 'Last run: OK' } else { ("Last run: FAIL (exit {0})" -f $code) }
        $lblStatus.ForeColor = $ColorMuted
        Update-AlfaGuiStatusLights
    })

    $lblStatus.Text = ("Running {0}..." -f $Mode)
    $lblStatus.ForeColor = $ColorMuted
    if (-not $script:LogExpanded) {
        Set-AlfaGuiLogExpanded -Expand $true
    }

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $script:ClusterProc = $proc
    Update-AlfaGuiJobButtons
}

# --- UI ---
try {
$prefs = Read-AlfaGuiPrefs

$Margin = 16
$ColW = 300
$Gutter = 16
$LeftX = $Margin
$RightX = $Margin + $ColW + $Gutter
$ContentW = ($ColW * 2) + $Gutter
$RowH = 22
$HeaderH = 64

$form = New-Object System.Windows.Forms.Form
$form.Text = ('ALFa Models {0}' -f $script:GuiMenuRev)
$form.ClientSize = New-Object System.Drawing.Size(($Margin * 2 + $ContentW), $script:FormHeightCollapsed)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = $ColorFormBg
$form.Add_FormClosing({
    if (Test-AlfaGuiClusterBusy) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'A cluster job is still running.`n`nYes = kill the job and close.`nNo = close GUI and leave the job running.`nCancel = stay open.',
            'ALFa Models',
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
$lblTitle.Text = 'Run models'
$lblTitle.ForeColor = $ColorHeaderText
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.BackColor = $ColorHeader
$panelHeader.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Location = New-Object System.Drawing.Point($LeftX, 34)
$lblSubtitle.Size = New-Object System.Drawing.Size($ContentW, 18)
$lblSubtitle.Text = 'Inference pool -- Start / Stop cluster'
$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 200)
$lblSubtitle.BackColor = $ColorHeader
$panelHeader.Controls.Add($lblSubtitle)

$contentY = $HeaderH + 12
$contentH = 620

$panelRun = New-Object System.Windows.Forms.Panel
$panelRun.Location = New-Object System.Drawing.Point($LeftX, $contentY)
$panelRun.Size = New-Object System.Drawing.Size($ContentW, $contentH)
$panelRun.BackColor = $ColorFormBg
$form.Controls.Add($panelRun)

$grpModel = New-Object System.Windows.Forms.GroupBox
$grpModel.Location = New-Object System.Drawing.Point(0, 0)
$grpModel.Size = New-Object System.Drawing.Size($ColW, 156)
$grpModel.Text = '  Model  '
$grpModel.BackColor = $ColorPanel
$panelRun.Controls.Add($grpModel)

$rbinference = New-Object System.Windows.Forms.RadioButton
$rbinference.Location = New-Object System.Drawing.Point(16, 24)
$rbinference.Size = New-Object System.Drawing.Size(268, 20)
$rbinference.Text = 'inference  (frontier-code 3.8)'
$rbinference.Checked = ($prefs.InferenceMode -eq 'inference' -or $prefs.InferenceMode -eq 'inference_38' -or [string]::IsNullOrEmpty($prefs.InferenceMode))
if ($prefs.InferenceMode -eq 'Pool72' -or $prefs.InferenceMode -eq 'Pool80') { $rbinference.Checked = $false }
$grpModel.Controls.Add($rbinference)

$rbPool72 = New-Object System.Windows.Forms.RadioButton
$rbPool72.Location = New-Object System.Drawing.Point(16, 46)
$rbPool72.Size = New-Object System.Drawing.Size(268, 20)
$rbPool72.Text = 'Pool72  (exclusive 72B Q5)'
$rbPool72.Checked = ($prefs.InferenceMode -eq 'Pool72')
$grpModel.Controls.Add($rbPool72)

$rbPool80 = New-Object System.Windows.Forms.RadioButton
$rbPool80.Location = New-Object System.Drawing.Point(16, 68)
$rbPool80.Size = New-Object System.Drawing.Size(268, 20)
$rbPool80.Text = 'Pool80  (exclusive 80B Q5)'
$rbPool80.Checked = ($prefs.InferenceMode -eq 'Pool80')
$grpModel.Controls.Add($rbPool80)

$poolRadioHandler = {
    Update-AlfaGuiinferenceExclusiveHosts
    if ($null -ne $txtCtx) {
        $mode = 'inference'
        if ($rbPool80.Checked) { $mode = 'Pool80' }
        elseif ($rbPool72.Checked) { $mode = 'Pool72' }
        $defs = Get-AlfaGuiPoolRunDefaults -InferenceMode $mode
        $txtCtx.Text = [string]$defs.Ctx
        $txtParallel.Text = [string]$defs.Parallel
    }
}
$rbinference.Add_CheckedChanged($poolRadioHandler)
$rbPool72.Add_CheckedChanged($poolRadioHandler)
$rbPool80.Add_CheckedChanged($poolRadioHandler)

$lblModelHint = New-Object System.Windows.Forms.Label
$lblModelHint.Location = New-Object System.Drawing.Point(16, 92)
$lblModelHint.Size = New-Object System.Drawing.Size(268, 52)
$lblModelHint.ForeColor = $ColorMuted
$lblModelHint.Text = 'inference opt-in: gaming-a/gaming-c/gaming-b/secondary/pool-opt-in (never required for core green).'
$grpModel.Controls.Add($lblModelHint)

$grpHosts = New-Object System.Windows.Forms.GroupBox
$grpHosts.Location = New-Object System.Drawing.Point(($ColW + $Gutter), 0)
$grpHosts.Size = New-Object System.Drawing.Size($ColW, 156)
$grpHosts.Text = '  Opt-in hosts (this start)  '
$grpHosts.BackColor = $ColorPanel
$panelRun.Controls.Add($grpHosts)

$chk219 = New-Object System.Windows.Forms.CheckBox
$chk219.Location = New-Object System.Drawing.Point(16, 22)
$chk219.Size = New-Object System.Drawing.Size(268, 18)
$chk219.Text = 'gaming-a gaming-worker-a :31352'
$chk219.Checked = [bool]$prefs.Include219
$grpHosts.Controls.Add($chk219)

$chk59 = New-Object System.Windows.Forms.CheckBox
$chk59.Location = New-Object System.Drawing.Point(16, 42)
$chk59.Size = New-Object System.Drawing.Size(268, 18)
$chk59.Text = 'gaming-c gaming-worker-c :31351'
$chk59.Checked = [bool]$prefs.Include59
$grpHosts.Controls.Add($chk59)

$chk249 = New-Object System.Windows.Forms.CheckBox
$chk249.Location = New-Object System.Drawing.Point(16, 62)
$chk249.Size = New-Object System.Drawing.Size(268, 18)
$chk249.Text = 'gaming-b gaming-worker-b :31358'
$chk249.Checked = [bool]$prefs.Include249
$grpHosts.Controls.Add($chk249)

$chk248 = New-Object System.Windows.Forms.CheckBox
$chk248.Location = New-Object System.Drawing.Point(16, 82)
$chk248.Size = New-Object System.Drawing.Size(268, 18)
$chk248.Text = 'secondary gpu-248 :31355'
$chk248.Checked = [bool]$prefs.Include248
$grpHosts.Controls.Add($chk248)

$chk100 = New-Object System.Windows.Forms.CheckBox
$chk100.Location = New-Object System.Drawing.Point(16, 102)
$chk100.Size = New-Object System.Drawing.Size(268, 18)
$chk100.Text = 'pool-opt-in VM100 :31354'
$chk100.Checked = [bool]$prefs.Include100
$grpHosts.Controls.Add($chk100)

$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpRun = New-Object System.Windows.Forms.GroupBox
$grpRun.Location = New-Object System.Drawing.Point(0, 164)
$grpRun.Size = New-Object System.Drawing.Size($ContentW, 72)
$grpRun.Text = '  Run settings (change before Start)  '
$grpRun.BackColor = $ColorPanel
$panelRun.Controls.Add($grpRun)

$lblCtx = New-Object System.Windows.Forms.Label
$lblCtx.Location = New-Object System.Drawing.Point(16, 28)
$lblCtx.Size = New-Object System.Drawing.Size(70, 20)
$lblCtx.Text = 'Context'
$grpRun.Controls.Add($lblCtx)

$txtCtx = New-Object System.Windows.Forms.TextBox
$txtCtx.Location = New-Object System.Drawing.Point(90, 26)
$txtCtx.Size = New-Object System.Drawing.Size(90, 22)
$grpRun.Controls.Add($txtCtx)

$lblParallel = New-Object System.Windows.Forms.Label
$lblParallel.Location = New-Object System.Drawing.Point(200, 28)
$lblParallel.Size = New-Object System.Drawing.Size(70, 20)
$lblParallel.Text = 'Parallel'
$grpRun.Controls.Add($lblParallel)

$txtParallel = New-Object System.Windows.Forms.TextBox
$txtParallel.Location = New-Object System.Drawing.Point(274, 26)
$txtParallel.Size = New-Object System.Drawing.Size(50, 22)
$grpRun.Controls.Add($txtParallel)

$lblRunHint = New-Object System.Windows.Forms.Label
$lblRunHint.Location = New-Object System.Drawing.Point(340, 22)
$lblRunHint.Size = New-Object System.Drawing.Size(($ContentW - 356), 40)
$lblRunHint.ForeColor = $ColorMuted
$lblRunHint.Text = 'Context is the total KV budget shared by the parallel slots. Switching the model radio resets these two boxes.'
$grpRun.Controls.Add($lblRunHint)

$openMode = 'inference'
if ($rbPool80.Checked) { $openMode = 'Pool80' }
elseif ($rbPool72.Checked) { $openMode = 'Pool72' }
$openDefs = Get-AlfaGuiPoolRunDefaults -InferenceMode $openMode
if ($prefs.CtxSize -gt 0) { $txtCtx.Text = [string]$prefs.CtxSize } else { $txtCtx.Text = [string]$openDefs.Ctx }
if ($prefs.ParallelSlots -gt 0) { $txtParallel.Text = [string]$prefs.ParallelSlots } else { $txtParallel.Text = [string]$openDefs.Parallel }

$grpStatus.Location = New-Object System.Drawing.Point(0, 244)
$grpStatus.Size = New-Object System.Drawing.Size($ContentW, 310)
$grpStatus.Text = '  Inference ports (DN after Stop cluster is expected)  '
$grpStatus.BackColor = $ColorPanel
# GroupBox cannot scroll (WinForms): https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.groupbox
$panelRun.Controls.Add($grpStatus)

$hdrY = 20
$lblHdrHost = New-Object System.Windows.Forms.Label
$lblHdrHost.Location = New-Object System.Drawing.Point(12, $hdrY)
$lblHdrHost.Size = New-Object System.Drawing.Size(140, 16)
$lblHdrHost.Text = 'HOST'
$lblHdrHost.ForeColor = $ColorMuted
$lblHdrHost.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$grpStatus.Controls.Add($lblHdrHost)

$lblHdrSsh = New-Object System.Windows.Forms.Label
$lblHdrSsh.Location = New-Object System.Drawing.Point(156, $hdrY)
$lblHdrSsh.Size = New-Object System.Drawing.Size(40, 16)
$lblHdrSsh.Text = 'SSH'
$lblHdrSsh.ForeColor = $ColorMuted
$lblHdrSsh.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$grpStatus.Controls.Add($lblHdrSsh)

$lblHdrIo = New-Object System.Windows.Forms.Label
$lblHdrIo.Location = New-Object System.Drawing.Point(210, $hdrY)
$lblHdrIo.Size = New-Object System.Drawing.Size(280, 16)
$lblHdrIo.Text = 'NETWORK I/O'
$lblHdrIo.ForeColor = $ColorMuted
$lblHdrIo.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$grpStatus.Controls.Add($lblHdrIo)

$y = 40
$alt = $false
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'orchestrator operator' -SshKey 'local' -AltRow:$alt -IoItems @(
    @{ Key = 'io93'; Caption = ':31350' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'rag RAG' -SshKey 'ssh110' -AltRow:$alt -IoItems @(
    @{ Key = 'io110e'; Caption = 'embed' },
    @{ Key = 'io110r'; Caption = 'rerank' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'hub brain' -SshKey 'ssh111' -AltRow:$alt -IoItems @(
    @{ Key = 'io111c'; Caption = 'coord' },
    @{ Key = 'io111s'; Caption = ':31353' },
    @{ Key = 'io111l'; Caption = 'LiteLLM' },
    @{ Key = 'io111b'; Caption = 'brain' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'inference ai-148' -SshKey 'ssh148' -AltRow:$alt -IoItems @(
    @{ Key = 'io148a'; Caption = ':31356' },
    @{ Key = 'io148b'; Caption = ':31357' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'pool-opt-in VM100' -SshKey 'ssh100' -AltRow:$alt -IoItems @(
    @{ Key = 'io100'; Caption = ':31354' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'gaming-a gaming-worker-a' -SshKey 'ssh219' -AltRow:$alt -IoItems @(
    @{ Key = 'io219'; Caption = ':31352' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'gaming-c gaming-worker-c' -SshKey 'ssh59' -AltRow:$alt -IoItems @(
    @{ Key = 'io59'; Caption = ':31351' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'gaming-b gaming-worker-b' -SshKey 'ssh249' -AltRow:$alt -IoItems @(
    @{ Key = 'io249'; Caption = ':31358' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'secondary gpu-248' -SshKey 'ssh248' -AltRow:$alt -IoItems @(
    @{ Key = 'io248'; Caption = ':31355' }
)
$y += $RowH; $alt = -not $alt
Add-AlfaGuiHostRow -Parent $grpStatus -Y $y -HostText 'Job I/O (log)' -SshKey '-' -AltRow:$alt -IoItems @(
    @{ Key = 'jobio'; Caption = 'stream' }
)

$btnStop = New-AlfaGuiFlatButton -Text 'Stop cluster' -Back $ColorBtnStop -Fore ([System.Drawing.Color]::White)
$btnStop.Location = New-Object System.Drawing.Point(0, 562)
$btnStop.Size = New-Object System.Drawing.Size($ColW, 38)
$btnStop.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Run full cluster STOP?`n`nTears down pool + brain app + RAG.`nEdge and DBs stay up.",
        'Confirm stop',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-AlfaGuiOrchestrator -Mode 'stop'
    }
})
$panelRun.Controls.Add($btnStop)

$btnStart = New-AlfaGuiFlatButton -Text 'Start cluster' -Back $ColorBtnStart -Fore ([System.Drawing.Color]::White)
$btnStart.Location = New-Object System.Drawing.Point(($ColW + $Gutter), 562)
$btnStart.Size = New-Object System.Drawing.Size($ColW, 38)
$btnStart.Add_Click({
    $inference = 'inference'
    if ($rbPool80.Checked) { $inference = 'Pool80' }
    elseif ($rbPool72.Checked) { $inference = 'Pool72' }
    if ((Test-AlfaTrainLockPresent) -and ($inference -eq 'Pool72' -or $inference -eq 'Pool80')) {
        [System.Windows.Forms.MessageBox]::Show(
            ("7B QLoRA trainer lock is set. Pool72/Pool80 cannot start while training.`n`n$TrainLockPath`n`nUse inference or stop the trainer first (train-desktop-menu.ps1)."),
            'Start blocked',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    $lblStatus.Text = 'Checking if cluster is stopped...'
    [System.Windows.Forms.Application]::DoEvents()
    # Do not wrap in @(): that enumerates the List and breaks Count-on-empty.
    $stillUp = Get-AlfaGuiServicesStillUp
    Update-AlfaGuiStatusLights

    if ($stillUp.Count -gt 0) {
        $list = [string]::Join(', ', $stillUp)
        if ($list.Length -gt 280) { $list = $list.Substring(0, 277) + '...' }
        $msg = "START $inference -- some services are STILL UP:`n`n$list`n`nRun Stop first (recommended), or start anyway?"
        $r = [System.Windows.Forms.MessageBox]::Show(
            $msg,
            'Cluster not fully stopped',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $lblStatus.Text = 'Start cancelled -- services still up'
            return
        }
    } else {
        $msg = ("Start {0} now?`n`nPreflight: service ports look down (ready for start)." -f $inference)
        $r = [System.Windows.Forms.MessageBox]::Show(
            $msg,
            'Confirm start',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $lblStatus.Text = 'Ready'
            return
        }
    }
    Start-AlfaGuiOrchestrator -Mode 'start'
})
$panelRun.Controls.Add($btnStart)

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
    $lblStatus.Text = 'Refreshing status...'
    Update-AlfaGuiStatusLights
    if (-not (Test-AlfaTrainLockPresent)) {
        $lblStatus.Text = 'Ready'
        $lblStatus.ForeColor = $ColorMuted
    }
})
$form.Controls.Add($btnRefresh)

$btninferenceMetrics = New-AlfaGuiFlatButton -Text 'inference metrics' -Back $ColorBtnFlat -Fore ([System.Drawing.Color]::FromArgb(40, 50, 60))
$btninferenceMetrics.Location = New-Object System.Drawing.Point(($LeftX + 236), $footerY)
$btninferenceMetrics.Size = New-Object System.Drawing.Size(130, 28)
$btninferenceMetrics.FlatAppearance.BorderSize = 1
$btninferenceMetrics.FlatAppearance.BorderColor = $ColorBorder
$btninferenceMetrics.Add_Click({
    # Official: Start-Process with a URL opens the default browser.
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process
    Start-Process 'http://monitor/d/inference-inference/inference-inference'
})
$form.Controls.Add($btninferenceMetrics)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(($LeftX + 374), ($footerY + 4))
$lblStatus.Size = New-Object System.Drawing.Size(($ContentW - 374), 22)
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
    Update-AlfaGuiStatusLights
})

$timerIo = New-Object System.Windows.Forms.Timer
$timerIo.Interval = 400
$timerIo.Add_Tick({ Update-AlfaGuiJobIoLight })

Set-AlfaGuiLogExpanded -Expand $false
$timer.Start()
$timerIo.Start()
$form.Add_Shown({
    Update-AlfaGuiinferenceExclusiveHosts
    Update-AlfaGuiJobButtons
    Update-AlfaGuiStatusLights
})
Update-AlfaGuiJobButtons

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
        'ALFa Models',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    throw
}
