#Requires -Version 5.1
<#
.SYNOPSIS
    Optional live error-only tail windows during cluster start/stop.

.DESCRIPTION
    Error capture runs automatically inside Start-Stop-AlfaAi.ps1. Use this only
    if you want live error lines in separate windows during the cycle.
    Pushes recorder scripts to inference via git pull or scp before tailing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Tail-AlfaClusterHostLogs.ps1 -SessionId 20260702-120000-start
#>
[CmdletBinding()]
param(
    [string]$SessionId,
    [switch]$OrchestratorOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$MemberDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $MemberDir '..\..\..')).Path
$OrchestratorTail = Join-Path $MemberDir 'Tail-AlfaClusterLog.ps1'
$Ssh148 = 'operator@orchestrator'
$Repo148 = '/home/operator/alfa-ai'

. (Join-Path $MemberDir 'inference-LogSession.ps1')

if (-not $SessionId) {
    $SessionId = Get-inferenceLogSessionId -RepoRoot $RepoRoot
}
if (-not $SessionId) {
    Write-Host 'No active session. Run Start-Stop-AlfaAi.ps1 first, or pass -SessionId.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host "inference live error tail session: $SessionId" -ForegroundColor Magenta
Write-Host '(background recorders already run from Start-Stop-AlfaAi.ps1)' -ForegroundColor DarkGray
Write-Host ''

function Start-AlfaTailWindow {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Command
    )
    Write-Host "Launching: $Title" -ForegroundColor Cyan
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
        '-Command', $Command
    ) | Out-Null
}

function Get-inferenceRemoteTailShell {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$RemoteRepo,
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$SessionId
    )
    $repo = Resolve-inferenceRemoteRepo -RemoteRepo $RemoteRepo -SshTarget $SshTarget
    $recordScript = Join-inferenceRemoteScript -RepoBase $repo -RelativePath 'deploy/cluster-members/_common/record-inference-host-logs.sh'
    # No single quotes inside remoteBash: child powershell wraps it in '...' for ssh.
    # SessionId / HostLabel are controlled (digits, hyphen).
    $recordCmd = "inference_LOG_SESSION_ID=$SessionId HOST_LABEL=$HostLabel TEE_LOG=1 SCP_TO_93=0 bash $recordScript"
    $remoteBash = "if test -f $recordScript; then $recordCmd; else echo ERROR: record script missing on .$HostLabel - re-run Tail after Start-Stop syncs scripts; sleep 86400; fi"
    return @"
`$ErrorActionPreference = 'Continue'
`$Host.UI.RawUI.WindowTitle = 'ALFa .$HostLabel errors'
Write-Host 'inference error tail .$HostLabel (Ctrl+C to stop)' -ForegroundColor Cyan
ssh -o BatchMode=yes $SshTarget '$remoteBash'
Write-Host ''
Write-Host "ssh exit: `$LASTEXITCODE" -ForegroundColor DarkGray
Read-Host 'Press Enter to close'
"@
}

Start-AlfaTailWindow -Title 'orchestrator orchestrator errors' -Command @"
`$ErrorActionPreference = 'Continue'
`$Host.UI.RawUI.WindowTitle = 'ALFa orchestrator orchestrator errors'
Set-Location '$RepoRoot'
& '$OrchestratorTail'
"@

if (-not $OrchestratorOnly) {
    $null = Sync-inferenceLogScriptsRemote -SshTarget $Ssh148 -RemoteRepo $Repo148 `
        -LocalRepoRoot $RepoRoot -HostLabel '148'

    $driveLetter = $RepoRoot.Substring(0, 1).ToLower()
    $wslRest = $RepoRoot.Substring(3).Replace('\', '/')
    $wslRecord = "/mnt/$driveLetter/$wslRest/deploy/cluster-members/_common/record-inference-host-logs.sh"
    # Test-Path is Windows - check the Windows path, not the WSL /mnt/... path.
    $winRecord = Join-Path $RepoRoot 'deploy\cluster-members\_common\record-inference-host-logs.sh'

    Start-AlfaTailWindow -Title 'orchestrator WSL shard errors' -Command @"
`$ErrorActionPreference = 'Continue'
`$Host.UI.RawUI.WindowTitle = 'ALFa orchestrator WSL errors'
if (Test-Path -LiteralPath '$winRecord' -ErrorAction SilentlyContinue) {
  wsl.exe -d Ubuntu bash -lc "inference_LOG_SESSION_ID='$SessionId' HOST_LABEL=93 TEE_LOG=1 SCP_TO_93=0 bash '$wslRecord'"
} else {
  Write-Host 'ERROR: local record script missing - git pull on orchestrator' -ForegroundColor Red
}
Read-Host 'Press Enter to close'
"@

    Start-AlfaTailWindow -Title 'inference errors' -Command (Get-inferenceRemoteTailShell `
        -SshTarget $Ssh148 -RemoteRepo $Repo148 -HostLabel '148' -SessionId $SessionId)
}

Write-Host ''
Write-Host 'Ctrl+C each window when done. Errors also collected at CLUSTER COMPLETE.' -ForegroundColor DarkGray
Write-Host ''