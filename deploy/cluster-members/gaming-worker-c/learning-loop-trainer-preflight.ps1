#Requires -Version 5.1
<#
.SYNOPSIS
  Preflight alfa-train on gaming-c for learning-loop L3 (Tier B).

.DESCRIPTION
  Operator steps for gaming-worker-c (gaming-c). Does not start inference or train automatically.
  Clone/pull alfa-train, verify hub pack path, document ingest command.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\learning-loop-trainer-preflight.ps1
#>
$ErrorActionPreference = "Stop"

$TrainRoot = "C:\alfa-ai-train"
$HubPackGlob = "\\hub\training\alfa-train\datasets\from-alfa-ai\*"
$HubPackLinux = "/mnt/HDDs/Alfa-AI/training/alfa-train/datasets/from-alfa-ai"

Write-Host "== learning-loop trainer preflight (gaming-c) =="
Write-Host "train_root=$TrainRoot"
Write-Host "hub_hint_linux=$HubPackLinux"

if (-not (Test-Path -LiteralPath $TrainRoot)) {
  Write-Host "MISSING clone: git clone alfa-train to $TrainRoot"
  Write-Host "  git clone https://github.com/example/alfa-train.git $TrainRoot"
  exit 2
}

Push-Location $TrainRoot
try {
  git fetch origin 2>&1 | Write-Host
  git status -sb 2>&1 | Write-Host
  if (Test-Path -LiteralPath ".\scripts\ingest_alfa_ai_pack.py") {
    Write-Host "OK ingest_alfa_ai_pack.py present"
  } else {
    Write-Host "MISSING scripts\ingest_alfa_ai_pack.py in alfa-train"
    exit 2
  }
} finally {
  Pop-Location
}

$packs = @()
if (Test-Path -LiteralPath "\\hub\training") {
  $packs = Get-ChildItem -Path $HubPackGlob -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 3
}
if ($packs.Count -gt 0) {
  Write-Host "OK hub packs (SMB):"
  $packs | ForEach-Object { Write-Host "  $($_.FullName)" }
} else {
  Write-Host "WARN no hub packs via SMB yet. Publish from hub:"
  Write-Host "  bash scripts/publish_train_pack_to_hub.sh"
}

Write-Host ""
Write-Host "Next (when GPU idle):"
Write-Host "  cd $TrainRoot"
Write-Host "  python scripts\ingest_alfa_ai_pack.py --pack <hub-pack-dir> --merge-into data"
Write-Host "  # then pool-7b-qlora-sft per alfa-train GETTING_STARTED"
