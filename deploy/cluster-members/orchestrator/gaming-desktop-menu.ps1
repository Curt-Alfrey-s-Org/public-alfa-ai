#Requires -Version 5.1
<#
.SYNOPSIS
  Desktop menu: stop pool shard for gaming, or resume shard after gaming (orchestrator).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$StopScript = Join-Path $PSScriptRoot 'gaming-stop-for-session.ps1'
$ResumeScript = Join-Path $PSScriptRoot 'gaming-resume-pool-shard.ps1'

function Invoke-AlfaGamingScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$ExtraArgs = ''
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Script not found:`n$ScriptPath`n`nRun git pull in $RepoDir",
            'ALFa Gaming Mode',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    $argList = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$ScriptPath`" $ExtraArgs"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $RepoDir
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ALFa operator-93 Gaming'
$form.Size = New-Object System.Drawing.Size(420, 260)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(20, 15)
$label.Size = New-Object System.Drawing.Size(370, 50)
$label.Text = "Stop the inference shard and free GPU/RAM before gaming.`nDone Gaming starts WSL only. Shard returns at next cluster Start."
$form.Controls.Add($label)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Location = New-Object System.Drawing.Point(20, 80)
$btnStart.Size = New-Object System.Drawing.Size(360, 40)
$btnStart.Text = 'Start Gaming (stop shard + shutdown WSL)'
$btnStart.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Stop inference shard on this PC and shut down WSL?`n`nPool on hub may error until you resume.",
        'Start Gaming',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-AlfaGamingScript -ScriptPath $StopScript -ExtraArgs '-ShutdownWsl'
    }
})
$form.Controls.Add($btnStart)

$btnResume = New-Object System.Windows.Forms.Button
$btnResume.Location = New-Object System.Drawing.Point(20, 130)
$btnResume.Size = New-Object System.Drawing.Size(360, 40)
$btnResume.Text = 'Done Gaming (start WSL; shard at next cluster Start)'
$btnResume.Add_Click({
    Invoke-AlfaGamingScript -ScriptPath $ResumeScript
})
$form.Controls.Add($btnResume)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Location = New-Object System.Drawing.Point(20, 180)
$btnClose.Size = New-Object System.Drawing.Size(360, 30)
$btnClose.Text = 'Close'
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

[void]$form.ShowDialog()
