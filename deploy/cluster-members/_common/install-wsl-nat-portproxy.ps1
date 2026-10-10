<#
.SYNOPSIS
    Win10 NAT path: forward Windows LAN ports into WSL2 for Petals workers.

.DESCRIPTION
    Mirrored WSL networking (Win11 22H2+) binds Petals host ports on the LAN IP
    directly. Win10 uses NAT - services listen inside the WSL VM (172.x.x.x).

    Microsoft-documented workaround:
      https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-a-wsl-2-distribution-from-your-local-area-network-lan

    Requires Administrator PowerShell. Re-run after every wsl --shutdown or
    reboot (WSL IP is dynamic). Use -RegisterScheduledTask for logon refresh.

    Audited deviation for gaming-worker-a (gaming-a) until Win11 upgrade - see
    docs/WINDOWS_WSL_DOCKER_ENGINE.md - Win10 NAT portproxy.

.EXAMPLE
    . .\deploy\cluster-members\_common\install-wsl-nat-portproxy.ps1
    Set-AlfaWslNatPortProxy -TcpPorts 31330,31331,5003

.EXAMPLE
    Install-AlfaWslNatPortProxy -DisplayNamePrefix 'ALFa gaming-worker-a-219' `
        -TcpPorts 31330,31331,5003 -RegisterScheduledTask
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest

function Test-AlfaWslMirroredNetworkingSupported {
    <#
    Mirrored mode requires Windows 11 22H2 (build 22621+).
    https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking
    #>
    return ([System.Environment]::OSVersion.Version.Build -ge 22621)
}

function Test-AlfaWslNatPortProxyRequired {
    if (-not (Test-AlfaWslMirroredNetworkingSupported)) {
        return $true
    }
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path -LiteralPath $cfg)) {
        return $false
    }
    $raw = Get-Content -LiteralPath $cfg -Raw
    return ($raw -notmatch '(?m)^\s*networkingMode\s*=\s*mirrored\s*$')
}

function Get-AlfaWslDistroIpv4 {
    [CmdletBinding()]
    param(
        [string]$Distro = 'Ubuntu'
    )

    wsl.exe -d $Distro -e true 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "WSL distro '$Distro' is not running. Start with: wsl -d $Distro"
    }

    $raw = (wsl.exe -d $Distro hostname -I 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Could not read WSL IP from: wsl -d $Distro hostname -I"
    }

    foreach ($token in ($raw -split '\s+')) {
        if ($token -match '^\d+\.\d+\.\d+\.\d+$' -and $token -notmatch '^127\.') {
            return $token
        }
    }
    throw "No usable IPv4 in WSL hostname -I output: $raw"
}

function Get-AlfaWslNatPortProxyRules {
    [CmdletBinding()]
    param(
        [string]$ListenAddress = '0.0.0.0'
    )

    $lines = netsh interface portproxy show v4tov4 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $rules = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') {
            if ($Matches[1] -eq $ListenAddress) {
                $rules += [pscustomobject]@{
                    ListenAddress  = $Matches[1]
                    ListenPort     = [int]$Matches[2]
                    ConnectAddress = $Matches[3]
                    ConnectPort    = [int]$Matches[4]
                }
            }
        }
    }
    return $rules
}

function Test-AlfaWslNatPortProxyMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int[]]$TcpPorts,
        [string]$Distro = 'Ubuntu',
        [string]$ListenAddress = '0.0.0.0'
    )

    if (-not (Test-AlfaWslNatPortProxyRequired)) {
        return $true
    }

    $wslIp = Get-AlfaWslDistroIpv4 -Distro $Distro
    $rules = @(Get-AlfaWslNatPortProxyRules -ListenAddress $ListenAddress)
    foreach ($port in $TcpPorts | Sort-Object -Unique) {
        $rule = $rules | Where-Object { $_.ListenPort -eq $port -and $_.ConnectAddress -eq $wslIp -and $_.ConnectPort -eq $port }
        if (-not $rule) {
            return $false
        }
    }
    return $true
}

function Invoke-AlfaWslNatPortProxyScheduledTask {
    [CmdletBinding()]
    param(
        [string]$TaskName = 'ALFa-WSL-NAT-PortProxy'
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return $false
    }
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 3
    return $true
}

function Sync-AlfaWslNatPortProxy {
    <#
    Idempotent Win10 NAT portproxy refresh. Safe from normal user PowerShell:
      - OK if rules already match current WSL IP
      - Admin: apply netsh rules directly
      - Non-admin: trigger ALFa-WSL-NAT-PortProxy scheduled task (elevated)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int[]]$TcpPorts,
        [string]$Distro = 'Ubuntu',
        [string]$DisplayNamePrefix = 'ALFa WSL NAT portproxy',
        [string]$RepoRoot,
        [switch]$SkipFirewall
    )

    if (-not (Test-AlfaWslNatPortProxyRequired)) {
        Write-Host '  portproxy: skipped (mirrored WSL / Win11 path)' -ForegroundColor DarkGray
        return $true
    }

    if (Test-AlfaWslNatPortProxyMatches -TcpPorts $TcpPorts -Distro $Distro) {
        Write-Host '  portproxy: OK (rules match current WSL IP)' -ForegroundColor Green
        return $true
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if ($isAdmin) {
        Install-AlfaWslNatPortProxy `
            -DisplayNamePrefix $DisplayNamePrefix `
            -TcpPorts $TcpPorts `
            -Distro $Distro `
            -RepoRoot $RepoRoot `
            -SkipFirewall:$SkipFirewall
    } else {
        Write-Host '  portproxy: stale rules - triggering elevated scheduled task...' -ForegroundColor Cyan
        if (-not (Invoke-AlfaWslNatPortProxyScheduledTask)) {
            Write-Host '  WARN: ALFa-WSL-NAT-PortProxy task missing. Run once from Admin:' -ForegroundColor Yellow
            Write-Host '    Install-AlfaWslNatPortProxy ... -RegisterScheduledTask' -ForegroundColor DarkGray
            return $false
        }
    }

    if (Test-AlfaWslNatPortProxyMatches -TcpPorts $TcpPorts -Distro $Distro) {
        Write-Host '  portproxy: OK after refresh' -ForegroundColor Green
        return $true
    }

    Write-Host '  WARN: portproxy still stale after refresh (WSL IP may have changed)' -ForegroundColor Yellow
    return $false
}

