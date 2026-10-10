#Requires -Version 5.1
<#
.SYNOPSIS
    Mirror gaming-worker-b-249 / gaming-worker-c-59 / gaming-worker-a-219 folders to SMB (thin refresh).

.DESCRIPTION
    Copies only the three Win worker member directories from the orchestrator repo checkout
    to \\hub\temp\cluster_members\<member>\.

    Blackwell deploy.ps1 requires \\hub\temp\cluster_members\_common\repo\
    (deploy\ + scripts\ mirrored from orchestrator). That tree is created by running
    scripts\stage-cluster-members.ps1 from the repo root on orchestrator - NOT by this script.

    Use publish-host-folders-to-smb.ps1 only as a supplemental refresh after a
    full stage-cluster-members.ps1 run, or when you intentionally need member
    scripts updated without re-running the full staging payload.
.NOTES
    hub = hub hub SMB host (same hub as petals-wheels / huggingface).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = 'C:/Users/operator\alfa-ai'
$SrcBase  = Join-Path $RepoRoot 'deploy\cluster-members'
$DstBase  = '\\hub\temp\cluster_members'
$Hosts    = @('gaming-worker-b-249', 'gaming-worker-c-59', 'gaming-worker-a-219')

function Step([string]$msg) {
    Write-Host "== $msg ==" -ForegroundColor Cyan
}

function Ensure-Path([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        throw "$Label not found: $Path"
    }
}

Step 'Validate source + destination'
Ensure-Path $SrcBase 'Source cluster-members path'
Ensure-Path $DstBase 'SMB destination root'

foreach ($member in $Hosts) {
    $src = Join-Path $SrcBase $member
    $dst = Join-Path $DstBase $member
    Ensure-Path $src "Host source folder ($member)"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null

    Step "Publish $member -> $dst"
    # Mirror full folder so git-install, bootstrap, env/smoke, run-with-log are in sync.
    robocopy $src $dst /E /R:2 /W:2 /NFL /NDL /NP
    $rc = $LASTEXITCODE
    # robocopy return codes 0..7 are success-ish.
    if ($rc -gt 7) {
        throw "robocopy failed for $member (exit $rc)"
    }
}

Write-Host ''
Write-Host 'Publish complete.' -ForegroundColor Green
Write-Host 'If workers have not had a full SMB stage yet, run from repo root:'
Write-Host '  .\scripts\stage-cluster-members.ps1'
Write-Host 'Then on each worker (preferred): deploy.ps1 from UNC - see FIRST_RUN_WORKERS_FROM_93.md'
