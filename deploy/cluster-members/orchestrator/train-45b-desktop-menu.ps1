#Requires -Version 5.1
<#
.SYNOPSIS
  Desktop window for the .45b trainer. Opening it does not start training.

.DESCRIPTION
  Same header, flat buttons, and start/stop row as the other ALFa desktop menus.
  Start asks for confirmation, then runs Start-AlfaTrain45bIsland.ps1.
  WinForms: https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.form
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$IslandScript = Join-Path $PSScriptRoot 'Start-AlfaTrain45bIsland.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$LogPath = Join-Path $env:TEMP 'alfa-45b-gui.log'

$ColorHeader = [System.Drawing.Color]::FromArgb(28, 40, 56)
$ColorHeaderText = [System.Drawing.Color]::FromArgb(245, 247, 250)
$ColorMuted = [System.Drawing.Color]::FromArgb(120, 130, 140)
$ColorFormBg = [System.Drawing.Color]::FromArgb(236, 239, 243)
$ColorPanel = [System.Drawing.Color]::White
$ColorBtnStop = [System.Drawing.Color]::FromArgb(160, 55, 55)
$ColorBtnStart = [System.Drawing.Color]::FromArgb(40, 110, 170)
$ColorBtnFlat = [System.Drawing.Color]::FromArgb(248, 249, 251)

