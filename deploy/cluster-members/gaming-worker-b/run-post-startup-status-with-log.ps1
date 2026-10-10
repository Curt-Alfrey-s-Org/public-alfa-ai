# gaming-b gaming-worker-b - post-startup status + SCP to inference hub.
param([switch]$NoScp)
$here = $PSScriptRoot
& (Join-Path $here '..\_common\run-post-startup-status-with-log.ps1') -HostProfile gaming-worker-b-249 @PSBoundParameters
exit $LASTEXITCODE
