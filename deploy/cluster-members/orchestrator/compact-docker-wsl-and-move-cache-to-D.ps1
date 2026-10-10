<#
.SYNOPSIS
    Host orchestrator - compact Docker Desktop WSL2 ext4.vhdx and/or move C:\alfa-ai-cache to D:\ with a junction.
.DESCRIPTION
    Run in Administrator PowerShell from any directory (script resolves paths via $PSScriptRoot).

    Phase A (optional): wsl --shutdown + diskpart compact on Docker's ext4.vhdx (reclaims sparse space).
    Phase B (optional): robocopy cache to D:\, rename old folder, mklink /J so C:\alfa-ai-cache still works.

    New deploy scripts auto-pick a cache root via Get-AlfaWindowsCacheRoot.ps1
    (Get-PSDrive + Win32_LogicalDisk; see docs/WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md).
    This script remains for the legacy C: junction workflow when you already use
    C:\alfa-ai-cache or want a fixed D:\ move without changing ALFA_WINDOWS_CACHE_ROOT.

    Quit Docker Desktop fully before running (tray -> Quit). Start Docker again after compaction.

.PARAMETER SkipCompact
    Do not run diskpart compact (only move cache, or nothing if SkipMoveCache too).
.PARAMETER SkipMoveCache
    Do not relocate alfa-ai-cache (only compact WSL vhdx, or nothing if SkipCompact too).
.PARAMETER CacheSource
    Current cache root (default C:\alfa-ai-cache).
.PARAMETER CacheDestRoot
    Destination directory on D: (default D:\alfa-ai-cache). Junction C:\alfa-ai-cache -> this path.
.PARAMETER DockerVhdxPath
    Override path to ext4.vhdx. Default: $env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx
.PARAMETER NoPause
    Skip "Press Enter after quitting Docker" prompts (for automation).
.EXAMPLE
    .\compact-docker-wsl-and-move-cache-to-D.ps1
