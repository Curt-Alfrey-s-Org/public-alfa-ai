<#
.SYNOPSIS
    Open inbound Windows Firewall rules for llama.cpp RPC / worker LAN ports.
#>

function Open-AlfaWorkerLanHyperVFirewall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayNamePrefix,
        [Parameter(Mandatory)]
        [int[]]$TcpPorts,
        [string]$RemoteAddress = 'orchestrator/24',
        [ValidateSet('Private', 'Domain', 'Public', 'Any')]
        [string]$Profile = 'Any'
    )

    if (-not (Get-Command Get-NetFirewallHyperVVMCreator -ErrorAction SilentlyContinue)) {
        Write-Host '  SKIP Hyper-V firewall: Get-NetFirewallHyperVVMCreator not available.' -ForegroundColor Yellow
        return
    }

    $vmCreator = Get-NetFirewallHyperVVMCreator -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vmCreator) {
        Write-Host '  SKIP Hyper-V firewall: no WSL VMCreatorId.' -ForegroundColor Yellow
        return
    }

    $vmId = $vmCreator.VMCreatorId
    Write-Host '== Hyper-V Firewall (WSL mirrored LAN inbound) ==' -ForegroundColor Cyan
    foreach ($port in $TcpPorts) {
        $displayName = "$DisplayNamePrefix HyperV TCP $port"
        $existing = Get-NetFirewallHyperVRule -DisplayName $displayName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $displayName already exists" -ForegroundColor Green
            continue
        }
        New-NetFirewallHyperVRule `
            -DisplayName $displayName `
            -Direction Inbound `
            -VMCreatorId $vmId `
            -Protocol TCP `
            -LocalPorts $port `
            -RemoteAddresses $RemoteAddress `
            -Action Allow `
            -Profile $Profile | Out-Null
        Write-Host "  Added $displayName (Profile=$Profile Remote=$RemoteAddress)" -ForegroundColor Green
    }
    Write-Host ''
}

function Open-AlfaWorkerLanFirewall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayNamePrefix,
        [int[]]$TcpPorts = @(31350, 31360),
        [string]$RemoteAddress = 'orchestrator/24',
        [ValidateSet('Private', 'Domain', 'Public', 'Any')]
        [string]$Profile = 'Private',
        [switch]$SkipHyperV
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-Host '  SKIP firewall: run from Administrator PowerShell to open LAN ports.' -ForegroundColor Yellow
        return
    }

    Write-Host '== Windows Firewall (worker LAN) ==' -ForegroundColor Cyan
    foreach ($port in $TcpPorts) {
        $displayName = "$DisplayNamePrefix TCP $port"
        $existing = Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $displayName already exists" -ForegroundColor Green
            continue
        }
        New-NetFirewallRule `
            -DisplayName $displayName `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $port `
            -RemoteAddress $RemoteAddress `
            -Action Allow `
            -Profile $Profile | Out-Null
        Write-Host "  Added $displayName (Profile=$Profile Remote=$RemoteAddress)" -ForegroundColor Green
    }
    Write-Host ''

    if (-not $SkipHyperV) {
        Open-AlfaWorkerLanHyperVFirewall -DisplayNamePrefix $DisplayNamePrefix -TcpPorts $TcpPorts -RemoteAddress $RemoteAddress -Profile $Profile
    }
}
