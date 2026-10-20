<#
.SYNOPSIS
    One-shot bootstrap for any ALFa AI Windows worker.
    Ensures git is installed, clones alfa-ai if not already a git repo at
    $RepoRoot, pulls latest, and runs the member's deploy.
.DESCRIPTION
    Use this the FIRST time you bring up a worker, or any time you need
    to re-bootstrap from a clean slate. It is safe to run repeatedly.
    Later runs just do `git pull` + deploy via run.ps1.

    The script is designed to be invoked from anywhere -- a local copy,
    the SMB staging area, or a UNC path -- so a freshly-built Windows
    box needs only this single command to come online:

        powershell -ExecutionPolicy Bypass -File \\
            \\hub\temp\cluster_members\_common\repo\scripts\bootstrap-worker.ps1 \\
            -Member gaming-worker-b-249

.PARAMETER Member
    One of: gaming-worker-b-249, gaming-worker-c-59, gaming-worker-a-219, operator-93.
.PARAMETER RepoRoot
    Where to clone/maintain the alfa-ai checkout. Default C:\alfa-ai.
.PARAMETER RepoUrl
    Git URL of the alfa-ai repository. Default is the public HTTPS URL
    (no SSH key required on the worker).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('gaming-worker-b-249','gaming-worker-c-59','gaming-worker-a-219','operator-93')]
    [string]$Member,

    [string]$RepoRoot = 'C:\alfa-ai',
    [string]$RepoUrl  = 'https://github.com/example/alfa-ai.git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host "== ALFa AI worker bootstrap: $Member ==" -ForegroundColor Cyan
Write-Host "  RepoRoot: $RepoRoot"
Write-Host "  RepoUrl:  $RepoUrl"
Write-Host ''

# --- 1. Self-healing environment readiness --------------------------------
# If this bootstrap was launched via SMB/UNC (the usual first-run case) the
# _common\ensure-worker-environment.ps1 helper lives NEXT TO us on the SMB
# staging tree. Use whichever copy is closest.
$envScriptCandidates = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy\cluster-members\_common\ensure-worker-environment.ps1'),
    (Join-Path $PSScriptRoot '..\deploy\cluster-members\_common\ensure-worker-environment.ps1')
)
$envScript = $envScriptCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($envScript) {
    . $envScript
    # Docker is not needed just to clone; probe only git + hub here so the
    # clone step does not block for 60-180s if Docker Desktop is slow to
    # start. run.ps1 will invoke the full env readiness (including Docker)
    # after the clone/pull.
    Ensure-AlfaWorkerEnvironment -SkipDocker
} else {
    # No helper nearby (highly unusual -- running a manually-downloaded
    # bootstrap). Best-effort git install.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw '[bootstrap] git missing and winget unavailable. Install git from https://git-scm.com/download/win and retry.'
        }
        Write-Host '[bootstrap] installing git via winget...' -ForegroundColor Yellow
        & winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        # Refresh PATH for this session
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw '[bootstrap] git installed but not on PATH -- close and reopen PowerShell, then retry.'
        }
    }
}

# --- 2. Clone if missing, else sanity-check -------------------------------
$gitDir = Join-Path $RepoRoot '.git'
if (-not (Test-Path $gitDir)) {
    if (Test-Path $RepoRoot) {
        Write-Host "[bootstrap] $RepoRoot exists but is not a git repo." -ForegroundColor Red
        Write-Host '  Either remove it or pick a different -RepoRoot.' -ForegroundColor Yellow
        Write-Host "  Example: powershell ... bootstrap-worker.ps1 -Member $Member -RepoRoot C:\alfa-ai2" -ForegroundColor Yellow
        throw "[bootstrap] non-git directory present at $RepoRoot -- refusing to overwrite."
    }
    Write-Host "[bootstrap] cloning $RepoUrl -> $RepoRoot" -ForegroundColor Cyan
    & git clone $RepoUrl $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "[bootstrap] git clone failed (exit $LASTEXITCODE)."
    }
    Write-Host '[bootstrap] clone complete' -ForegroundColor Green
} else {
    Write-Host "[bootstrap] existing git clone at $RepoRoot -- will let run.ps1 pull." -ForegroundColor Green
}
Write-Host ''

# --- 3. Hand off to the member's run.ps1 ----------------------------------
$runScript = Join-Path $RepoRoot "deploy\cluster-members\$Member\run.ps1"
if (-not (Test-Path $runScript)) {
    throw "[bootstrap] expected entry point not found: $runScript (is $Member a valid member folder?)"
}

Write-Host "[bootstrap] handing off to $runScript" -ForegroundColor Cyan
Write-Host ''
& $runScript
