#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotent LAN firewall (host + Hyper-V) for WSL mirrored Docker workers.

.DESCRIPTION
    Microsoft WSL mirrored mode with firewall=true requires BOTH New-NetFirewallRule
    AND New-NetFirewallHyperVRule for remote LAN peers to reach container ports.
    See docs/WINDOWS_WSL_DOCKER_ENGINE.md and:
    https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking

    Install once per Windows worker during Phase B (Administrator / operator on orchestrator).
    Orchestrator and deploy scripts call Test-AlfaWslLanFirewallProfileReady from
    a non-Admin session and fail loud with this script path when rules are missing.

.EXAMPLE
    # From orchestrator Administrator PowerShell as operator (no git pull):
    powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\_common\install-wsl-lan-firewall.ps1 -Profile operator-93

.EXAMPLE
    . .\install-wsl-lan-firewall.ps1
    Test-AlfaWslLanFirewallProfileReady -Profile operator-93
#>
[CmdletBinding()]
param(
    [ValidateSet('operator-93', 'gaming-worker-a-219', 'gaming-worker-b-249', 'gaming-worker-c-59')]
    [string]$Profile = '',
    [string]$RepoRoot = '',
    [switch]$InstallOnly
)

Set-StrictMode -Version Latest

function Get-AlfaWslLanFirewallProfiles {
    return @{
        'operator-93' = @{
            DisplayNamePrefix = 'ALFa operator-93'
            LegacyPrefixes    = @('ALFa inference orchestrator')
            TcpPorts          = @(8413, 5002, 31330, 31340, 31331, 31341, 31350)
            RemoteAddress     = 'orchestrator/24'
        }
        'gaming-worker-a-219' = @{
            DisplayNamePrefix = 'ALFa gaming-worker-a-219'
            TcpPorts          = @(31330, 31331, 5003, 31352)
            RemoteAddress     = 'orchestrator/24'
        }
        'gaming-worker-b-249' = @{
            DisplayNamePrefix = 'ALFa gaming-worker-b-249'
            TcpPorts          = @(31330, 31331, 31360)
            RemoteAddress     = 'orchestrator/24'
        }
        'gaming-worker-c-59' = @{
            DisplayNamePrefix = 'ALFa gaming-worker-c-59'
            TcpPorts          = @(31330, 31331, 31351, 11434)
            RemoteAddress     = 'orchestrator/24'
        }
    }
}

function Test-AlfaWslLanFirewallPortReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayNamePrefix,
        [Parameter(Mandatory)][int]$Port,
        [string[]]$LegacyPrefixes = @()
    )

    if (-not (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        return $false
    }
    $prefixes = @($DisplayNamePrefix) + @($LegacyPrefixes)
    $rules = @(Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)
    foreach ($pfx in $prefixes) {
        foreach ($r in $rules) {
            if ($r.DisplayName -like "$pfx*" -and "$($r.LocalPorts)" -match "\b$Port\b") {
                return $true
            }
        }
    }
    return $false
}

function Test-AlfaWslLanFirewallProfileReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('operator-93', 'gaming-worker-a-219', 'gaming-worker-b-249', 'gaming-worker-c-59')]
        [string]$Profile,
        [int[]]$RequiredPorts = @()
    )

    $profiles = Get-AlfaWslLanFirewallProfiles
    $cfg = $profiles[$Profile]
    $ports = if ($RequiredPorts.Count -gt 0) { $RequiredPorts } else { $cfg.TcpPorts }
    $legacy = @()
    if ($cfg.ContainsKey('LegacyPrefixes')) {
        $legacy = @($cfg.LegacyPrefixes)
    }
    foreach ($port in $ports) {
        if (-not (Test-AlfaWslLanFirewallPortReady -DisplayNamePrefix $cfg.DisplayNamePrefix -Port $port -LegacyPrefixes $legacy)) {
            return $false
        }
    }
    return $true
}

function Get-AlfaWslLanFirewallInstallCommand {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [string]$RepoRoot = ''
    )
    if (-not $RepoRoot) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    }
    $scriptPath = Join-Path $PSScriptRoot 'install-wsl-lan-firewall.ps1'
    return "powershell -ExecutionPolicy Bypass -File `"$scriptPath`" -Profile $Profile"
}

function Install-AlfaWslLanFirewall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('operator-93', 'gaming-worker-a-219', 'gaming-worker-b-249', 'gaming-worker-c-59')]
        [string]$Profile,
        [string]$RepoRoot = ''
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        throw "Install-AlfaWslLanFirewall requires Administrator PowerShell. Run: $(Get-AlfaWslLanFirewallInstallCommand -Profile $Profile -RepoRoot $RepoRoot)"
    }

    $profiles = Get-AlfaWslLanFirewallProfiles
    $cfg = $profiles[$Profile]
    $fwScript = Join-Path $PSScriptRoot 'open-worker-lan-firewall.ps1'
    if (-not (Test-Path -LiteralPath $fwScript)) {
        throw "Missing firewall helper: $fwScript"
    }
    . $fwScript
    Write-Host "== WSL LAN firewall ($Profile) ==" -ForegroundColor Cyan
    Open-AlfaWorkerLanFirewall `
        -DisplayNamePrefix $cfg.DisplayNamePrefix `
        -TcpPorts $cfg.TcpPorts `
        -Profile Any `
        -RemoteAddress $cfg.RemoteAddress
    Write-Host ''
    Write-Host 'If .wslconfig changed recently, run: wsl --shutdown' -ForegroundColor Yellow
    Write-Host 'Then redeploy inference shard (deploy-grev27-pool-shard.ps1) or full orchestrator start.' -ForegroundColor Yellow
}

if ($Profile -and $MyInvocation.InvocationName -ne '.') {
    Install-AlfaWslLanFirewall -Profile $Profile -RepoRoot $RepoRoot
}
