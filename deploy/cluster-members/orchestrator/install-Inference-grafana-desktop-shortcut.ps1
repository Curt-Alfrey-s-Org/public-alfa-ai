#Requires -Version 5.1
<#
.SYNOPSIS
  Create a Desktop Internet Shortcut to the inference Grafana dashboard.

.DESCRIPTION
  Writes a .url Internet Shortcut (Microsoft):
  https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa767731(v=vs.85)
  Target is the provisioned Grafana dashboard on monitor (uid inference-inference).
  Docs: docs/inference_PERF_AND_SHARDS.md

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\install-inference-grafana-desktop-shortcut.ps1
#>
[CmdletBinding()]
param(
    [string] $ShortcutName = 'ALFa inference metrics',
    [string] $DashboardUrl = 'http://monitor/d/inference-inference/inference-inference'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$desktop = [Environment]::GetFolderPath('Desktop')
$urlPath = Join-Path $desktop ($ShortcutName + '.url')

# Internet Shortcut file format (ASCII). IconIndex 25 on shell32 is a chart-style glyph.
@(
    '[InternetShortcut]'
    ('URL=' + $DashboardUrl)
    'IconFile=%SystemRoot%\System32\shell32.dll'
    'IconIndex=25'
) | Set-Content -LiteralPath $urlPath -Encoding ASCII

Write-Host ("Desktop shortcut: {0}" -f $urlPath) -ForegroundColor Green
Write-Host ("Opens: {0}" -f $DashboardUrl) -ForegroundColor DarkGray
