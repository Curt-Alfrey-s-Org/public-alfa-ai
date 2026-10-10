<#
.SYNOPSIS
    Write CHAT, CODE, or CODE27 coordinator profile into deploy/llamacpp-rpc/.env.rpc on orchestrator.
.DESCRIPTION
    Scenario 2 (FOUR_HOST_FRONTIER_POOL.md): one tier-3 GGUF at a time on orchestrator:31360.
    Code = Qwen3-Coder-Next-80B-A3B (frontier-code). Code27 = optional Qwen3.6-27B pool.
    Chat = future Qwen3.5-122B-A10B upgrade path (not wired as LiteLLM `frontier` today).
    Run deploy-llamacpp-rpc-coordinator.ps1 after this to recreate llama-server.
.PARAMETER Profile
    Chat (122B pooled), Code (80B tier-3 coding), or Code27 (27B on 3050+5060).
.PARAMETER EnableSpeculative
    Enable Phase E2 draft model on the coordinator RTX 3060 (requires hub GGUF sync).
.EXAMPLE
    .\switch-coordinator-profile.ps1 -Profile Code
.EXAMPLE
    .\switch-coordinator-profile.ps1 -Profile Chat -EnableSpeculative
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Chat', 'Code', 'Code27')]
    [string]$Profile,
    [switch]$EnableSpeculative
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CommonDir = Join-Path $PSScriptRoot '..\_common'
. (Join-Path $CommonDir 'Get-AlfaWindowsCacheRoot.ps1')
. (Join-Path $CommonDir 'wsl-docker.ps1')
$cacheRoot = Get-AlfaWindowsCacheRoot
$modelsWin = Join-Path $cacheRoot 'llama-cpp\models'
$slotCacheWin = Join-Path $cacheRoot 'llama-cpp\slot-cache'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$EnvPath = Join-Path $RepoDir 'deploy\llamacpp-rpc\.env.rpc'
$ModelsDirWsl = ConvertTo-AlfaWslPath -Path $modelsWin
$SlotCacheDirWsl = ConvertTo-AlfaWslPath -Path $slotCacheWin
$WslHome = (wsl.exe -d Ubuntu bash -lc 'printf %s "$HOME"').Trim()
if (-not $WslHome) {
    throw 'Could not resolve WSL HOME for Code27 MODELS_DIR'
}
$ModelsDirWslNative = "$WslHome/alfa-ai-cache/llama-cpp/models"
$SlotCacheDirWslNative = "$WslHome/alfa-ai-cache/llama-cpp/slot-cache"

$speculativeBlock = ''
if ($EnableSpeculative) {
    $speculativeBlock = @"

# Phase E2 speculative draft (coordinator GPU; main model stays RPC)
MODEL_DRAFT_FILE=Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
N_GPU_LAYERS_DRAFT=999
DRAFT_MAX=16
"@
}

$chatBlock = @"
# --- Coordinator (CHAT profile - future qwen3.5-122b-a10b) ---
MAIN_PORT=31360
MODELS_DIR=$ModelsDirWsl
LLAMA_API_KEY=change-me
PARALLEL=1
CHAT_TEMPLATE=chatml
# No CACHE_REUSE for Qwen3.5 hybrid (llama.cpp #18497: ineffective on recurrent layers).
SLOT_CACHE_DIR=$SlotCacheDirWsl
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0
THREADS_HTTP=16

MODEL_ALIAS=qwen3.5-122b-a10b
MODEL_FILE=Q3_K_M/Qwen3.5-122B-A10B-Q3_K_M-00001-of-00003.gguf
# Stop Petals 70B and stop Code profile before Chat load.
# Start rpc-server on orchestrator:31350 and inference:31356 (3060 shards) before Chat load.
RPC_BACKENDS=orchestrator,orchestrator,orchestrator,hub
CTX_SIZE=65536
N_GPU_LAYERS=0
"@

$codeBlock80 = @"
# --- Coordinator (CODE profile - frontier-code, Qwen3-Coder-Next-80B-A3B) ---
MAIN_PORT=31360
MODELS_DIR=$ModelsDirWsl
LLAMA_API_KEY=change-me
PARALLEL=1
CHAT_TEMPLATE=chatml
CACHE_REUSE=256
SLOT_CACHE_DIR=$SlotCacheDirWsl
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0
THREADS_HTTP=16

