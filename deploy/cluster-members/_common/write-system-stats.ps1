<#
.SYNOPSIS
    Write a plain-text hardware / OS inventory file for Blackwell Win workers.
.DESCRIPTION
    Dot-source from deploy.ps1 (gaming-worker-b-249, gaming-worker-c-59, gaming-worker-a-219). Matches the
    capture commands documented in docs/NODE_INVENTORY.md (Windows section).
.NOTES
    Output path: <WorkerDir>\system-stats-<MachineName>.txt (UTF-8, no BOM).
#>

function Write-AlfaClusterSystemStats {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkerDir,

        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [Parameter(Mandatory = $true)]
        [string]$MachineIP
    )

    if (-not (Test-Path -LiteralPath $WorkerDir)) {
        Write-Warning "Write-AlfaClusterSystemStats: WorkerDir does not exist: $WorkerDir"
        return
    }

    $outPath = Join-Path $WorkerDir ("system-stats-{0}.txt" -f $MachineName)
    $lines = [System.Collections.Generic.List[string]]::new()

    $utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lines.Add('# ALFa AI -- Windows system stats (operator capture)')
    $lines.Add("# Written: $utc (UTC)")
    $lines.Add("# Cluster identity: MachineName=$MachineName  LAN=$MachineIP")
    $lines.Add('')

    $lines.Add('## Session')
    $lines.Add("COMPUTERNAME=$env:COMPUTERNAME")
    $lines.Add("USERDOMAIN=$env:USERDOMAIN")
    $lines.Add('')

    $lines.Add('## OS')
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $lines.Add("Caption=$($os.Caption)")
        $lines.Add("Version=$($os.Version)")
        $lines.Add("Build=$($os.BuildNumber)")
        $lines.Add("OSArchitecture=$($os.OSArchitecture)")
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $lines.Add("TotalPhysicalMemory_GB=$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2))")
        $lines.Add("Manufacturer=$($cs.Manufacturer)")
        $lines.Add("Model=$($cs.Model)")
    } catch {
        $lines.Add("(Win32_OperatingSystem / Win32_ComputerSystem query failed: $($_.Exception.Message))")
    }
    $lines.Add('')

    $lines.Add('## CPU (Get-CimInstance Win32_Processor)')
    try {
        Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | ForEach-Object {
            $lines.Add("Name=$($_.Name)")
            $lines.Add("NumberOfCores=$($_.NumberOfCores)")
            $lines.Add("NumberOfLogicalProcessors=$($_.NumberOfLogicalProcessors)")
            $lines.Add("MaxClockSpeed_MHz=$($_.MaxClockSpeed)")
        }
    } catch {
        $lines.Add("(Win32_Processor query failed: $($_.Exception.Message))")
    }
    $lines.Add('')

    $lines.Add('## Memory')
    try {
        $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
        $lines.Add("TotalPhysicalMemory_GB=$ramGb")
    } catch {
        $lines.Add("(memory query failed: $($_.Exception.Message))")
    }
    $lines.Add('')

    $lines.Add('## Fixed drives (Get-CimInstance Win32_LogicalDisk DriveType=3)')
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
            ForEach-Object {
                $free = [math]::Round($_.FreeSpace / 1GB, 2)
                $size = [math]::Round($_.Size / 1GB, 2)
                $lines.Add("$($_.DeviceId) size_GB=$size free_GB=$free")
            }
    } catch {
        $lines.Add("(Win32_LogicalDisk query failed: $($_.Exception.Message))")
    }
    try {
        $c = Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue
        if ($c) {
            $lines.Add("Get-PSDrive_C_Free_GB=$([math]::Round($c.Free / 1GB, 2))")
        }
    } catch { }
    $lines.Add('')

    $lines.Add('## GPU (nvidia-smi)')
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $ns = & nvidia-smi 2>&1 | Out-String
        if ($ns) { $lines.Add($ns.TrimEnd()) } else { $lines.Add('(nvidia-smi returned no output)') }
    } catch {
        $lines.Add("(nvidia-smi failed: $($_.Exception.Message))")
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $lines.Add('')

    $lines.Add('## systeminfo (summary)')
    try {
        $si = & systeminfo.exe 2>&1 | Out-String
        if ($si) {
            $lines.Add($si.TrimEnd())
        }
    } catch {
        $lines.Add("(systeminfo failed: $($_.Exception.Message))")
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($outPath, $lines.ToArray(), $utf8NoBom)
    Write-Host "  System stats written: $outPath" -ForegroundColor Green
}
