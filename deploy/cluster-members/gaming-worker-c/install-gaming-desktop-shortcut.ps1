#Requires -Version 5.1
<#
.SYNOPSIS
  Create a Desktop shortcut for ALFa gaming start/stop menu on gaming-c.

.DESCRIPTION
  Writes ALFa Gaming Mode.lnk on the current user's Desktop. Same pattern as
  operator-93 and gaming-worker-a-219. WScript.Shell CreateShortcut:
  https://learn.microsoft.com/en-us/previous-versions/aew9yb99(v=vs.80)
  Desktop folder: Environment.GetFolderPath
  https://learn.microsoft.com/en-us/dotnet/api/system.environment.getfolderpath

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\install-gaming-desktop-shortcut.ps1
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
Write-Host 'Double-click to open Start Gaming / Resume Shard menu.' -ForegroundColor Cyan
