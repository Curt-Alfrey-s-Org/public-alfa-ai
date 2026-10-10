<#
.SYNOPSIS
    Route Docker CLI calls through WSL Ubuntu when Docker Desktop is absent.

.DESCRIPTION
    Windows workers migrated to WSL Docker Engine invoke `docker` inside Ubuntu.
    Dot-source from deploy.ps1; call Initialize-AlfaDockerCli before any docker use.

    Microsoft WSL mirrored networking:
      https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking
#>

Set-StrictMode -Version Latest

$script:AlfaUseWslDocker = $false
$script:AlfaWslDockerDistro = 'Ubuntu'

function ConvertTo-AlfaWslPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $n = ($Path -replace '\\', '/').TrimEnd('/')
    if ($n -match '^([A-Za-z]):/(.*)$') {
        return "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
    }
    return $Path
}

function Test-AlfaDockerDesktopInstalled {
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $true }
    }
    return $false
}

function Test-AlfaNativeDockerEngine {
    # After Desktop uninstall, docker.exe may linger on PATH but the engine pipe is gone.
    if (-not (Test-AlfaDockerDesktopInstalled)) {
        return $false
    }
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = docker.exe version 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
}

function Import-AlfaWslRecoveryModule {
    $recoverScript = Join-Path $PSScriptRoot 'Invoke-AlfaWslBash.ps1'
    if (-not (Test-Path -LiteralPath $recoverScript)) { return }
    if (Get-Command Ensure-AlfaWslDistroResponsive -ErrorAction SilentlyContinue) { return }
    . $recoverScript
}

function Test-AlfaWslDockerEngine {
    param([string]$Distro = $script:AlfaWslDockerDistro)

    Import-AlfaWslRecoveryModule
    if (Get-Command Test-AlfaWslDistroResponsive -ErrorAction SilentlyContinue) {
        if (-not (Test-AlfaWslDistroResponsive -Distro $Distro)) {
            if (Get-Command Repair-AlfaWslVm -ErrorAction SilentlyContinue) {
                Repair-AlfaWslVm -Distro $Distro | Out-Null
            }
        }
        if (-not (Test-AlfaWslDistroResponsive -Distro $Distro)) {
            return $false
        }
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    wsl.exe -d $Distro docker version 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
}

function Enable-AlfaWslDockerCli {
    param([string]$Distro = $script:AlfaWslDockerDistro)

    $script:AlfaUseWslDocker = $true
    $script:AlfaWslDockerDistro = $Distro

    function global:docker {
        wsl.exe -d $script:AlfaWslDockerDistro docker @args
    }
}

function Start-AlfaWslDockerService {
    param([string]$Distro = $script:AlfaWslDockerDistro)

    Import-AlfaWslRecoveryModule
    if (Get-Command Ensure-AlfaWslDistroResponsive -ErrorAction SilentlyContinue) {
        Ensure-AlfaWslDistroResponsive -Distro $Distro
    }

    Write-Host "  Starting Docker service in WSL ($Distro)..." -ForegroundColor Cyan
    wsl.exe -d $Distro -e bash -lc 'sudo systemctl start docker 2>/dev/null || sudo service docker start'
}

function Test-AlfaRequireWslDockerEngine {
    $natScript = Join-Path $PSScriptRoot 'install-wsl-nat-portproxy.ps1'
    if (-not (Test-Path -LiteralPath $natScript)) { return $false }
    if (-not (Get-Command Test-AlfaWslNatPortProxyRequired -ErrorAction SilentlyContinue)) {
        . $natScript
    }
    if (Get-Command Test-AlfaWslNatPortProxyRequired -ErrorAction SilentlyContinue) {
        return (Test-AlfaWslNatPortProxyRequired)
    }
    return $false
}

function Test-AlfaUseWslDockerCli {
    return [bool]$script:AlfaUseWslDocker
}

function Resolve-AlfaDockerHeartbeatExec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,
        [string]$WorkingDirectory
    )

    if (-not $script:AlfaUseWslDocker) {
        return @{
            FilePath         = 'docker'
            ArgumentList     = $ArgumentList
            WorkingDirectory = $WorkingDirectory
        }
    }

    $parts = @()
    foreach ($a in $ArgumentList) {
        if ($a -match '\s|"') {
            $parts += '"' + ($a.Replace('"', '\"')) + '"'
        } else {
            $parts += $a
        }
    }
    $dockerLine = 'docker ' + ($parts -join ' ')
    if ($WorkingDirectory) {
        $wslWd = ConvertTo-AlfaWslPath -Path $WorkingDirectory
        $scriptLine = "cd '$wslWd' && $dockerLine"
    } else {
        $scriptLine = $dockerLine
    }

    return @{
        FilePath         = 'wsl.exe'
        ArgumentList     = @('-d', $script:AlfaWslDockerDistro, 'bash', '-lc', $scriptLine)
        WorkingDirectory = $null
    }
}

function Initialize-AlfaDockerCli {
    param([string]$WslDistro = 'Ubuntu')

    # Win10 NAT + portproxy: containers MUST run in WSL Ubuntu, not Docker Desktop.
    # Post-startup runs bash inside WSL; Desktop engine leaves WSL docker ps empty.
    $requireWslEngine = $false
    $natScript = Join-Path $PSScriptRoot 'install-wsl-nat-portproxy.ps1'
    if (Test-Path -LiteralPath $natScript) {
        if (-not (Get-Command Test-AlfaWslNatPortProxyRequired -ErrorAction SilentlyContinue)) {
            . $natScript
        }
        if (Get-Command Test-AlfaWslNatPortProxyRequired -ErrorAction SilentlyContinue) {
            $requireWslEngine = Test-AlfaWslNatPortProxyRequired
        }
    }

    if ($requireWslEngine -and (Test-AlfaWslDockerEngine -Distro $WslDistro)) {
        Enable-AlfaWslDockerCli -Distro $WslDistro
        if (Test-AlfaNativeDockerEngine) {
            Write-Host "Docker CLI: WSL ($WslDistro) - ignoring Docker Desktop (Win10 NAT portproxy requires WSL engine)" -ForegroundColor Yellow
        } else {
            Write-Host "Docker CLI: WSL ($WslDistro) - bind mounts use /mnt/ paths" -ForegroundColor Cyan
        }
        return $true
    }

    if ($requireWslEngine -and (Test-AlfaNativeDockerEngine) -and -not (Test-AlfaWslDockerEngine -Distro $WslDistro)) {
        Write-Host 'Docker CLI: Docker Desktop only - not usable on Win10 NAT (post-startup checks WSL engine)' -ForegroundColor Red
        Write-Host '  Fix: quit Docker Desktop; run deploy/cluster-members/_common/wsl-docker/02-install-docker-wsl-engine.ps1' -ForegroundColor Yellow
        $script:AlfaUseWslDocker = $false
        return $false
    }

    if (Test-AlfaNativeDockerEngine) {
        $script:AlfaUseWslDocker = $false
        Write-Host 'Docker CLI: native docker.exe (Docker Desktop or Windows client)' -ForegroundColor DarkGray
        return $true
    }

    if (Test-AlfaWslDockerEngine -Distro $WslDistro) {
        Enable-AlfaWslDockerCli -Distro $WslDistro
        Write-Host "Docker CLI: WSL ($WslDistro) - bind mounts use /mnt/ paths" -ForegroundColor Cyan
        return $true
    }

    return $false
}

function ConvertTo-AlfaDockerHostPath {
    param([string]$Path)

    if ($script:AlfaUseWslDocker) {
        return ConvertTo-AlfaWslPath -Path $Path
    }
    return ($Path -replace '\\', '/')
}
