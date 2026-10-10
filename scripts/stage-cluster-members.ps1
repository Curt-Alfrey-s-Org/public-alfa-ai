<#
.SYNOPSIS
    Stage per-member deploy folders to \\hub\temp\cluster_members\.
    Run on orchestrator (Win11 primary Dockge UI) after git pull.
.DESCRIPTION
    1. git pull in the local repo
    2. Copy deploy\cluster-members\* to \\hub\temp\cluster_members\
    3. Copy Docker image tarballs if present
    4. Copy Ollama installer cache if present

    After staging, each worker runs deploy.ps1 directly from UNC:
    \\hub\temp\cluster_members\<gaming-worker-b-249|gaming-worker-c-59|gaming-worker-a-219>\deploy.ps1
    That script mirrors _common\repo\deploy and _common\repo\scripts into
    C:\alfa-ai-worker for Docker/WSL (SMB stays the publication source).

    hub = hub hub. SMB share name temp must map to
    /mnt/HDDs/Alfa-AI/smb-scratch on the hub (NOT /mnt/HDDs/media/temp).
    See docs/CLUSTER_SHARED_STORAGE.md Windows nodes (SMB).

    publish-host-folders-to-smb.ps1 only refreshes the three member folders and
    does NOT populate _common\repo — operators must run THIS script for a full
    Blackwell worker deploy path.
.EXAMPLE
    cd C:/Users/operator\alfa-ai
    .\scripts\stage-cluster-members.ps1
.EXAMPLE
    .\scripts\stage-cluster-members.ps1 -SkipPull   # skip git pull
#>
param(
    [switch]$SkipPull,
    [string]$RepoDir = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) {
    $RepoDir = Split-Path -Parent $PSScriptRoot
}

$smbDest     = '\\hub\temp\cluster_members'
$clusterSrc  = Join-Path $RepoDir 'deploy\cluster-members'
# Dedicated SMB share on hub backed by /mnt/HDDs/Alfa-AI/docker-images/.
# deploy-worker-lan.ps1 reads directly from here via `docker load`, so the
# `_common\docker-images\` copy under staging is purely a fallback for
# offline workers that can't reach hub directly.
$hubImages   = '\\hub\docker-images'
$hubOllama   = '\\hub\temp\alfa-ai-cluster\installers\ollama'

Write-Host ''
Write-Host '== Stage Cluster Members to SMB ==' -ForegroundColor Cyan
Write-Host "  Repo:   $RepoDir"
Write-Host "  Dest:   $smbDest"
Write-Host ''

# --- 1. Git pull -------------------------------------------------------------
if (-not $SkipPull) {
    Write-Host '== 1. Git pull ==' -ForegroundColor Cyan
    Push-Location $RepoDir
    try {
        & git pull --ff-only origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'WARN: git pull failed. Resolve conflicts manually.' -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }
    Write-Host ''
}

# --- 2. Create SMB destination -----------------------------------------------
Write-Host '== 2. Creating SMB staging directory ==' -ForegroundColor Cyan
if (-not (Test-Path $smbDest)) {
    New-Item -ItemType Directory -Path $smbDest -Force | Out-Null
    Write-Host "  Created $smbDest"
} else {
    Write-Host "  $smbDest already exists"
}

# --- 3. Copy per-member folders + _common ------------------------------------
Write-Host ''
Write-Host '== 3. Copying per-member folders ==' -ForegroundColor Cyan

if (-not (Test-Path $clusterSrc)) {
    Write-Host "FAIL: $clusterSrc not found in repo." -ForegroundColor Red
    exit 1
}

$folders = Get-ChildItem -Path $clusterSrc -Directory
foreach ($folder in $folders) {
    $destFolder = Join-Path $smbDest $folder.Name
    if (-not (Test-Path $destFolder)) {
        New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
    }
    Copy-Item -Path "$($folder.FullName)\*" -Destination $destFolder -Recurse -Force
    Write-Host "  $($folder.Name) -> $destFolder"
}

# --- 4. Mirror repo subset to _common\repo\ ---------------------------------
# LAN-first builds on gaming-b/gaming-c/gaming-a need deploy/ + scripts/ trees.
Write-Host ''
Write-Host '== 4. Mirroring repo subset (deploy\, scripts\) to _common\repo\ ==' -ForegroundColor Cyan

$commonRepoDir = Join-Path $smbDest '_common\repo'
if (-not (Test-Path $commonRepoDir)) {
    New-Item -ItemType Directory -Path $commonRepoDir -Force | Out-Null
}