MODEL_ALIAS=qwen3-coder-next-80b-a3b
MODEL_FILE=Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf
# Stop Petals 70B before Code load. Start all rpc-server shards before Code load.
# Append gaming hosts when online: gaming-c:31351, gaming-a:31352, orchestrator:31355
RPC_BACKENDS=orchestrator,orchestrator,orchestrator,hub,orchestrator,orchestrator,orchestrator
CTX_SIZE=65536
N_GPU_LAYERS=999
"@

$codeBlock27 = @"
# --- Coordinator (CODE27 profile - optional qwen3.6-27b, concurrent with 35B) ---
MAIN_PORT=31360
MODELS_DIR=$ModelsDirWslNative
LLAMA_API_KEY=change-me
PARALLEL=1
CHAT_TEMPLATE=chatml
CACHE_REUSE=256
SLOT_CACHE_DIR=$SlotCacheDirWslNative
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0
THREADS_HTTP=16

MODEL_ALIAS=qwen3.6-27b
MODEL_FILE=Qwen3.6-27B-Q4_K_M.gguf
# 27B weights RPC-only (hub 5060 + apps 1660S + inference 3050). No orchestrator GPU/CPU model blocks.
RPC_BACKENDS=hub,apps,orchestrator
CTX_SIZE=4096
N_GPU_LAYERS=999
TENSOR_SPLIT=4,3,2
"@

if ($Profile -eq 'Code27') {
    $cudaBlock = @"
# Code27: empty CUDA_VISIBLE_DEVICES hides orchestrator 3060 from llama-server (Phase G Ollama 35B).
# Do not set N_GPU_LAYERS=0 -- upstream disables RPC offload (llama.cpp#11807).
CUDA_VISIBLE_DEVICES=

"@
}
else {
    $cudaBlock = @"
CUDA_VISIBLE_DEVICES=0

"@
}

$header = @"
# llama.cpp RPC -- orchestrator coordinator + dual-GPU shards (FOUR_HOST_FRONTIER_POOL.md)
# Shards: docker-compose.rpc-server.dual-gpu-93.yml (:31350 + :31355)
# Coordinator: docker-compose.rpc-main.yml + docker-compose.rpc-main.wsl-93.yml
# Profile: $Profile (switch via switch-coordinator-profile.ps1)

$cudaBlock
"@

$footer = @"

# Legacy shard-only keys (ignored by b7186 rpc-server):
RPC_MEM_MB_GPU0=10240
RPC_MEM_MB_GPU1=10240
"@

if ($Profile -eq 'Chat') {
    $body = $chatBlock
}
elseif ($Profile -eq 'Code27') {
    $body = $codeBlock27
}
else {
    $body = $codeBlock80
}
$content = $header + $body + $speculativeBlock + $footer

$dir = Split-Path -Parent $EnvPath
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

Set-Content -Path $EnvPath -Value $content -Encoding ASCII
Write-Host "Wrote $Profile profile to $EnvPath" -ForegroundColor Green

if ($Profile -eq 'Code') {
    $lead = Join-Path $modelsWin 'Qwen3-Coder-Next-Q4_K_M\Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf'
    if (-not (Test-Path $lead)) {
        Write-Host "WARN: Code 80B GGUF missing at $lead" -ForegroundColor Yellow
        Write-Host '  Stage from hub: scripts/hub_hub_models.sh pull gguf (agentic profile)' -ForegroundColor Yellow
    }
}
elseif ($Profile -eq 'Code27') {
    $code27Gguf = Join-Path $modelsWin 'Qwen3.6-27B-Q4_K_M.gguf'
    if (-not (Test-Path $code27Gguf)) {
        Write-Host "WARN: Code27 GGUF missing at $code27Gguf" -ForegroundColor Yellow
        Write-Host '  Run: .\sync-frontier-code-gguf-from-hub.ps1' -ForegroundColor Yellow
    }
}
