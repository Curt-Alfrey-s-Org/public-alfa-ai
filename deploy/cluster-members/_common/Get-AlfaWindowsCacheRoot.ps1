<#
.SYNOPSIS
    Pick a Windows local cache root under *:\alfa-ai-cache (avoid filling C:).

.DESCRIPTION
    Shared helper for ALFa cluster Windows gaming/dev hosts (orchestrator, gaming-a, gaming-c, gaming-b).
    Selects a fixed NTFS drive that is not 80%+ full, prefers G: when eligible,
    else the drive with the most free space. Creates the cache directory if missing.

    ALFa scope only: always *:\alfa-ai-cache (models, trainer artifacts, hub tarballs).
    Never games, Steam, or unrelated Windows folders.

    Env override: ALFA_WINDOWS_CACHE_ROOT (full path ending in \alfa-ai-cache).

    Official references:
    - Get-CimInstance: https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance
    - Win32_LogicalDisk: https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logicaldisk

.EXAMPLE
    . .\Get-AlfaWindowsCacheRoot.ps1
    $root = Get-AlfaWindowsCacheRoot
    $dockerImages = Join-Path $root 'docker-images'

.EXAMPLE
    Get-AlfaWindowsCacheRoot -RequiredFreeBytes 50GB
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:AlfaCacheUsedPercentMax = 80
$script:AlfaCacheMinFreeBytesDefault = 30GB
$script:AlfaCacheFolderName = 'alfa-ai-cache'

function Get-AlfaWindowsCacheDriveUsagePercent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uint64]$SizeBytes,

        [Parameter(Mandatory)]
        [uint64]$FreeBytes
    )

    if ($SizeBytes -eq 0) {
        return 100.0
    }
    $used = $SizeBytes - [double]$FreeBytes
    return ($used / [double]$SizeBytes) * 100.0
}

function Get-AlfaWindowsFixedNtfsDisks {
    [CmdletBinding()]
    param()

    try {
        return @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
            Where-Object { $_.FileSystem -eq 'NTFS' -and $_.DeviceID -match '^[A-Z]:$' })
    } catch {
        throw "Get-AlfaWindowsCacheRoot: Win32_LogicalDisk query failed: $($_.Exception.Message)"
    }
}

function Test-AlfaWindowsDriveEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimInstance]$Disk,

        [Parameter(Mandatory)]
        [uint64]$MinimumFreeBytes
    )

    $usage = Get-AlfaWindowsCacheDriveUsagePercent -SizeBytes $Disk.Size -FreeBytes $Disk.FreeSpace
    if ($usage -ge $script:AlfaCacheUsedPercentMax) {
        return $false
    }
    if ($Disk.FreeSpace -lt $MinimumFreeBytes) {
        return $false
    }
    return $true
}

function Assert-AlfaDriveNotTooFull {
    <#
    .SYNOPSIS
        Throws if the drive backing TargetPath is 80%+ full.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    $root = [System.IO.Path]::GetPathRoot($TargetPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Assert-AlfaDriveNotTooFull: could not resolve drive for path '$TargetPath'"
    }

    $letter = $root.TrimEnd('\').ToUpperInvariant()
    if ($letter.Length -ne 2 -or -not $letter.EndsWith(':')) {
        throw "Assert-AlfaDriveNotTooFull: unexpected drive root '$root' for path '$TargetPath'"
    }

    $disk = Get-AlfaWindowsFixedNtfsDisks | Where-Object { $_.DeviceID -eq $letter } | Select-Object -First 1
    if (-not $disk) {
        throw "Assert-AlfaDriveNotTooFull: no fixed NTFS disk found for drive $letter"
    }

    $usage = Get-AlfaWindowsCacheDriveUsagePercent -SizeBytes $disk.Size -FreeBytes $disk.FreeSpace
    if ($usage -ge $script:AlfaCacheUsedPercentMax) {
        $freeGb = [math]::Round($disk.FreeSpace / 1GB, 2)
        throw "Assert-AlfaDriveNotTooFull: drive $letter is ${usage}% full (free ${freeGb} GB); limit is $($script:AlfaCacheUsedPercentMax)%"
    }
}

function Join-AlfaRemoteWinPath {
    <#
    .SYNOPSIS
        Join a Windows path that may live on another host (drive need not exist here).
    .DESCRIPTION
        Windows PowerShell 5.1 Join-Path requires the Path drive to exist on this
        host (Join-Path Example 5). Use Path.Combine for remote strings such as
        G:\alfa-ai-cache on gaming-c when this script runs on orchestrator.

        Official:
        - Join-Path: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/join-path
        - Path.Combine: https://learn.microsoft.com/en-us/dotnet/api/system.io.path.combine
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Parent,

        [Parameter(Mandatory)]
        [string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Parent)) {
        throw 'Join-AlfaRemoteWinPath: Parent is empty'
    }
    if ([string]::IsNullOrWhiteSpace($Child)) {
        throw 'Join-AlfaRemoteWinPath: Child is empty'
    }
    return [System.IO.Path]::Combine($Parent.TrimEnd(), $Child)
}

function ConvertTo-AlfaWindowsCacheWslPath {
    <#
    .SYNOPSIS
        Map a Windows path to WSL /mnt/<drive>/... (official WSL mount layout).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WinPath
    )

    $resolved = $WinPath
    if (Test-Path -LiteralPath $WinPath) {
        $resolved = (Resolve-Path -LiteralPath $WinPath).Path
    }
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    throw "ConvertTo-AlfaWindowsCacheWslPath: not a Windows path: $WinPath"
}

function Test-AlfaWindowsCacheRootPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $leaf = Split-Path -Leaf ($Path.TrimEnd('\'))
    if ($leaf -ne $script:AlfaCacheFolderName) {
        throw "Get-AlfaWindowsCacheRoot: path must end in \$($script:AlfaCacheFolderName) (ALFa models/trainer only); got '$Path'"
    }
}

function Get-AlfaWindowsCacheRoot {
    [CmdletBinding()]
    param(
        [uint64]$RequiredFreeBytes = 0
    )

    $minimumFreeBytes = $script:AlfaCacheMinFreeBytesDefault
    if ($RequiredFreeBytes -gt $minimumFreeBytes) {
        $minimumFreeBytes = $RequiredFreeBytes
    }

    $envOverride = $env:ALFA_WINDOWS_CACHE_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envOverride)) {
        $cacheRoot = $envOverride.Trim()
        Test-AlfaWindowsCacheRootPath -Path $cacheRoot
        $driveRoot = [System.IO.Path]::GetPathRoot($cacheRoot)
        if ([string]::IsNullOrWhiteSpace($driveRoot)) {
            throw "Get-AlfaWindowsCacheRoot: could not resolve drive for ALFA_WINDOWS_CACHE_ROOT '$cacheRoot'"
        }
        $letter = $driveRoot.TrimEnd('\').ToUpperInvariant()
        $disk = Get-AlfaWindowsFixedNtfsDisks | Where-Object { $_.DeviceID -eq $letter } | Select-Object -First 1
        if (-not $disk) {
            throw "Get-AlfaWindowsCacheRoot: no fixed NTFS disk found for ALFA_WINDOWS_CACHE_ROOT drive $letter"
        }
        if (-not (Test-AlfaWindowsDriveEligible -Disk $disk -MinimumFreeBytes $minimumFreeBytes)) {
            $usage = Get-AlfaWindowsCacheDriveUsagePercent -SizeBytes $disk.Size -FreeBytes $disk.FreeSpace
            $freeGb = [math]::Round($disk.FreeSpace / 1GB, 2)
            $minGb = [math]::Round($minimumFreeBytes / 1GB, 0)
            throw ("Get-AlfaWindowsCacheRoot: ALFA_WINDOWS_CACHE_ROOT drive {0} is {1:N1}% full (free {2} GB); need < {3}% used and at least {4} GB free" -f $letter, $usage, $freeGb, $script:AlfaCacheUsedPercentMax, $minGb)
        }
        try {
            New-Item -ItemType Directory -Path $cacheRoot -Force -ErrorAction Stop | Out-Null
            Assert-AlfaDriveNotTooFull -TargetPath $cacheRoot
            return $cacheRoot
        } catch {
            throw "Get-AlfaWindowsCacheRoot: ALFA_WINDOWS_CACHE_ROOT '$cacheRoot' failed: $($_.Exception.Message)"
        }
    }

    $disks = Get-AlfaWindowsFixedNtfsDisks
    if ($disks.Count -eq 0) {
        throw 'Get-AlfaWindowsCacheRoot: no fixed NTFS drives found'
    }

    $eligible = @($disks | Where-Object { Test-AlfaWindowsDriveEligible -Disk $_ -MinimumFreeBytes $minimumFreeBytes })
    if ($eligible.Count -eq 0) {
        throw "Get-AlfaWindowsCacheRoot: no fixed NTFS drive under $($script:AlfaCacheUsedPercentMax)% used with at least $([math]::Round($minimumFreeBytes / 1GB, 0)) GB free"
    }

    $nonC = @($eligible | Where-Object { $_.DeviceID -ne 'C:' })
    if ($nonC.Count -gt 0) {
        $eligible = $nonC
    }

    $preferred = @($eligible | Where-Object { $_.DeviceID -eq 'G:' })
    if ($preferred.Count -gt 0) {
        $chosen = $preferred[0]
    } else {
        $chosen = $eligible | Sort-Object -Property FreeSpace -Descending | Select-Object -First 1
    }

    $cacheRoot = Join-Path $chosen.DeviceID $script:AlfaCacheFolderName
    try {
        New-Item -ItemType Directory -Path $cacheRoot -Force -ErrorAction Stop | Out-Null
        Assert-AlfaDriveNotTooFull -TargetPath $cacheRoot
        return $cacheRoot
    } catch {
        throw "Get-AlfaWindowsCacheRoot: failed to prepare '$cacheRoot': $($_.Exception.Message)"
    }
}

function Assert-AlfaWindowsCacheRootHelperLoaded {
    <#
    .SYNOPSIS
        Throws when Get-AlfaWindowsCacheRoot.ps1 was not dot-sourced.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command Get-AlfaWindowsDockerImagesCacheDir -ErrorAction SilentlyContinue) {
        return
    }
    throw @(
        'Missing Get-AlfaWindowsCacheRoot.ps1.',
        'Dot-source deploy\cluster-members\_common\Get-AlfaWindowsCacheRoot.ps1',
        'or set ALFA_WINDOWS_CACHE_ROOT to a full path ending in \alfa-ai-cache.'
    ) -join ' '
}

function Get-AlfaWindowsDockerImagesCacheDir {
    <#
    .SYNOPSIS
        Returns <cache-root>\docker-images for hub tarball staging.
    #>
    [CmdletBinding()]
    param()

    return Join-Path (Get-AlfaWindowsCacheRoot) 'docker-images'
}
