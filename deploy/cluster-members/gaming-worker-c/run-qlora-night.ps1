#Requires -Version 5.1
<#
.SYNOPSIS
  Run OP-LL-3 7B QLoRA night on gaming-c (operator-owned, GPU must be idle).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\run-qlora-night.ps1 -PackDir \\hub\training\alfa-train\datasets\from-alfa-ai\20260714T120000Z
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$PackDir,
  [string]$TrainRoot = "C:\alfa-ai-train"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $TrainRoot)) {
  throw "alfa-train missing at $TrainRoot"
}
if (-not (Test-Path -LiteralPath $PackDir)) {
  throw "Pack not found: $PackDir"
}

Write-Host "== OP-LL-3 QLoRA night (gaming-c) =="
Write-Host "pack=$PackDir"

Push-Location $TrainRoot
try {
  python scripts\ingest_alfa_ai_pack.py --pack $PackDir --merge-into data
  if ($LASTEXITCODE -ne 0) {
    throw "ingest failed exit=$LASTEXITCODE"
  }
  Write-Host "Ingest OK. Start training per alfa-train docs (pool-7b-qlora-sft)."
  Write-Host "Publish checkpoint to hub when done; run eval gate on orchestrator/apps:"
  Write-Host "  python scripts/eval/train_checkpoint_gate.py --answers-base ... --answers-checkpoint ..."
} finally {
  Pop-Location
}
