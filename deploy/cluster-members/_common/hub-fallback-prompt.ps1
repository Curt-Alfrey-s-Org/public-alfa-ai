<#
.SYNOPSIS
    Interactive operator gate when a hub SMB hub is unreachable.

.DESCRIPTION
    Hub-first deploy scripts call Request-AlfaHubFallback before any PyPI /
    docker build / source-build fallback. Default is STOP (Enter or Y).

    Non-interactive overrides (CI / scripted reruns):
      ALFA_HUB_FALLBACK=proceed  - allow fallback without prompting
      ALFA_HUB_FALLBACK=stop     - abort without prompting

    Each -Context value is prompted at most once per PowerShell session.
#>

Set-StrictMode -Version Latest

# Global (not $script:) so decisions survive dot-source from deploy helpers invoked
# inside functions (PS 5.1 $script: scope mismatch under Set-StrictMode -Version Latest).
if (-not (Get-Variable -Name AlfaHubFallbackDecisions -Scope Global -ErrorAction SilentlyContinue)) {
    $global:AlfaHubFallbackDecisions = @{}
}

function Request-AlfaHubFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Context,

        [Parameter(Mandatory)]
        [string]$HubPath,

        [Parameter(Mandatory)]
        [string]$FallbackDescription
    )

    if (-not (Get-Variable -Name AlfaHubFallbackDecisions -Scope Global -ErrorAction SilentlyContinue)) {
        $global:AlfaHubFallbackDecisions = @{}
    }

    if ($global:AlfaHubFallbackDecisions.ContainsKey($Context)) {
        return [bool]$global:AlfaHubFallbackDecisions[$Context]
    }

    $envChoice = ''
    if ($env:ALFA_HUB_FALLBACK) {
        $envChoice = $env:ALFA_HUB_FALLBACK.Trim().ToLowerInvariant()
    }
    if ($envChoice -eq 'proceed') {
        Write-Host ("[hub] ALFA_HUB_FALLBACK=proceed - allowing fallback for: {0}" -f $Context) -ForegroundColor Yellow
        $global:AlfaHubFallbackDecisions[$Context] = $true
        return $true
    }
    if ($envChoice -eq 'stop') {
        Write-Host ("[hub] ALFA_HUB_FALLBACK=stop - aborting: {0}" -f $Context) -ForegroundColor Red
        $global:AlfaHubFallbackDecisions[$Context] = $false
        return $false
    }

    Write-Host ''
    Write-Host '=== HUB TARBALL MISSING OR UNREACHABLE ===' -ForegroundColor Red
    Write-Host ("  Context : {0}" -f $Context)
    Write-Host ("  Hub path: {0}" -f $HubPath)
    Write-Host ("  If you proceed: {0}" -f $FallbackDescription) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Recommended: stop, fix SMB / hub / net use, re-run deploy.' -ForegroundColor Gray
    Write-Host '  Type y only if you accept non-hub downloads (PyPI, Docker Hub, HF).' -ForegroundColor Gray
    Write-Host ''
    $ans = Read-Host 'Proceed without hub? [y/N]'
    $proceed = ($ans -match '^\s*[yY]')
    if ($proceed) {
        Write-Host '[hub] Operator chose PROCEED with fallback.' -ForegroundColor Yellow
    } else {
        Write-Host '[hub] Operator chose STOP.' -ForegroundColor Red
    }
    $global:AlfaHubFallbackDecisions[$Context] = $proceed
    return $proceed
}

function Assert-AlfaHubFallbackProceed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Context,

        [Parameter(Mandatory)]
        [string]$HubPath,

        [Parameter(Mandatory)]
        [string]$FallbackDescription
    )

    if (-not (Request-AlfaHubFallback -Context $Context -HubPath $HubPath -FallbackDescription $FallbackDescription)) {
        throw "Operator stopped: hub unreachable ($Context). Path: $HubPath"
    }
}

function Import-AlfaHubFallbackPrompt {
    # No-op when dot-sourced; exists so callers can ensure the module loaded.
}
