<#
.SYNOPSIS
    REFERENCE TEMPLATE -- not sourced at runtime.
    Each per-member deploy.ps1 has this logic inlined and is fully self-contained.
.DESCRIPTION
    This file is the canonical reference for common Windows worker deploy logic.
    When making a common fix, update this template, then apply the same change
    to each member's deploy.ps1 (gaming-worker-b-249, gaming-worker-c-59, gaming-worker-a-219).
    Shared helpers live alongside this file: nvidia-preflight.ps1,
    configure-docker-mirror.ps1, write-system-stats.ps1 (hardware report).

    Variables each member sets at the top of its deploy.ps1:
        $MachineName   e.g. 'gaming-worker-b', 'gaming-worker-c', 'gaming-worker-a'
        $MachineIP     e.g. 'orchestrator'
        $WorkerDir     e.g. 'C:\alfa-ai-worker'

    Flow:
        1. Copy files from SMB staging to local WorkerDir
        2. Load pre-built Docker images (skips if already present)
        3. Detect GPU architecture (Blackwell vs standard)
        4. Clean up old CPU worker if present
        5. Docker compose up with the correct compose file
        6. Install Ollama from cached installer if not present
        7. Print status

    hub = hub hub. The SMB share \\hub\temp\ is hosted
    on hub, the same machine as the NFS hub.
#>