function New-Alfa45bFlatButton {
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

$Margin = 16
$ContentW = 640
$HeaderH = 64

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ALFa Trainer .45b'
$form.ClientSize = New-Object System.Drawing.Size(($Margin * 2 + $ContentW), 920)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = $ColorFormBg
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$panelHeader = New-Object System.Windows.Forms.Panel
$panelHeader.Location = New-Object System.Drawing.Point(0, 0)
$panelHeader.Size = New-Object System.Drawing.Size(($form.ClientSize.Width), $HeaderH)
$panelHeader.BackColor = $ColorHeader
$form.Controls.Add($panelHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point($Margin, 10)
$lblTitle.Size = New-Object System.Drawing.Size($ContentW, 22)
$lblTitle.Text = '.45b Trainer'
$lblTitle.ForeColor = $ColorHeaderText
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.BackColor = $ColorHeader
$panelHeader.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Location = New-Object System.Drawing.Point($Margin, 34)
$lblSubtitle.Size = New-Object System.Drawing.Size($ContentW, 20)
$lblSubtitle.Text = 'Four ranks, bf16, AdamW. Opening this window does not start.'
$lblSubtitle.ForeColor = $ColorMuted
$lblSubtitle.BackColor = $ColorHeader
$panelHeader.Controls.Add($lblSubtitle)

$grpHosts = New-Object System.Windows.Forms.GroupBox
$grpHosts.Text = 'Island'
$grpHosts.Location = New-Object System.Drawing.Point($Margin, 80)
$grpHosts.Size = New-Object System.Drawing.Size($ContentW, 136)
$grpHosts.BackColor = $ColorPanel
$form.Controls.Add($grpHosts)

$lblHosts = New-Object System.Windows.Forms.Label
$lblHosts.Location = New-Object System.Drawing.Point(12, 24)
$lblHosts.Size = New-Object System.Drawing.Size(490, 84)
$lblHosts.Text = "Rank 0  orchestrator   RTX 3060`r`nRank 1  gaming-c   RTX 5070`r`nRank 2  gaming-b  RTX 5070`r`nRank 3  inference  RTX 3060 (5060 stays out)`r`nModel 24 layers, hidden 1024, 16 heads, seq 2048, bf16"
$grpHosts.Controls.Add($lblHosts)

$grpSettings = New-Object System.Windows.Forms.GroupBox
$grpSettings.Text = 'Run settings'
$grpSettings.Location = New-Object System.Drawing.Point($Margin, 224)
$grpSettings.Size = New-Object System.Drawing.Size($ContentW, 440)
$grpSettings.BackColor = $ColorPanel
$form.Controls.Add($grpSettings)

function New-Alfa45bField {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [string]$Label,
        [string]$Value,
        [int]$BoxWidth
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point($X, ($Y + 3))
    $lbl.Size = New-Object System.Drawing.Size(160, 20)
    $lbl.Text = $Label
    $Parent.Controls.Add($lbl)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(($X + 164), $Y)
    $box.Size = New-Object System.Drawing.Size($BoxWidth, 22)
    $box.Text = $Value
    $Parent.Controls.Add($box)
    return $box
}

$txtSteps = New-Alfa45bField -Parent $grpSettings -X 12 -Y 24 -Label 'Max steps' -Value '8448' -BoxWidth 80
$txtBatch = New-Alfa45bField -Parent $grpSettings -X 12 -Y 52 -Label 'Batch size' -Value '1' -BoxWidth 80
$txtSeed = New-Alfa45bField -Parent $grpSettings -X 12 -Y 80 -Label 'Seed' -Value '1' -BoxWidth 80
$txtLogEvery = New-Alfa45bField -Parent $grpSettings -X 12 -Y 108 -Label 'Log every' -Value '10' -BoxWidth 80
$txtCkptEvery = New-Alfa45bField -Parent $grpSettings -X 12 -Y 136 -Label 'Checkpoint every' -Value '100' -BoxWidth 80
$lblOpt = New-Object System.Windows.Forms.Label
$lblOpt.Location = New-Object System.Drawing.Point(12, 171)
$lblOpt.Size = New-Object System.Drawing.Size(150, 20)
$lblOpt.Text = 'Optimizer'
$grpSettings.Controls.Add($lblOpt)
$cboOpt = New-Object System.Windows.Forms.ComboBox
$cboOpt.Location = New-Object System.Drawing.Point(176, 168)
$cboOpt.Size = New-Object System.Drawing.Size(100, 22)
$cboOpt.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cboOpt.Items.Add('adamw')
[void]$cboOpt.Items.Add('muon')
$cboOpt.SelectedIndex = 0
$grpSettings.Controls.Add($cboOpt)
$chkCompile = New-Object System.Windows.Forms.CheckBox
$chkCompile.Location = New-Object System.Drawing.Point(12, 200)
$chkCompile.Size = New-Object System.Drawing.Size(220, 22)
$chkCompile.Text = 'Compile blocks'
$chkCompile.Checked = $true
$grpSettings.Controls.Add($chkCompile)
$chkAct = New-Object System.Windows.Forms.CheckBox
$chkAct.Location = New-Object System.Drawing.Point(12, 226)
$chkAct.Size = New-Object System.Drawing.Size(260, 22)
$chkAct.Text = 'Activation checkpoint'
$chkAct.Checked = $false
$grpSettings.Controls.Add($chkAct)
$chkResume = New-Object System.Windows.Forms.CheckBox
$chkResume.Location = New-Object System.Drawing.Point(12, 252)
$chkResume.Size = New-Object System.Drawing.Size(300, 22)
$chkResume.Text = 'Resume latest checkpoint'
$chkResume.Checked = $false
$grpSettings.Controls.Add($chkResume)

$txtLr = New-Alfa45bField -Parent $grpSettings -X 330 -Y 24 -Label 'AdamW lr' -Value '0.0003' -BoxWidth 90
$txtBeta1 = New-Alfa45bField -Parent $grpSettings -X 330 -Y 52 -Label 'AdamW beta1' -Value '0.9' -BoxWidth 90
$txtBeta2 = New-Alfa45bField -Parent $grpSettings -X 330 -Y 80 -Label 'AdamW beta2' -Value '0.95' -BoxWidth 90
$txtWd = New-Alfa45bField -Parent $grpSettings -X 330 -Y 108 -Label 'AdamW decay' -Value '0.1' -BoxWidth 90
$txtMuonLr = New-Alfa45bField -Parent $grpSettings -X 330 -Y 136 -Label 'Muon lr' -Value '0.02' -BoxWidth 90
$txtMuonMom = New-Alfa45bField -Parent $grpSettings -X 330 -Y 164 -Label 'Muon momentum' -Value '0.95' -BoxWidth 90
$txtMuonWd = New-Alfa45bField -Parent $grpSettings -X 330 -Y 192 -Label 'Muon decay' -Value '0.1' -BoxWidth 90
$txtReserve = New-Alfa45bField -Parent $grpSettings -X 330 -Y 220 -Label 'Reserve GiB desktops' -Value '3' -BoxWidth 90
$txtReserve148 = New-Alfa45bField -Parent $grpSettings -X 330 -Y 248 -Label 'Reserve GiB inference' -Value '0' -BoxWidth 90
$txtUpsample = New-Alfa45bField -Parent $grpSettings -X 330 -Y 276 -Label 'Replay upsample' -Value '2' -BoxWidth 90
$txtPatience = New-Alfa45bField -Parent $grpSettings -X 330 -Y 304 -Label 'Retention patience' -Value '3' -BoxWidth 90
$txtReplay = New-Alfa45bField -Parent $grpSettings -X 12 -Y 360 -Label 'Replay from' -Value '' -BoxWidth 420
$lblReplay = New-Object System.Windows.Forms.Label
$lblReplay.Location = New-Object System.Drawing.Point(12, 388)
$lblReplay.Size = New-Object System.Drawing.Size(600, 32)
$lblReplay.Text = 'Replay from is a Linux path on every rank. Leave it empty for the first run. Desktops are orchestrator, gaming-c, and gaming-b.'
$grpSettings.Controls.Add($lblReplay)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point($Margin, 672)
$lblStatus.Size = New-Object System.Drawing.Size($ContentW, 32)
$lblStatus.Text = 'Idle. Start has not been pressed.'
$lblStatus.ForeColor = $ColorMuted
$form.Controls.Add($lblStatus)

$BtnW = 160
$btnStart = New-Alfa45bFlatButton -Text 'Start .45b' -Back $ColorBtnStart -Fore ([System.Drawing.Color]::White)
$btnStart.Location = New-Object System.Drawing.Point($Margin, 708)
$btnStart.Size = New-Object System.Drawing.Size($BtnW, 40)
$form.Controls.Add($btnStart)

$btnStop = New-Alfa45bFlatButton -Text 'Stop .45b' -Back $ColorBtnStop -Fore ([System.Drawing.Color]::White)
$btnStop.Location = New-Object System.Drawing.Point(($Margin + $BtnW + 8), 708)
$btnStop.Size = New-Object System.Drawing.Size($BtnW, 40)
$form.Controls.Add($btnStop)

$btnRefresh = New-Alfa45bFlatButton -Text 'Refresh log' -Back $ColorBtnFlat -Fore ([System.Drawing.Color]::FromArgb(40, 50, 60))
$btnRefresh.Location = New-Object System.Drawing.Point(($Margin + ($BtnW + 8) * 2), 708)
$btnRefresh.Size = New-Object System.Drawing.Size(140, 40)
$form.Controls.Add($btnRefresh)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point($Margin, 760)
$txtLog.Size = New-Object System.Drawing.Size($ContentW, 140)
$txtLog.Multiline = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 34)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 224, 228)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

