#Requires -Version 5.1
<#
.SYNOPSIS
  Create a Desktop shortcut for ALFa gaming start/stop menu on orchestrator.
#>
[CmdletBinding()]
param(
    [string] $ShortcutName = 'ALFa Gaming Mode'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$MenuScript = Join-Path $PSScriptRoot 'gaming-desktop-menu.ps1'
if (-not (Test-Path -LiteralPath $MenuScript)) {
    throw "Missing menu script: $MenuScript"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($lnkPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MenuScript`""
$shortcut.WorkingDirectory = $RepoDir
$shortcut.Description = 'Stop inference shard for gaming; Done Gaming starts WSL only'
$shortcut.IconLocation = 'shell32.dll,174'
$shortcut.Save()

Write-Host "Desktop shortcut: $lnkPath" -ForegroundColor Green