# --- Guard: caller must set required vars ------------------------------------
foreach ($var in @('MachineName', 'MachineIP', 'WorkerDir')) {
    if (-not (Get-Variable -Name $var -ValueOnly -ErrorAction SilentlyContinue)) {
        Write-Host "FAIL: `$$var not set. This script must be dot-sourced from a per-member deploy.ps1." -ForegroundColor Red
        exit 1
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Preflight: single source of truth for GPU + LAN registry mirror ---------
# Every worker deploy.ps1 inlines this block, right after the identity section,
# so hardware facts come from nvidia-smi (never docs) and Docker pulls come
# from the LAN registry mirror on hub instead of Docker Hub.
$CommonDir = $PSScriptRoot
$preflightScript = Join-Path $CommonDir 'nvidia-preflight.ps1'
$mirrorScript    = Join-Path $CommonDir 'configure-docker-mirror.ps1'
if (Test-Path $preflightScript) {
    . $preflightScript
    Invoke-AlfaNvidiaPreflight -Role 'gpu-worker' | Out-Null
}
if (Test-Path $mirrorScript) {
    . $mirrorScript
    Configure-AlfaDockerMirror -MirrorUrl 'http://hub'
}

$smbRoot        = '\\hub\temp\cluster_members'
$smbCommon      = Join-Path $smbRoot '_common'
$smbMember      = Join-Path $smbRoot "$MachineName-*"
$smbWorkerFiles = Join-Path $smbCommon 'worker-files'
$smbDockerImg   = Join-Path $smbCommon 'docker-images'
$smbOllama      = Join-Path $smbCommon 'installers\ollama'

Write-Host ''
Write-Host "== ALFa AI Cluster Deploy: $MachineName ($MachineIP) ==" -ForegroundColor Cyan
Write-Host "  WorkerDir: $WorkerDir"
Write-Host "  SMB root:  $smbRoot"
Write-Host ''

# --- 1. Copy from SMB to local WorkerDir ------------------------------------
Write-Host '== 1. Syncing files from SMB to local ==' -ForegroundColor Cyan

if (-not (Test-Path $WorkerDir)) {
    New-Item -ItemType Directory -Path $WorkerDir -Force | Out-Null
    Write-Host "  Created $WorkerDir"
}

$workerFilesLocal = Join-Path $WorkerDir 'worker-files'
if (-not (Test-Path $workerFilesLocal)) {
    New-Item -ItemType Directory -Path $workerFilesLocal -Force | Out-Null
}

if (Test-Path $smbWorkerFiles) {
    Copy-Item -Path "$smbWorkerFiles\*" -Destination $workerFilesLocal -Recurse -Force
    Write-Host "  worker-files synced from SMB"
} else {
    Write-Host "  WARN: $smbWorkerFiles not found on SMB" -ForegroundColor Yellow
}

$memberEnv = Join-Path $PSScriptRoot '.env.worker'
if (Test-Path $memberEnv) {
    Copy-Item -Force $memberEnv (Join-Path $workerFilesLocal '.env.worker')
    Write-Host "  .env.worker copied for $MachineName"
} else {
    Write-Host "  WARN: No .env.worker in member folder; using existing" -ForegroundColor Yellow
}

# --- 2. Load Docker images --------------------------------------------------
Write-Host ''
Write-Host '== 2. Loading pre-built Docker images ==' -ForegroundColor Cyan

if (Test-Path $smbDockerImg) {
    $tarballs = Get-ChildItem -Path $smbDockerImg -Filter '*.tar.gz' -ErrorAction SilentlyContinue
    if ($tarballs) {
        foreach ($tb in $tarballs) {
            Write-Host "  Loading $($tb.Name) ..."
            & docker load -i $tb.FullName 2>&1 | Select-Object -Last 1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  WARN: Failed to load $($tb.Name)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  No image tarballs found in $smbDockerImg" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Docker images dir not found on SMB; will build from source if needed" -ForegroundColor Yellow
}

# --- 3. Detect GPU architecture ----------------------------------------------
Write-Host ''
Write-Host '== 3. Detecting GPU architecture ==' -ForegroundColor Cyan

$computeCap = $null
try {
    $raw = & docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 `
        nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $computeCap = ($raw | Select-Object -First 1).ToString().Trim()
    }
} catch {
    Write-Host '  Could not query compute capability' -ForegroundColor Yellow
}

$useBlackwell = $false
if ($computeCap) {
    Write-Host "  Compute capability: $computeCap"
    $major = [int]($computeCap.Split('.')[0])
    if ($major -ge 12) {
        $useBlackwell = $true
        Write-Host '  Blackwell (sm_120+) -> CUDA 12.8 + torch cu128' -ForegroundColor Green
    } else {
        Write-Host '  Pre-Blackwell -> standard CUDA 12.4 + torch cu121' -ForegroundColor Green
    }
} else {
    Write-Host '  Unknown; defaulting to standard image' -ForegroundColor Yellow
}

# Preflight already picked the correct variant via nvidia-smi. Prefer it over
# the (now redundant) inline detection above; fall back for pre-helper nodes.
$composeFile = if ($env:ALFA_NODE_PETALS_COMPOSE) {
    Split-Path -Leaf $env:ALFA_NODE_PETALS_COMPOSE
} elseif ($useBlackwell) {
    'docker-compose.worker.blackwell.yml'
} else {
    'docker-compose.worker.yml'
}
$composePath = Join-Path $workerFilesLocal $composeFile

if (-not (Test-Path $composePath)) {
    Write-Host "FAIL: $composePath not found." -ForegroundColor Red
    exit 1
}

# --- 4. Clean up old CPU worker ----------------------------------------------
Write-Host ''
Write-Host '== 4. Cleaning up old CPU worker (if any) ==' -ForegroundColor Cyan

$oldContainer = & docker ps -aq -f "name=petals-worker-cpu" 2>&1
if ($oldContainer) {
    & docker rm -f petals-worker-cpu 2>&1 | Out-Null
    Write-Host '  Removed container petals-worker-cpu' -ForegroundColor Green
}

# --- 5. Docker compose up ---------------------------------------------------
Write-Host ''
Write-Host "== 5. Starting worker ($composeFile) ==" -ForegroundColor Cyan

$envFile = Join-Path $workerFilesLocal '.env.worker'
if (-not (Test-Path $envFile)) {
    Write-Host "FAIL: $envFile not found. Ensure .env.worker is in the member folder." -ForegroundColor Red
    exit 1
}

$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Write-Host "  C: drive free: ${freeGB} GB"
if ($freeGB -lt 25) {
    Write-Host '  WARNING: Less than 25 GB free. Build may fail.' -ForegroundColor Yellow
    Write-Host '  Free space: docker system prune -a' -ForegroundColor Yellow
}

Push-Location $workerFilesLocal
try {
    & docker compose --env-file .env.worker -f $composeFile build
    if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }

    & docker compose --env-file .env.worker -f $composeFile up -d
    if ($LASTEXITCODE -ne 0) { throw "Start failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# --- 6. Ollama setup ---------------------------------------------------------
Write-Host ''
Write-Host '== 6. Ollama setup ==' -ForegroundColor Cyan

$ollamaInstalled = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaInstalled) {
    Write-Host "  Ollama already installed"
} else {
    $cachedInstaller = Join-Path $smbOllama 'install.sh'
    $ollamaExe = Join-Path $smbOllama 'OllamaSetup.exe'
    if (Test-Path $ollamaExe) {
        Write-Host "  Installing Ollama from cached .exe ..."
        Start-Process -FilePath $ollamaExe -ArgumentList '/SILENT' -Wait
    } elseif (Test-Path $cachedInstaller) {
        Write-Host "  Ollama install.sh found (Linux). For Windows, download from https://ollama.com/download/windows"
    } else {
        Write-Host "  Ollama not found in cache. Download from https://ollama.com/download/windows" -ForegroundColor Yellow
    }
}

$smbOllamaModels = Join-Path (Split-Path $smbCommon) 'models\ollama'
if (Test-Path $smbOllamaModels -ErrorAction SilentlyContinue) {
    Write-Host "  Shared Ollama models available at: $smbOllamaModels"
    Write-Host "  Copy to local: Copy-Item -Recurse '$smbOllamaModels\*' `"`$HOME\.ollama\models\`""
}

# --- 7. Status ---------------------------------------------------------------
Write-Host ''
Write-Host '== Deploy Complete ==' -ForegroundColor Green
Write-Host ''
Write-Host "  Machine:  $MachineName ($MachineIP)"
Write-Host "  Compose:  $composeFile"
Write-Host "  Worker:   $workerFilesLocal"
Write-Host ''
Write-Host 'Logs: docker logs -f petals-worker' -ForegroundColor Cyan
Write-Host ''
