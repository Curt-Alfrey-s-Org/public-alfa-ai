#Requires -Version 5.1
<#
.SYNOPSIS
    Phase H: deploy orchestrator rpc-server shard :31350 for 27B/35B RPC pool.
.EXAMPLE
    .\deploy-grev27-pool-shard.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'
$Llc = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$EnvPath = Join-Path $Llc '.env.rpc'

function ConvertTo-AlfaWslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $resolved = (Resolve-Path -LiteralPath $WinPath).Path
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    throw "Not a Windows path: $WinPath"
}

function Invoke-AlfaWslBashScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$EnvPrefix = ''
    )
    $wslScript = ConvertTo-AlfaWslPath -WinPath $ScriptPath
    wsl.exe -d Ubuntu bash -lc "${EnvPrefix}bash '$wslScript'"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL bash failed (exit $LASTEXITCODE): $ScriptPath"
    }
}

Write-Host '== Phase H: Docker preflight on orchestrator ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-docker-engine.sh') -EnvPrefix 'HOST_LABEL=93 '

Write-Host '== Phase H: stop local llama / free GPU on orchestrator ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'inference-stop-local.sh') -EnvPrefix 'inference_STOP_MODE=shard HOST_LABEL=93 '
# orchestrator 3060 drives the Win11 desktop; WDDM + Cursor/Chrome often 2.5-3.5 GiB (2026-09-03: 2964 MiB).
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-gpu-empty.sh') -EnvPrefix 'HOST_LABEL=93 MAX_MIB=4096 '

$shardBlock = @"
# Phase H: orchestrator rpc-server shard for 27B/35B pool (:31350)
RPC_PORT=31350
CUDA_VISIBLE_DEVICES=0
"@

if (-not (Test-Path (Split-Path $EnvPath))) {
    New-Item -ItemType Directory -Path (Split-Path $EnvPath) -Force | Out-Null
}
Set-Content -Path $EnvPath -Value $shardBlock -Encoding ASCII
Write-Host "Wrote orchestrator shard env to $EnvPath" -ForegroundColor Green

. (Join-Path $Common 'deploy-llamacpp-rpc.ps1')
Invoke-AlfaLlamacppRpcDeploy -Role Shard -RepoDir $RepoDir -EnvFileRpc $EnvPath

Write-Host '== Phase H: LAN firewall for inference shard :31350 (WSL mirrored Hyper-V rules) ==' -ForegroundColor Cyan
$fwInstall = Join-Path $Common 'install-wsl-lan-firewall.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not (Test-Path -LiteralPath $fwInstall)) {
    throw "Missing firewall install script: $fwInstall"
}
. $fwInstall
if ($isAdmin) {
    Install-AlfaWslLanFirewall -Profile 'operator-93' -RepoRoot $RepoDir
} elseif (-not (Test-AlfaWslLanFirewallProfileReady -Profile 'operator-93' -RequiredPorts @(31350))) {
    $fix = Get-AlfaWslLanFirewallInstallCommand -Profile 'operator-93' -RepoRoot $RepoDir
    throw @(
        'FAIL: Hyper-V firewall rule for orchestrator :31350 not found (non-Admin session).',
        'Run once from Administrator PowerShell as operator (docs/WINDOWS_WSL_DOCKER_ENGINE.md):',
        "  $fix"
    ) -join "`n"
}

Write-Host '== Phase H: LAN reachability check (orchestrator from WSL) ==' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ncExit = 1
try {
    # nc -z prints "Connection to ... succeeded!" to stderr even on success; with
    # $ErrorActionPreference = 'Stop' that native stderr write becomes a
    # terminating error before 2>$null can suppress it (same class of bug as the
    # git/docker stderr issue documented in Invoke-WithLog.ps1). Flip to
    # 'Continue' for this one native call and check $LASTEXITCODE instead.
    $null = wsl.exe -d Ubuntu bash -lc 'nc -z -w 3 orchestrator 31350' 2>&1
    $ncExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($ncExit -ne 0) {
    $fix = Get-AlfaWslLanFirewallInstallCommand -Profile 'operator-93' -RepoRoot $RepoDir
    throw @(
        'FAIL: orchestrator is not reachable on LAN (hub verify uses mgmt IP, not WSL loopback).',
        'Confirm .wslconfig mirrored + firewall=true, then wsl --shutdown.',
        'Re-run WSL LAN firewall install (Administrator as operator):',
        "  $fix"
    ) -join "`n"
}
Write-Host '  OK orchestrator reachable on LAN' -ForegroundColor Green

Write-Host 'deploy-grev27-pool-shard OK on orchestrator' -ForegroundColor Green
Write-Host 'Verify from hub: nc -zv orchestrator 31350' -ForegroundColor Green