.EXAMPLE
    .\compact-docker-wsl-and-move-cache-to-D.ps1 -SkipCompact
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch] $SkipCompact,
    [switch] $SkipMoveCache,
    [string] $CacheSource = 'C:\alfa-ai-cache',
    [string] $CacheDestRoot = 'D:\alfa-ai-cache',
    [string] $DockerVhdxPath = '',
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DockerExt4VhdxPath {
    param([string] $Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) {
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $default = Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'
    if (Test-Path -LiteralPath $default) {
        return (Resolve-Path -LiteralPath $default).Path
    }
    # Older layouts / recursion under wsl\
    $found = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Docker\wsl') -Filter 'ext4.vhdx' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ($found) { return $found }

    # Docker Desktop 4.3x+: docker_data.vhdx under wsl\disk\, or other *.vhdx under %LOCALAPPDATA%\Docker
    $dockerRoot = Join-Path $env:LOCALAPPDATA 'Docker'
    if (-not (Test-Path -LiteralPath $dockerRoot)) {
        return $null
    }
    $named = @()
    foreach ($pat in @('ext4.vhdx', 'docker_data.vhdx')) {
        $named += Get-ChildItem -Path $dockerRoot -Recurse -Filter $pat -ErrorAction SilentlyContinue
    }
    $named = $named | Sort-Object Length -Descending
    $underWsl = $named | Where-Object { $_.FullName -match '\\wsl\\' } | Select-Object -First 1
    if ($underWsl) { return $underWsl.FullName }
    if ($named.Count -gt 0) { return $named[0].FullName }

    $any = Get-ChildItem -Path $dockerRoot -Recurse -Filter '*.vhdx' -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    return $any
}

function Invoke-DiskpartCompact {
    param([string] $VhdxPath)
    $scriptFile = Join-Path $env:TEMP ("alfa-docker-compact-{0}.txt" -f [Guid]::NewGuid().ToString('n'))
    @(
        "select vdisk file=`"$VhdxPath`""
        'attach vdisk readonly'
        'compact vdisk'
        'detach vdisk'
    ) | Set-Content -LiteralPath $scriptFile -Encoding ASCII
    try {
        Write-Host "diskpart: compacting $VhdxPath (may take several minutes)..." -ForegroundColor Cyan
        $p = Start-Process -FilePath 'diskpart.exe' -ArgumentList @('/s', $scriptFile) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            throw "diskpart exit $($p.ExitCode). Check that Docker is quit and WSL is shutdown."
        }
        Write-Host "diskpart: compact finished OK." -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'ERROR: Run PowerShell as Administrator (required for diskpart and mklink /J).' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '== compact-docker-wsl-and-move-cache-to-D (orchestrator) ==' -ForegroundColor Cyan
Write-Host '  Quit Docker Desktop completely (system tray -> Quit) before continuing.' -ForegroundColor Yellow
if (-not $NoPause) {
    Read-Host 'Press Enter after Docker Desktop is fully quit'
}

if (-not $SkipCompact) {
    $vhdx = Get-DockerExt4VhdxPath -Explicit $DockerVhdxPath
    if (-not $vhdx) {
        Write-Host 'WARN: No Docker *.vhdx found under %LOCALAPPDATA%\Docker; skipping compact.' -ForegroundColor Yellow
        Write-Host '      List disks: Get-ChildItem $env:LOCALAPPDATA\Docker -Recurse -Filter *.vhdx | ft FullName,Length' -ForegroundColor DarkYellow
        Write-Host '      Then re-run: .\compact-docker-wsl-and-move-cache-to-D.ps1 -DockerVhdxPath "<full path>"' -ForegroundColor DarkYellow
    }
    else {
        Write-Host "  WSL shutdown..." -ForegroundColor DarkGray
        & wsl.exe --shutdown
        Start-Sleep -Seconds 2
        if ($PSCmdlet.ShouldProcess($vhdx, 'diskpart compact')) {
            Invoke-DiskpartCompact -VhdxPath $vhdx
        }
    }
}
else {
    Write-Host 'Skipping WSL vhdx compact (-SkipCompact).' -ForegroundColor DarkGray
}

if (-not $SkipMoveCache) {
    $src = $CacheSource.TrimEnd('\')
    $dst = $CacheDestRoot.TrimEnd('\')

    if (-not (Test-Path -LiteralPath 'D:\')) {
        throw 'Drive D: not found. Plug/format the SSD or set -CacheDestRoot to an existing drive.'
    }

    $existing = Get-Item -LiteralPath $src -ErrorAction SilentlyContinue
    if ($existing) {
        $isJunction = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isJunction) {
            Write-Host "INFO: $src is already a reparse point (junction/symlink). Skipping cache move." -ForegroundColor Green
            Write-Host '      If this points at the wrong disk, remove the junction manually then re-run.' -ForegroundColor DarkYellow
        }
        else {
            if ($PSCmdlet.ShouldProcess("$src -> $dst", 'robocopy + junction')) {
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                Write-Host "robocopy `"$src`" `"$dst`" /E /COPY:DAT /R:2 /W:2 ..." -ForegroundColor Cyan
                & robocopy.exe $src $dst /E /COPY:DAT /R:2 /W:2
                $rc = $LASTEXITCODE
                if ($rc -ge 8) {
                    throw "robocopy failed with exit code $rc"
                }
                $bak = "${src}.bak-pre-D-move"
                if (Test-Path -LiteralPath $bak) {
                    throw "Backup path exists: $bak - remove it or rename manually, then re-run."
                }
                Rename-Item -LiteralPath $src -NewName (Split-Path -Leaf $bak)
                cmd /c mklink /J "$src" "$dst"
                if ($LASTEXITCODE -ne 0) {
                    throw 'mklink /J failed - restore by renaming the .bak folder back to alfa-ai-cache'
                }
                Write-Host "OK: junction $src -> $dst" -ForegroundColor Green
                Write-Host "     After you verify Docker loads tarballs, delete: $bak" -ForegroundColor DarkYellow
            }
        }
    }
    else {
        Write-Host "INFO: $src does not exist yet - creating $dst and junction for future cache." -ForegroundColor Cyan
        if ($PSCmdlet.ShouldProcess($src, 'create empty junction')) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $dst 'docker-images') -Force | Out-Null
            cmd /c mklink /J "$src" "$dst"
            if ($LASTEXITCODE -ne 0) { throw 'mklink /J failed' }
            Write-Host "OK: empty junction $src -> $dst (docker-images subfolder ready)." -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host 'Docker Desktop: add D:\ under Settings -> Resources -> File Sharing if you bind-mount from D: elsewhere.' -ForegroundColor DarkGray
}
else {
    Write-Host 'Skipping cache move (-SkipMoveCache).' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Done. Start Docker Desktop, then: docker version' -ForegroundColor Green
Write-Host ''
