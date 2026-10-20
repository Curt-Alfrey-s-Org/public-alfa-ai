# orchestrator - post-startup status (WSL) + SCP to inference hub.
#   powershell -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\run-post-startup-status-with-log.ps1
param([switch]$NoScp)
$here = $PSScriptRoot
& (Join-Path $here '..\_common\run-post-startup-status-with-log.ps1') -HostProfile operator-93 @PSBoundParameters
exit $LASTEXITCODE
