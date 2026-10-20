#Requires -Version 5.1
$desk = [Environment]::GetFolderPath('Desktop')
$icon = Join-Path $PSScriptRoot 'lact-icon.png'
$script = Join-Path $PSScriptRoot 'Launch-LactGui.ps1'
if (-not (Test-Path $icon)) {
    throw "Missing icon: $icon"
}
if (-not (Test-Path $script)) {
    throw "Missing launcher: $script"
}

$wsh = New-Object -ComObject WScript.Shell

$lnk148 = $wsh.CreateShortcut((Join-Path $desk 'LACT GPU (inference).lnk'))
$lnk148.TargetPath = 'powershell.exe'
$lnk148.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$lnk148.WorkingDirectory = 'C:/Users/operator\alfa-ai'
$lnk148.IconLocation = "$icon,0"
$lnk148.Description = 'LACT remote GUI - RTX 5060 + 3060 on ai-148'
$lnk148.Save()

$lnk100 = $wsh.CreateShortcut((Join-Path $desk 'LACT GPU (pool-opt-in).lnk'))
$lnk100.TargetPath = 'powershell.exe'
$lnk100.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -TcpHost orchestrator"
$lnk100.WorkingDirectory = 'C:/Users/operator\alfa-ai'
$lnk100.IconLocation = "$icon,0"
$lnk100.Description = 'LACT remote GUI - GTX 1660 Super on ALFA-AI pool-opt-in'
$lnk100.Save()

Write-Host "OK: $(Join-Path $desk 'LACT GPU (inference).lnk')"
Write-Host "OK: $(Join-Path $desk 'LACT GPU (pool-opt-in).lnk')"
