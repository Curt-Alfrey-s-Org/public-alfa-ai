<#
.SYNOPSIS
    Run bash scripts in WSL Ubuntu with VM recovery on Wsl/Service/E_UNEXPECTED.

.DESCRIPTION
    Windows workers (orchestrator orchestrator, shard deploy scripts) invoke inference bash via
    wsl.exe. A stuck WSL VM can fail instantly with exit -1 and no script output
    (Wsl/Service/E_UNEXPECTED). Microsoft documents wsl --shutdown as the first
    recovery step:
    https://learn.microsoft.com/en-us/windows/wsl/troubleshooting

    Dot-source from Invoke-AlfaAiCluster.ps1 or deploy scripts; call
    Invoke-AlfaWslBashScript instead of duplicating wsl.exe wrappers.

.NOTES
    Does not restart the LxssManager service (requires Administrator).
#>

Set-StrictMode -Version Latest

$script:AlfaWslDefaultDistro = 'Ubuntu'

function Write-AlfaWslLog {
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    if (Get-Command Write-AlfaLog -ErrorAction SilentlyContinue) {
        Write-AlfaLog -Level $Level -Message $Message
        return
    }
    Write-Host "[$Level] $Message"
}

function ConvertTo-AlfaWslWinPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $resolved = (Resolve-Path -LiteralPath $WinPath).Path
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    throw "Not a Windows path: $WinPath"
}

function Test-AlfaWslDistroResponsive {
    param([string]$Distro = $script:AlfaWslDefaultDistro)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $out = & wsl.exe -d $Distro -e echo ALFA_WSL_OK 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev

    if ($code -ne 0) {
        return $false
    }
    $text = ($out | ForEach-Object { "$_" }) -join ''
    return ($text -match 'ALFA_WSL_OK')
}

function Repair-AlfaWslVm {
    param(
        [string]$Distro = $script:AlfaWslDefaultDistro,
        [int]$ShutdownWaitSec = 10
    )

    Write-AlfaWslLog -Level WARN -Message "WSL ($Distro) unresponsive; running wsl --shutdown then re-probing"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & wsl.exe --shutdown 2>&1 | Out-Null
    $ErrorActionPreference = $prev
    Start-Sleep -Seconds $ShutdownWaitSec
    return (Test-AlfaWslDistroResponsive -Distro $Distro)
}

function Ensure-AlfaWslDistroResponsive {
    param(
        [string]$Distro = $script:AlfaWslDefaultDistro,
        [int]$MaxRecoveries = 2,
        [int]$ShutdownWaitSec = 10
    )

    if (Test-AlfaWslDistroResponsive -Distro $Distro) {
        return
    }

    $recovered = $false
    for ($i = 1; $i -le $MaxRecoveries; $i++) {
        Write-AlfaWslLog -Level INFO -Message "WSL recovery attempt $i / $MaxRecoveries"
        if (Repair-AlfaWslVm -Distro $Distro -ShutdownWaitSec $ShutdownWaitSec) {
            Write-AlfaWslLog -Level OK -Message "WSL ($Distro) responsive after recovery"
            $recovered = $true
            break
        }
    }

    if (-not $recovered) {
        throw @(
            "WSL distro '$Distro' still unresponsive after $MaxRecoveries wsl --shutdown recoveries.",
            'Official troubleshooting: https://learn.microsoft.com/en-us/windows/wsl/troubleshooting',
            'Check C: free space and .wslconfig per docs/WINDOWS_WSL_DOCKER_ENGINE.md.',
            'If shutdown does not help: Administrator PowerShell Restart-Service LxssManager, then retry.'
        ) -join [Environment]::NewLine
    }
}

function Test-AlfaWslBashExitNeedsRecovery {
    param([int]$ExitCode)
    if ($ExitCode -eq 0) {
        return $false
    }
    # PS 5.1 may surface wsl.exe -1 as 4294967295 (unsigned 32-bit).
    if ($ExitCode -eq -1 -or $ExitCode -eq 4294967295) {
        return $true
    }
    return $false
}

function Invoke-AlfaWslBashScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$EnvPrefix = '',
        [string]$Distro = $script:AlfaWslDefaultDistro,
        [int]$WslRecoveries = 2,
        [int]$ShutdownWaitSec = 10
    )

    Ensure-AlfaWslDistroResponsive -Distro $Distro -MaxRecoveries $WslRecoveries -ShutdownWaitSec $ShutdownWaitSec

    $wslScript = ConvertTo-AlfaWslWinPath -WinPath $ScriptPath
    $maxRuns = 2

    for ($run = 1; $run -le $maxRuns; $run++) {
        Write-AlfaWslLog -Level CMD -Message "wsl bash $wslScript"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        wsl.exe -d $Distro bash -lc "${EnvPrefix}bash '$wslScript'"
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $prev

        if ($exit -eq 0) {
            return
        }

        if ($run -lt $maxRuns -and (Test-AlfaWslBashExitNeedsRecovery -ExitCode $exit)) {
            Write-AlfaWslLog -Level WARN -Message "WSL bash failed (exit $exit) before script ran; recovering and retrying once"
            Ensure-AlfaWslDistroResponsive -Distro $Distro -MaxRecoveries $WslRecoveries -ShutdownWaitSec $ShutdownWaitSec
            continue
        }

        throw "WSL bash failed (exit $exit): $ScriptPath"
    }
}