function Update-Alfa45bLogView {
    if (Test-Path -LiteralPath $LogPath) {
        $txtLog.Text = [System.IO.File]::ReadAllText($LogPath)
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

$btnRefresh.Add_Click({ Update-Alfa45bLogView })

function Read-Alfa45bInt {
    param([System.Windows.Forms.TextBox]$Box, [string]$Name)
    $parsed = 0
    if (-not [int]::TryParse($Box.Text.Trim(), [ref]$parsed)) {
        throw ("{0} must be an integer." -f $Name)
    }
    return $parsed
}

function Read-Alfa45bDouble {
    param([System.Windows.Forms.TextBox]$Box, [string]$Name)
    $parsed = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($Box.Text.Trim(), $style, $culture, [ref]$parsed)) {
        throw ("{0} must be a number." -f $Name)
    }
    return $parsed
}

$btnStart.Add_Click({
    try {
        $steps = Read-Alfa45bInt -Box $txtSteps -Name 'Max steps'
        $batch = Read-Alfa45bInt -Box $txtBatch -Name 'Batch size'
        $seed = Read-Alfa45bInt -Box $txtSeed -Name 'Seed'
        $logEvery = Read-Alfa45bInt -Box $txtLogEvery -Name 'Log every'
        $ckptEvery = Read-Alfa45bInt -Box $txtCkptEvery -Name 'Checkpoint every'
        $reserve = Read-Alfa45bInt -Box $txtReserve -Name 'Desktop reserve'
        $reserve148 = Read-Alfa45bInt -Box $txtReserve148 -Name 'inference reserve'
        $upsample = Read-Alfa45bInt -Box $txtUpsample -Name 'Replay upsample'
        $patience = Read-Alfa45bInt -Box $txtPatience -Name 'Retention patience'
        $lr = Read-Alfa45bDouble -Box $txtLr -Name 'AdamW lr'
        $beta1 = Read-Alfa45bDouble -Box $txtBeta1 -Name 'AdamW beta1'
        $beta2 = Read-Alfa45bDouble -Box $txtBeta2 -Name 'AdamW beta2'
        $wd = Read-Alfa45bDouble -Box $txtWd -Name 'AdamW decay'
        $muonLr = Read-Alfa45bDouble -Box $txtMuonLr -Name 'Muon lr'
        $muonMom = Read-Alfa45bDouble -Box $txtMuonMom -Name 'Muon momentum'
        $muonWd = Read-Alfa45bDouble -Box $txtMuonWd -Name 'Muon decay'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ALFa Trainer .45b') | Out-Null
        return
    }
    if ($steps -lt 1 -or $batch -lt 1 -or $logEvery -lt 1 -or $ckptEvery -lt 1 -or $upsample -lt 1 -or $patience -lt 1) {
        [System.Windows.Forms.MessageBox]::Show('Steps, batch, log interval, checkpoint interval, upsample, and patience must be at least 1.', 'ALFa Trainer .45b') | Out-Null
        return
    }
    $opt = [string]$cboOpt.SelectedItem
    $replay = $txtReplay.Text.Trim()
    $resumeNote = ''
    if ($chkResume.Checked) { $resumeNote = ' Resume from the latest checkpoint; Max steps stays the total.' }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Start .45b on orchestrator, gaming-c, gaming-b, and inference?`r`n`r`nSteps {0}, batch {1}, {2}, AdamW lr {3}.{4}`r`nThis does not stop inference." -f $steps, $batch, $opt, $lr, $resumeNote),
        'ALFa Trainer .45b',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$IslandScript`" -MaxSteps $steps -BatchSize $batch -Seed $seed -LogEvery $logEvery -CheckpointEvery $ckptEvery -Optimizer $opt -LearningRate $($lr.ToString('G9', $inv)) -Beta1 $($beta1.ToString('G9', $inv)) -Beta2 $($beta2.ToString('G9', $inv)) -WeightDecay $($wd.ToString('G9', $inv)) -MuonLr $($muonLr.ToString('G9', $inv)) -MuonMomentum $($muonMom.ToString('G9', $inv)) -MuonWeightDecay $($muonWd.ToString('G9', $inv)) -DesktopReserveGb $reserve -HeadlessReserveGb $reserve148 -Upsample $upsample -RetentionPatience $patience"
    if (-not $chkCompile.Checked) { $arg = $arg + ' -NoCompile' }
    if ($chkAct.Checked) { $arg = $arg + ' -ActivationCheckpoint' }
    if ($chkResume.Checked) { $arg = $arg + ' -Resume' }
    if (-not [string]::IsNullOrWhiteSpace($replay)) { $arg = $arg + " -ReplayFrom `"$replay`"" }
    Start-Process -FilePath $PowerShellExe -ArgumentList $arg -WindowStyle Hidden | Out-Null
    $lblStatus.Text = ("Start spawned for {0} steps. Refresh log to read the spawn lines." -f $steps)
    Start-Sleep -Seconds 1
    Update-Alfa45bLogView
})

$btnStop.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Stop the .45b torchrun processes on the four island hosts?',
        'ALFa Trainer .45b',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$IslandScript`" -Stop"
    Start-Process -FilePath $PowerShellExe -ArgumentList $arg -WindowStyle Hidden | Out-Null
    $lblStatus.Text = 'Stop spawned. Refresh log to read the stop lines.'
    Start-Sleep -Seconds 1
    Update-Alfa45bLogView
})

[void]$form.ShowDialog()
