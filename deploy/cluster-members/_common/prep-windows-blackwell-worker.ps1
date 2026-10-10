<#
.SYNOPSIS
    One-time (or pre-deploy) prep for Windows Blackwell workers (gaming-a/gaming-c/gaming-b).

.DESCRIPTION
    Lessons from gaming-worker-a (gaming-a) rollout - run as the **normal Windows login**
    (not Admin) before build-start:

1. Map **H:/Y:/Z:** to hub (`hub`) via IP + dedicated SMB user (not operator).
      Stores credentials in Windows Credential Manager (`cmdkey`) so **SSH and
      scheduled tasks** can reconnect without a password prompt.
      2. Verify cuda-blackwell bitsandbytes wheel on Y:.
      3. Strip CRLF from shell scripts / env files (Windows git checkout).

    hub one-time (operator on hub): create a local SMB user matching this
    host (e.g. Corey, gaming-worker-c, gaming-worker-b), grant read on petals-wheels / huggingface /
    docker-images datasets. See README - hub SMB user.

    Copy commands from Notepad - chat apps may eat ``\\`` in UNC paths.

.PARAMETER MemberFolder
    e.g. gaming-worker-a-219, gaming-worker-c-59, gaming-worker-b-249

.PARAMETER SmbUser
    hub local SMB username (defaults to $env:USERNAME).

.PARAMETER hubIp
    Default hub

.PARAMETER inferenceOnly
    RPC shard prep only (gaming-worker-a gaming-a today): map H: docker-images, verify
    llamacpp hub tarball. Skips Petals bitsandbytes wheel check on Y:.

.EXAMPLE
    cd C:\Users\Corey\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File `
      .\deploy\cluster-members\_common\prep-windows-blackwell-worker.ps1 `
      -MemberFolder gaming-worker-a-219 -SmbUser Corey -inferenceOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MemberFolder,
    [string]$hubIp = 'hub',
    [string]$SmbUser = $env:USERNAME,
    [string]$SmbPassword,
    [string]$RepoRoot,
    [switch]$inferenceOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-AlfaFileToLf {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $text = [IO.File]::ReadAllText($Path)
    $lf = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($lf -ne $text) {
        [IO.File]::WriteAllText($Path, $lf)
        Write-Host "  CRLF->LF: $Path" -ForegroundColor DarkGray
    }
}

function Get-AlfaEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $line = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Key))=" } |
        Select-Object -First 1
    if (-not $line) { return '' }
    return (($line -split '=', 2)[1]).Trim()
}

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

Write-Host ''
Write-Host "== prep-windows-blackwell-worker: $MemberFolder ==" -ForegroundColor Cyan
Write-Host "  RepoRoot  : $RepoRoot"
Write-Host "  hubIp : $hubIp"
Write-Host "  SmbUser   : $SmbUser"
Write-Host ''

if (-not $SmbPassword) {
    $sec = Read-Host "hub SMB password for $SmbUser" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $SmbPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

Write-Host '== SMB drive maps (IP-based; run as normal user) ==' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # No existing session is OK - net.exe writes to stderr and triggers Stop otherwise.
    & net use "\\$hubIp\IPC$" /delete /y 2>$null | Out-Null
    & net use * /delete /y 2>$null | Out-Null
    & cmdkey /delete:$hubIp 2>$null | Out-Null
    $cmdkeyOut = & cmdkey /add:$hubIp /user:$SmbUser /pass:$SmbPassword 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "cmdkey failed for ${SmbUser}@${hubIp}: $cmdkeyOut"
    }
} finally {
    $ErrorActionPreference = $prevEap
}

$drivePairs = if ($inferenceOnly) {
    @(@{ Letter = 'H'; Share = 'docker-images' })
} else {
    @(
        @{ Letter = 'Y'; Share = 'petals-wheels' },
        @{ Letter = 'Z'; Share = 'huggingface' },
        @{ Letter = 'H'; Share = 'docker-images' }
    )
}
foreach ($pair in $drivePairs) {
    $drive = "$($pair.Letter):"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # No existing Y:/Z: map is OK - net.exe stderr trips Stop otherwise.
        & net use $drive /delete /y 2>$null | Out-Null
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $unc = "\\$hubIp\$($pair.Share)"
    $mapOut = & net use $drive $unc /persistent:yes 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SMB map failed: $drive -> $unc ($mapOut)"
    }
    if (-not (Test-Path "${drive}\")) {
        throw "SMB map failed: $drive -> $unc (check hub SMB user ACL on $($pair.Share))"
    }
    Write-Host "  $drive -> $unc" -ForegroundColor Green
}

if ($inferenceOnly) {
    $rpcTar = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
    if (-not (Test-Path -LiteralPath "H:\$rpcTar")) {
        throw "Missing H:\$rpcTar - verify hub docker-images on $hubIp"
    }
    Write-Host "  hub OK   : H:\$rpcTar" -ForegroundColor Green
} else {
    $bnb = Get-ChildItem -Path 'Y:\cuda-blackwell' -Filter 'bitsandbytes-0.45*.whl' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $bnb) {
        throw "Missing bitsandbytes>=0.45 on Y:\cuda-blackwell - verify hub wheels at \\hub\petals-wheels\cuda-blackwell"
    }
    Write-Host "  wheel OK : $($bnb.Name)" -ForegroundColor Green
}
Write-Host ''

Write-Host '== CRLF cleanup ==' -ForegroundColor Cyan
$memberEnv = Join-Path $RepoRoot "deploy\cluster-members\$MemberFolder\.env.worker"
if (Test-Path -LiteralPath $memberEnv) {
    Convert-AlfaFileToLf -Path $memberEnv
    Write-Host "  Normalized: $memberEnv" -ForegroundColor Green
}
Write-Host ''

Write-Host '== reminders ==' -ForegroundColor Cyan
if ($inferenceOnly) {
    $cacheRootScript = Join-Path $RepoRoot 'deploy\cluster-members\_common\Get-AlfaWindowsCacheRoot.ps1'
    $exampleDockerCache = '<Get-AlfaWindowsCacheRoot>\docker-images'
    if (Test-Path -LiteralPath $cacheRootScript) {
        . $cacheRootScript
        if (Get-Command Get-AlfaWindowsDockerImagesCacheDir -ErrorAction SilentlyContinue) {
            $exampleDockerCache = Get-AlfaWindowsDockerImagesCacheDir
        }
    }
    Write-Host '  Seed local cache once (so orchestrator SSH deploy works without console H:):'
    Write-Host "    New-Item -Force -ItemType Directory $exampleDockerCache | Out-Null"
    Write-Host "    Copy-Item H:\alfa-llamacpp-rpc-cuda128-b10355.tar.gz $exampleDockerCache\"
} else {
    Write-Host '  Docker Desktop -> File sharing: allow Y: and Z:'
}
Write-Host '  Optional (Admin once): hosts file line: hub hub'
Write-Host '  Deploy as normal user; build-start opens firewall (may prompt Admin)'
Write-Host ''