foreach ($sub in @('deploy','scripts')) {
    $src = Join-Path $RepoDir $sub
    $dst = Join-Path $commonRepoDir $sub
    if (-not (Test-Path $src)) {
        Write-Host "  SKIP: $src missing in repo" -ForegroundColor Yellow
        continue
    }
    Write-Host "  robocopy $sub\ -> $dst\"
    # /MIR mirrors (deletes stale). /XD excludes dirs we don't want on SMB
    # (worker-local venvs, local logs, empty wheel hubs -- those are synced
    # at worker runtime from \\hub\petals-wheels directly).
    & robocopy $src $dst /MIR /R:2 /W:2 /NP /NDL /NJH /NJS /MT:8 `
        /XD node_modules __pycache__ .venv venv logs `
        | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy $sub failed (exit $LASTEXITCODE)"
    }
}

# --- 5. Copy Docker image tarballs (if apps has exported them) ----------------
Write-Host ''
Write-Host '== 5. Docker images ==' -ForegroundColor Cyan

$commonDockerImages = Join-Path $smbDest '_common\docker-images'
if (-not (Test-Path $commonDockerImages)) {
    New-Item -ItemType Directory -Path $commonDockerImages -Force | Out-Null
}

if (Test-Path $hubImages) {
    $tarballs = Get-ChildItem -Path $hubImages -Filter '*.tar.gz' -ErrorAction SilentlyContinue
    if ($tarballs) {
        foreach ($tb in $tarballs) {
            try {
                Copy-Item -Force $tb.FullName $commonDockerImages -ErrorAction Stop
                Write-Host "  $($tb.Name)"
            }
            catch {
                # Pascal / other images may be root-owned on hub; gaming workers
                # only need cuda128. Do not abort the whole stage on one ACL miss.
                Write-Host ("  WARN: skip {0}: {1}" -f $tb.Name, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        $manifest = Join-Path $hubImages 'images.json'
        if (Test-Path $manifest) {
            try {
                Copy-Item -Force $manifest $commonDockerImages -ErrorAction Stop
                Write-Host '  images.json'
            }
            catch {
                Write-Host ("  WARN: skip images.json: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        $cuda128 = Join-Path $commonDockerImages 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
        if (-not (Test-Path -LiteralPath $cuda128)) {
            Write-Host '  WARN: cuda128 tarball missing from staging fallback (workers can still read \\hub\docker-images\)' -ForegroundColor Yellow
        }
        else {
            Write-Host '  OK: cuda128 tarball in staging (gaming gaming-c/gaming-a/gaming-b)' -ForegroundColor Green
        }
    } else {
        Write-Host '  No tarballs found in hub' -ForegroundColor Yellow
    }
} else {
    Write-Host "  Hub images dir not found: $hubImages" -ForegroundColor Yellow
    Write-Host '  Run export_docker_images.sh on apps first' -ForegroundColor Yellow
}

# --- 6. Copy Ollama installer cache ------------------------------------------
Write-Host ''
Write-Host '== 6. Ollama installer ==' -ForegroundColor Cyan

$commonOllama = Join-Path $smbDest '_common\installers\ollama'
if (-not (Test-Path $commonOllama)) {
    New-Item -ItemType Directory -Path $commonOllama -Force | Out-Null
}

if (Test-Path $hubOllama) {
    Copy-Item -Path "$hubOllama\*" -Destination $commonOllama -Force -ErrorAction SilentlyContinue
    Write-Host '  Ollama installer cached'
} else {
    Write-Host "  Hub Ollama dir not found: $hubOllama" -ForegroundColor Yellow
}

# --- Summary ------------------------------------------------------------------
Write-Host ''
Write-Host '== Staging Complete ==' -ForegroundColor Green
Write-Host ''
Write-Host 'Staged to:' -ForegroundColor Cyan
Write-Host "  $smbDest"
Write-Host ''
Write-Host 'Each Win worker (gaming-worker-b, gaming-worker-c, gaming-worker-a):' -ForegroundColor Cyan
Write-Host '  Run directly from SMB (picks up _common\deploy-worker-lan.ps1 and _common\repo\):'
Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\<name>\deploy.ps1'
Write-Host '  (deploy.ps1 robocopies _common\repo\deploy and _common\repo\scripts into C:\alfa-ai-worker,'
Write-Host '   then delegates to _common\deploy-worker-lan.ps1 for LAN-first build + compose up.)'
Write-Host ''

$memberFolders = $folders | Where-Object { $_.Name -ne '_common' -and $_.Name -ne 'operator-93' -and $_.Name -ne 'hub-111' }
Write-Host 'Win workers:' -ForegroundColor Cyan
foreach ($folder in $memberFolders) {
    Write-Host "  $($folder.Name)"
}
Write-Host ''
Write-Host 'Win11 primary Dockge (orchestrator, operator-93):' -ForegroundColor Cyan
Write-Host '  Run directly from repo: .\deploy\cluster-members\orchestrator\deploy.ps1'
Write-Host ''
Write-Host 'hub brain + hub (hub, hub-111):' -ForegroundColor Cyan
Write-Host '  Run via SSH: sudo bash deploy/cluster-members/hub/deploy.sh'
Write-Host ''
