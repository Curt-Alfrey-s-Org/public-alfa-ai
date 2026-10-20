<#
.SYNOPSIS
    GPU preflight for Windows (and WSL-facing) cluster nodes.
.DESCRIPTION
    Runs `nvidia-smi` as the single source of truth for GPU identity, classifies the
    first card's compute capability, and writes a node profile JSON to
    $env:ProgramData\alfa-ai\node_profile.json.

    Call this FIRST from every deploy.ps1 on orchestrator, gaming-b, gaming-c, gaming-a. Downstream steps
    read the profile instead of hard-coding hardware facts from out-of-date docs.

    nvidia-smi:   https://docs.nvidia.com/deploy/nvidia-smi/
    Blackwell cc: sm_120+ (RTX 5060/5070); Ampere 86; Ada 89; Turing 75.

.PARAMETER Role
    brain | gpu-worker | apps | agent-only. Role drives whether missing GPU is fatal.
.PARAMETER Force
    Skip role/hardware gate (e.g. agent-only box with no CUDA driver).
.PARAMETER RepoRoot
    Defaults to two levels up from this script (deploy/cluster-members/_common/..).
.PARAMETER ProfilePath
    Override the output JSON location (default: $env:ProgramData\alfa-ai\node_profile.json).

.EXAMPLE
    . "$PSScriptRoot\..\_common\nvidia-preflight.ps1"
    Invoke-AlfaNvidiaPreflight -Role 'gpu-worker'
#>

function Invoke-AlfaNvidiaPreflight {
    [CmdletBinding()]
    param(
        [ValidateSet('brain','gpu-worker','apps','agent-only')]
        [string]$Role = 'gpu-worker',
        [switch]$Force,
        [string]$RepoRoot,
        [string]$ProfilePath
    )

    $ErrorActionPreference = 'Stop'
    if (-not $RepoRoot) {
        # This script lives at <repo>\deploy\cluster-members\_common\nvidia-preflight.ps1
        # Four Split-Path -Parent pops take us: _common -> cluster-members -> deploy -> <repo>
        $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
    }
    if (-not $ProfilePath) {
        $dataRoot = if ($env:ProgramData) { $env:ProgramData } else { $env:TEMP }
        $ProfilePath = Join-Path $dataRoot 'alfa-ai\node_profile.json'
    }

    $smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
    $gpus = @()
    if ($smi) {
        # --query-gpu fields, comma-separated, no header -- easy to ForEach-Object split.
        $raw = & nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            foreach ($line in $raw) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line.Split(',') | ForEach-Object { $_.Trim() }
                if ($parts.Count -ge 4) {
                    $gpus += [PSCustomObject]@{
                        Name        = $parts[0]
                        Driver      = $parts[1]
                        ComputeCap  = $parts[2]
                        MemoryTotal = $parts[3]
                    }
                }
            }
        }
    }

    if ($gpus.Count -gt 0) {
        Write-Host '[nvidia-preflight] Detected GPUs:' -ForegroundColor Cyan
        $gpus | ForEach-Object { Write-Host ('  {0} | cc={1} | {2}' -f $_.Name, $_.ComputeCap, $_.MemoryTotal) }
    } else {
        Write-Host '[nvidia-preflight] No GPUs reported by nvidia-smi.' -ForegroundColor Yellow
    }

    $computeCap = if ($gpus.Count -gt 0) { $gpus[0].ComputeCap } else { '' }
    $major = 0
    if ($computeCap -match '^(\d+)') { $major = [int]$matches[1] }

    $gpuClass = 'none'
    if ($major -ge 12)      { $gpuClass = 'blackwell' }
    elseif ($major -ge 7)   { $gpuClass = 'ampere-or-newer' }
    elseif ($major -gt 0)   { $gpuClass = 'legacy' }

    if (($Role -in @('brain','gpu-worker')) -and $gpuClass -eq 'none' -and -not $Force) {
        throw "[nvidia-preflight] role '$Role' expects a CUDA GPU but nvidia-smi reports none (use -Force to override)"
    }

    $profileDir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress) 2>$null

    $profile = [PSCustomObject]@{
        hostname             = $env:COMPUTERNAME
        ip                   = $ip
        role                 = $Role
        gpu_class            = $gpuClass
        first_gpu            = if ($gpus.Count -gt 0) { $gpus[0].Name } else { 'none' }
        compute_cap          = $computeCap
        generated_at         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $profile | ConvertTo-Json -Depth 4 | Set-Content -Path $ProfilePath -Encoding UTF8

    Write-Host ("[nvidia-preflight] profile -> {0} (role={1} gpu_class={2})" -f `
        $ProfilePath, $Role, $gpuClass) -ForegroundColor Green

    $env:ALFA_NODE_ROLE = $Role
    $env:ALFA_NODE_GPU_CLASS = $gpuClass
    return $profile
}

if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\.\s') {
    $params = @{}
    if ($args) {
        for ($i = 0; $i -lt $args.Count; $i++) {
            if ($args[$i] -eq '-Role' -and ($i+1) -lt $args.Count) { $params.Role = $args[$i+1]; $i++ }
            elseif ($args[$i] -eq '-Force') { $params.Force = $true }
        }
    }
    Invoke-AlfaNvidiaPreflight @params | Out-Null
}
