#Requires -Version 5.1
<#
.SYNOPSIS
  Create Desktop shortcuts for ALFa inference models and 7B trainer menus on orchestrator.

.DESCRIPTION
  Uses WScript.Shell CreateShortcut (Microsoft WSH):
  https://learn.microsoft.com/en-us/troubleshoot/windows-client/admin-development/create-desktop-shortcut-with-wsh
  Installs ALFa Models.lnk (models-desktop-menu.ps1), ALFa Trainer 7B.lnk
  (train-desktop-menu.ps1), and ALFa Trainer .45b.lnk
  (train-45b-desktop-menu.ps1). Removes legacy ALFa Cluster Start-Stop.lnk and
  ALFa Trainer 14B.lnk if present.
  Also installs ALFa inference metrics.url (Grafana dashboard on monitor).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\install-cluster-desktop-shortcut.ps1
#>
[CmdletBinding()]
param(
    [string]$ModelsShortcutName = 'ALFa Models',
    [string]$TrainShortcutName = 'ALFa Trainer 7B',
    [string]$Train45bShortcutName = 'ALFa Trainer .45b'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ModelsScript = Join-Path $PSScriptRoot 'models-desktop-menu.ps1'
$TrainScript = Join-Path $PSScriptRoot 'train-desktop-menu.ps1'
$Train45bScript = Join-Path $PSScriptRoot 'train-45b-desktop-menu.ps1'
if (-not (Test-Path -LiteralPath $ModelsScript)) {
    throw "Missing models menu script: $ModelsScript"
}
if (-not (Test-Path -LiteralPath $TrainScript)) {
    throw "Missing train menu script: $TrainScript"
}
if (-not (Test-Path -LiteralPath $Train45bScript)) {
    throw "Missing .45b menu script: $Train45bScript"
}

function New-AlfaDesktopShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Icon
    )
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop ($Name + '.lnk')

    # Official: WScript.Shell CreateShortcut
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/admin-development/create-desktop-shortcut-with-wsh
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($lnkPath)
    $shortcut.TargetPath = 'powershell.exe'
    # -STA required for WinForms. Do not use -WindowStyle Hidden: spawning a console
    # child from a hidden host can fail with 0xc0000142 (STATUS_DLL_INIT_FAILED).
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$Script`""
    $shortcut.WorkingDirectory = $RepoDir
    $shortcut.Description = $Description
    $shortcut.IconLocation = $Icon
    $shortcut.Save()

    Write-Host "Desktop shortcut: $lnkPath" -ForegroundColor Green
}

$desktop = [Environment]::GetFolderPath('Desktop')
$legacyLnk = Join-Path $desktop 'ALFa Cluster Start-Stop.lnk'
if (Test-Path -LiteralPath $legacyLnk) {
    # Official: Remove-Item
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item
    Remove-Item -LiteralPath $legacyLnk -Force
    Write-Host "Removed legacy shortcut: $legacyLnk" -ForegroundColor Yellow
}

$legacyTrainLnk = Join-Path $desktop 'ALFa Trainer 14B.lnk'
if (Test-Path -LiteralPath $legacyTrainLnk) {
    Remove-Item -LiteralPath $legacyTrainLnk -Force
    Write-Host "Removed legacy shortcut: $legacyTrainLnk" -ForegroundColor Yellow
}

New-AlfaDesktopShortcut -Name $ModelsShortcutName -Script $ModelsScript `
    -Description 'ALFa inference models: pool radio, opt-in hosts, Start/Stop cluster' `
    -Icon 'shell32.dll,25'

New-AlfaDesktopShortcut -Name $TrainShortcutName -Script $TrainScript `
    -Description 'ALFa 7B QLoRA trainer: Start/Stop trainer, TensorBoard' `
    -Icon 'shell32.dll,21'

New-AlfaDesktopShortcut -Name $Train45bShortcutName -Script $Train45bScript `
    -Description 'ALFa .45b trainer: Start/Stop the four-rank pretrain' `
    -Icon 'shell32.dll,21'

Write-Host 'Double-click ALFa Models: pick pool/hosts, Stop or Start cluster.' -ForegroundColor DarkGray
Write-Host 'Double-click ALFa Trainer 7B: Start/Stop 7B QLoRA trainer, TensorBoard.' -ForegroundColor DarkGray
Write-Host 'Double-click ALFa Trainer .45b: Start/Stop the .45b pretrain. Opening it does not start.' -ForegroundColor DarkGray

$grafanaShortcut = Join-Path $PSScriptRoot 'install-inference-grafana-desktop-shortcut.ps1'
if (-not (Test-Path -LiteralPath $grafanaShortcut)) {
    throw "Missing Grafana shortcut script: $grafanaShortcut"
}
& $grafanaShortcut
