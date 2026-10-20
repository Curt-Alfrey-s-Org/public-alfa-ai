#Requires -Version 5.1
<#
.SYNOPSIS
    Block Code27 coordinator deploy while LiteLLM on hub can probe :31360.
.DESCRIPTION
    LiteLLM routes qwen3.6-27b to LLAMACPP_FRONTIER_URL (orchestrator:31360). While the
    coordinator is loading (503), chat completion probes from hub extend load and
    can restart the crash loop. Stop alfa-ai-litellm on hub before first load.
.EXAMPLE
    . .\Test-Code27LiteLLMProbeGuard.ps1
    Test-Code27LiteLLMProbeGuard
#>
Set-StrictMode -Version Latest

function Test-Code27LiteLLMProbeGuard {
    [CmdletBinding()]
    param(
        [string]$LiteLLMHost = 'hub',
        [int]$LiteLLMPort = 8413,
        [int]$CoordinatorPort = 31360,
        [int]$ProbeLogTailLines = 40,
        [int]$MaxProbeLinesInTail = 3
    )

    $litellmUp = $false
    try {
        $probe = Test-NetConnection -ComputerName $LiteLLMHost -Port $LiteLLMPort -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($probe -and $probe.TcpTestSucceeded) {
            $litellmUp = $true
        }
    } catch {
        $litellmUp = $false
    }

    $coordinatorProbe = $false
    $containerName = 'llamacpp-server'
    $running = wsl.exe -d Ubuntu docker ps --filter "name=^/${containerName}$" --format '{{.Names}}' 2>$null
    if ($running -match $containerName) {
        $tail = wsl.exe -d Ubuntu bash -lc "docker logs $containerName 2>&1 | tail -n $ProbeLogTailLines" 2>$null
        if ($tail) {
            $probeCount = ([regex]::Matches($tail, 'POST /v1/chat/completions 192\.168\.0\hub')).Count
            if ($probeCount -gt $MaxProbeLinesInTail) {
                $coordinatorProbe = $true
            }
        }
    }

    if (-not $litellmUp -and -not $coordinatorProbe) {
        Write-Host "Code27 guard OK: LiteLLM not reachable on ${LiteLLMHost}:${LiteLLMPort}; no hub probe spam in coordinator logs." -ForegroundColor Green
        return
    }

    $reasons = @()
    if ($litellmUp) {
        $reasons += "LiteLLM is listening on ${LiteLLMHost}:${LiteLLMPort} (will route qwen3.6-27b to orchestrator:${CoordinatorPort})"
    }
    if ($coordinatorProbe) {
        $reasons += "Coordinator logs show repeated POST /v1/chat/completions from hub"
    }

    throw @"
Code27 deploy blocked: LiteLLM probe guard failed.
  $($reasons -join '; ')

From hub (hub shell as operator), stop LiteLLM before first 27B load:
  sudo docker stop alfa-ai-litellm

After coordinator /health is 200, start LiteLLM again:
  sudo docker start alfa-ai-litellm

Override only if LiteLLM is already stopped and this is a false positive:
  deploy-llamacpp-rpc-coordinator.ps1 -Profile Code27 -SkipLiteLLMGuard
"@
}

if ($MyInvocation.InvocationName -ne '.') {
    Test-Code27LiteLLMProbeGuard @args
}
