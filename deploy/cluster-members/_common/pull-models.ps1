<#
.SYNOPSIS
    Pull the ALFa AI Ollama tier set into local Ollama.

.DESCRIPTION
    JUNE 2026 model upgrade (ROADMAP "Operator-selected models (2026-06-17)"):
      gaming-c gaming-worker-c   = qwen3.5:27b dense (quality default) + qwen3-embedding:4b
      orchestrator hub = qwen3.6:35b-a3b MoE (speed)
      gaming-b gaming-worker-b    = embed cold-standby; reranker = Qwen3-Reranker-0.6B sidecar (NOT Ollama)
      hub/apps/gaming-a = no chat LLM (delete Ollama there).
    Requires Ollama 0.30.x (Gated-DeltaNet arch) - verify the tag loads first.

    May 2026 audit HUB-001 - hub-first policy (fleet sync only):
      Merge hub manifests+blobs into local store; ollama pull for missing tags.
      To SEED the hub on hub, use hub_hub_models.sh - not curl /api/pull
      from another host. See docs/HTTP_DOWNLOADS.md.

    Environment (optional):
      $env:ALFA_OLLAMA_HUB_MODELS  Explicit UNC or path to hub directory mirroring
                                   .ollama\models (contains manifests\ + blobs\).
      $env:ALFA_OLLAMA_SKIP_HUB    If set, skip hub (public pull only).

    Default hub candidates (first with manifests\registry.ollama.ai\library):
      ALFA_OLLAMA_HUB_MODELS, \\hub\ollama\models, \\hub\ollama,
      W:\models (if drive letter mapped per docs/HUB_ARTIFACTS.md),
      \\hub\temp\cluster_members\models\ollama

    Install / runtime gotchas (CUDA visibility, OLLAMA_HOST, CPU-only tiers):
      docs/OLLAMA_INSTALL_GOTCHAS.md (audit OLLAMA-002 / backlog #24).
    Architecture: docs/DISTRIBUTED_AI.md; tiers: docs/QWEN3_MIGRATION.md.

    Roles:
      -Role Quality  gaming-c gaming-worker-c. CPU chat quality default (qwen3.5:27b dense) + primary embed.
      -Role Speed    orchestrator hub. CPU chat speed host (qwen3.6:35b-a3b MoE).
      -Role Embed    gaming-c primary / gaming-b cold-standby. Pulls qwen3-embedding:4b only.
      -Role Reranker gaming-b gaming-worker-b. Embed standby; reranker = Qwen3-Reranker-0.6B sidecar (NOT Ollama).
      -Role All      Same as Quality (convenience).
      -Role Brain    DEPRECATED - hub no longer runs chat models. Warns, pulls nothing.
      -Role Fleet    DEPRECATED - 30B MoE fleet retired. Warns, pulls nothing.

    The tags themselves are the authoritative list -- update this file and
    the Linux pull-models.sh sibling when the tier matrix changes. See
    deploy/litellm_config.yaml and docs/QWEN3_MIGRATION.md.

.PARAMETER Role
    Which tier set to pull. One of Quality, Speed, Embed, Reranker, All,
    Brain (deprecated), Fleet (deprecated).
    Default Quality.

.EXAMPLE
    # gaming-c gaming-worker-c (CPU chat quality + embed)
    pwsh ./pull-models.ps1 -Role Quality

.EXAMPLE
    # orchestrator hub (CPU chat speed MoE)
    pwsh ./pull-models.ps1 -Role Speed

.EXAMPLE
    # gaming-b gaming-worker-b (embed standby)
    pwsh ./pull-models.ps1 -Role Reranker

.EXAMPLE
    # Force skip hub (CI / offline hub)
    $env:ALFA_OLLAMA_SKIP_HUB='1'; pwsh ./pull-models.ps1 -Role Embed
#>
[CmdletBinding()]
param(
    [ValidateSet('Quality', 'Speed', 'Embed', 'Reranker', 'All', 'Brain', 'Agent', 'Fast', 'Fleet', 'Inline')]
    [string]$Role = 'Quality'
)

$ErrorActionPreference = 'Stop'

function Get-ManifestRelPathForTag {
    param([string]$Tag)
    $lib = 'manifests\registry.ollama.ai\library'
    if ($Tag -match '^([^:]+):(.+)$') {
        return Join-Path $lib (Join-Path $Matches[1] $Matches[2])
    }
    return Join-Path (Join-Path $lib $Tag) 'latest'
}

function Test-HubHasManifest {
    param(
        [string]$HubModelsDir,
        [string]$Tag
    )
    $rel = Get-ManifestRelPathForTag -Tag $Tag
    $full = Join-Path $HubModelsDir $rel
    return (Test-Path -LiteralPath $full -PathType Leaf)
}

function Get-ResolvedHubModelsDir {
    if ($env:ALFA_OLLAMA_SKIP_HUB) { return $null }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ALFA_OLLAMA_HUB_MODELS) { $candidates.Add($env:ALFA_OLLAMA_HUB_MODELS.TrimEnd('\')) }
    $candidates.Add('\\hub\ollama\models')
    $candidates.Add('\\hub\ollama')
    if (Test-Path -LiteralPath 'W:\models' -ErrorAction SilentlyContinue) { $candidates.Add('W:\models') }
    if (Test-Path -LiteralPath 'W:\' -ErrorAction SilentlyContinue) { $candidates.Add('W:\') }
    $candidates.Add('\\hub\temp\cluster_members\models\ollama')

    foreach ($d in $candidates) {
        if (-not $d) { continue }
        $lib = Join-Path $d 'manifests\registry.ollama.ai\library'
        if (Test-Path -LiteralPath $lib -PathType Container) {
            return $d
        }
    }
    return $null
}

function Merge-HubModelsIntoLocal {
    param([string]$HubModelsDir)

    $dest = Join-Path $env:USERPROFILE '.ollama\models'
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    $null = & robocopy.exe $HubModelsDir $dest /E /XO /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        Write-Warning "robocopy exited $code (hub merge may be incomplete)"
        return $false
    }
    return $true
}

function Get-OllamaPresentTags {
    $raw = & ollama list 2>$null
    if (-not $raw) { return @() }
    ($raw -split "`n" | Select-Object -Skip 1 | ForEach-Object {
            $parts = $_ -split '\s+', 2
            if ($parts[0]) { $parts[0].Trim() }
        }) | Where-Object { $_ }
}

$qualityTags  = @('qwen3-embedding:4b')
$speedTags    = @('qwen3.6:35b-a3b')
$embedTags    = @('qwen3-embedding:4b')
$rerankerTags = @('qwen3-embedding:4b')

$tags = switch ($Role) {
    'Quality'  { $qualityTags }
    'Speed'    { $speedTags }
    'Embed'    { $embedTags }
    'Reranker' { $rerankerTags }
    'All'      { $qualityTags }
    { $_ -in 'Brain','Agent','Fast','Fleet','Inline' } {
        Write-Warning "Role '$Role' is DEPRECATED."
        Write-Warning "  hub/apps/gaming-a: no chat LLM. gaming-c: use Quality. orchestrator: use Speed. gaming-b: use Reranker."
        Write-Warning "  No models will be pulled. See docs/ROADMAP.md Operator-selected models (2026-06-17)."
        exit 0
    }
}

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Error 'ollama not found on PATH. Install from https://ollama.com/download first.'
    exit 1
}

Write-Host "== Ollama pull ($Role) - hub-first (audit HUB-001) ==" -ForegroundColor Cyan

$hubModels = Get-ResolvedHubModelsDir
if ($hubModels) {
    Write-Host "  hub models dir: $hubModels"
} else {
    Write-Host '  hub: not resolved (map W: per HUB_ARTIFACTS.md or set ALFA_OLLAMA_HUB_MODELS); will use ollama pull only'
}

$present = @(Get-OllamaPresentTags)

$needMerge = $false
if ($hubModels) {
    foreach ($tag in $tags) {
        if ($present -contains $tag) { continue }
        if (Test-HubHasManifest -HubModelsDir $hubModels -Tag $tag) {
            $needMerge = $true
            break
        }
    }
    if ($needMerge) {
        Write-Host '  [hub] merging manifests+blobs from hub (one-shot)...' -ForegroundColor Yellow
        $null = Merge-HubModelsIntoLocal -HubModelsDir $hubModels
        $present = @(Get-OllamaPresentTags)
    }
}

foreach ($tag in $tags) {
    if ($present -contains $tag) {
        Write-Host "  [skip] $tag already present"
        continue
    }
    if ($hubModels -and -not (Test-HubHasManifest -HubModelsDir $hubModels -Tag $tag)) {
        Write-Host "  [hub] no manifest for $tag - using ollama pull"
    }
    Write-Host "  [pull] $tag"
    & ollama pull $tag
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Failed to pull $tag (exit $LASTEXITCODE). Retry manually."
    }
    $present = @(Get-OllamaPresentTags)
}

Write-Host ''
Write-Host 'Done. Current Ollama models:' -ForegroundColor Green
& ollama list
