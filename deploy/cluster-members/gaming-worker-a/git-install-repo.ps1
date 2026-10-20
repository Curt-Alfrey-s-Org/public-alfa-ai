#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoUrl    = 'https://github.com/example/alfa-ai.git'
$RepoBranch = 'main'
$RepoRoot   = 'C:\alfa-ai-worker'
$NextScript = 'C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\run-aria2-bootstrap-with-log.ps1'

function Step([string]$msg) {
    Write-Host "== $msg ==" -ForegroundColor Cyan
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-GitCli {
    cmd /c 'git --version >nul 2>nul'
    return ($LASTEXITCODE -eq 0)
}

function Install-GitIfMissing {
    if (Test-GitCli) { return }

    Step 'Git missing; attempting install'
    if (Test-Command 'winget') {
        & winget install -e --id Git.Git --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "winget install Git.Git failed (exit $LASTEXITCODE)." }
    } elseif (Test-Command 'choco') {
        & choco install git -y
        if ($LASTEXITCODE -ne 0) { throw "choco install git failed (exit $LASTEXITCODE)." }
    } else {
        throw 'Git CLI not found and neither winget nor choco is available. Install Git manually, then rerun.'
    }

    if (-not (Test-GitCli)) {
        throw 'Git CLI still unavailable after install. Open a new PowerShell session and rerun.'
    }
}

function Ensure-Repo {
    Step 'Ensure repo checkout'

    if (Test-Path (Join-Path $RepoRoot '.git')) {
        & git -C $RepoRoot fetch origin $RepoBranch
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed in $RepoRoot" }
        & git -C $RepoRoot pull --ff-only origin $RepoBranch
        if ($LASTEXITCODE -ne 0) { throw "git pull failed in $RepoRoot" }
        return
    }

    if (Test-Path $RepoRoot) {
        $entries = Get-ChildItem -Force -Path $RepoRoot -ErrorAction SilentlyContinue
        if ($entries.Count -gt 0) {
            throw "Repo target exists but is not a git repo: $RepoRoot. Move/clear it, then rerun."
        }
    } else {
        New-Item -ItemType Directory -Force -Path $RepoRoot | Out-Null
    }

    & git clone --branch $RepoBranch --single-branch $RepoUrl $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "git clone failed: $RepoUrl -> $RepoRoot" }
}

Step 'First-run repo setup for gaming-worker-a-219'
Install-GitIfMissing
Ensure-Repo

Write-Host ''
Write-Host 'Repo setup complete.' -ForegroundColor Green
Write-Host "Next: powershell -ExecutionPolicy Bypass -File $NextScript"