function Set-AlfaWslNatPortProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int[]]$TcpPorts,
        [string]$Distro = 'Ubuntu',
        [string]$ListenAddress = '0.0.0.0'
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        throw 'Set-AlfaWslNatPortProxy requires Administrator PowerShell.'
    }

    $wslIp = Get-AlfaWslDistroIpv4 -Distro $Distro
    Write-Host "== WSL NAT portproxy (Win10 path) ==" -ForegroundColor Cyan
    Write-Host "  WSL distro: $Distro @ $wslIp" -ForegroundColor DarkGray
    Write-Host "  Listen:     $ListenAddress -> WSL (Microsoft netsh portproxy)" -ForegroundColor DarkGray

    foreach ($port in $TcpPorts | Sort-Object -Unique) {
        netsh interface portproxy delete v4tov4 listenport=$port listenaddress=$ListenAddress 2>$null | Out-Null
        netsh interface portproxy add v4tov4 `
            listenport=$port listenaddress=$ListenAddress `
            connectport=$port connectaddress=$wslIp | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "netsh portproxy failed for port $port"
        }
        Write-Host "  OK   $ListenAddress`:$port -> ${wslIp}:$port" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Current portproxy rules:' -ForegroundColor DarkGray
    netsh interface portproxy show v4tov4
    Write-Host ''
}

function Register-AlfaWslNatPortProxyScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [int[]]$TcpPorts,
        [string]$Distro = 'Ubuntu',
        [string]$TaskName = 'ALFa-WSL-NAT-PortProxy',
        [string]$DisplayNamePrefix = 'ALFa WSL NAT portproxy'
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        throw 'Register-AlfaWslNatPortProxyScheduledTask requires Administrator PowerShell.'
    }

    $runner = Join-Path $RepoRoot 'deploy\cluster-members\_common\run-wsl-nat-portproxy.ps1'
    if (-not (Test-Path -LiteralPath $runner)) {
        throw "Missing runner script: $runner"
    }

    $portArg = ($TcpPorts | Sort-Object -Unique) -join ','
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -TcpPorts $portArg -Distro $Distro -Quiet"

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Host "  Scheduled task registered: $TaskName (At logon, highest)" -ForegroundColor Green
    Write-Host "  Refreshes portproxy when WSL IP changes after reboot/wsl --shutdown." -ForegroundColor DarkGray
}

function Install-AlfaWslNatPortProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayNamePrefix,
        [Parameter(Mandatory)]
        [int[]]$TcpPorts,
        [string]$Distro = 'Ubuntu',
        [string]$RepoRoot,
        [switch]$RegisterScheduledTask,
        [switch]$SkipFirewall
    )

    if (-not $RepoRoot) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    }

    if (-not (Test-AlfaWslNatPortProxyRequired)) {
        Write-Host '  SKIP portproxy: mirrored WSL networking active (Win11 path).' -ForegroundColor DarkGray
        return
    }

    Set-AlfaWslNatPortProxy -TcpPorts $TcpPorts -Distro $Distro

    if (-not $SkipFirewall) {
        $fwScript = Join-Path $PSScriptRoot 'open-worker-lan-firewall.ps1'
        if (Test-Path -LiteralPath $fwScript) {
            . $fwScript
            Open-AlfaWorkerLanFirewall -DisplayNamePrefix $DisplayNamePrefix `
                -TcpPorts $TcpPorts -Profile Any -SkipHyperV
        }
    }

    if ($RegisterScheduledTask) {
        Register-AlfaWslNatPortProxyScheduledTask -RepoRoot $RepoRoot -TcpPorts $TcpPorts -Distro $Distro
    }

    Write-Host '  Remote verify from inference after worker is up:' -ForegroundColor Cyan
    Write-Host '    timeout 3 bash -c "echo >/dev/tcp/orchestrator/31330" && echo DHT_OK' -ForegroundColor DarkGray
}
