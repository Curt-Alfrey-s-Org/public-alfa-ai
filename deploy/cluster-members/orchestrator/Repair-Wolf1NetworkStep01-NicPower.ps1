#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Step 1: Reduce DRIVER_POWER_STATE_FAILURE (0x9F) and NIC link-flap risk on orchestrator.

.DESCRIPTION
  Microsoft basic 0x9F guidance: disable power saving on adapters and reduce
  PCIe ASPM while diagnosing. See:
  https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x9f--driver-power-state-failure
  Device Manager "Allow the computer to turn off this device to save power"
  is WMI MSPower_DeviceEnable.Enable (root\wmi). See:
  https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/wmi-and-the-power-management-tab

.NOTES
  Elevated Administrator PowerShell as operator. A normal operator window cannot read
  the WMI instances. Does not change IP, bridge, or WSL.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ("[Repair-Step01] " + $msg)
}

Write-Step "Intel / bridge-class physical adapters:"
Get-NetAdapter -Physical |
    Where-Object { $_.InterfaceDescription -match 'Intel|Ethernet Controller X540|Network Bridge' } |
    Format-Table Name, Status, InterfaceDescription, DriverVersion, DriverDate -AutoSize

Write-Step "Disabling MSPower_DeviceEnable.Enable (allow power-off) for Intel X540 devices..."
$changed = 0
$alreadyOff = 0
$powerRows = @()
try {
    $powerRows = @(Get-CimInstance -ClassName MSPower_DeviceEnable -Namespace root/wmi -ErrorAction Stop)
} catch {
    Write-Step ("WARN: MSPower_DeviceEnable query failed: " + $_.Exception.Message)
    Write-Step "WARN: X540 power checkbox is not exposed while Ethernet 2 and Ethernet 5 are Network Bridge members."
    Write-Step "WARN: Get-NetAdapterPowerManagement returns Windows error 31 on those members. Leaving the bridge up."
}
foreach ($row in $powerRows) {
    if ($row.InstanceName -notmatch 'VEN_8086') {
        continue
    }
    if ($row.InstanceName -notmatch 'DEV_1528') {
        continue
    }
    $label = $row.InstanceName.Substring(0, [Math]::Min(80, $row.InstanceName.Length))
    if ($row.Enable -eq $false) {
        $alreadyOff++
        Write-Step ("Already off: " + $label)
        continue
    }
    Set-CimInstance -InputObject $row -Property @{ Enable = $false } | Out-Null
    $changed++
    Write-Step ("Disabled power-off: " + $label)
}
Write-Step ("MSPower_DeviceEnable rows updated: " + $changed + "; already off: " + $alreadyOff)

Write-Step "Setting PCI Express Link State Power Management to Off on AC (diagnostic)..."
$scheme = (powercfg /GETACTIVESCHEME) -replace '.*GUID: ([a-f0-9-]+).*', '$1'
if ($scheme -match '^[a-f0-9-]{36}$') {
    # ASPM 0 = Off. Subgroup GUID SUB_PCIEXPRESS, setting ASPM
    powercfg /SETACVALUEINDEX $scheme SUB_PCIEXPRESS ASPM 0 | Out-Null
    powercfg /SETACTIVE $scheme | Out-Null
    Write-Step "PCIe ASPM set Off for active scheme $scheme"
} else {
    Write-Step "WARN: Could not parse active power scheme; set PCIe ASPM Off manually in Power Options."
}

Write-Step "Prevent sleep on AC while diagnosing (Control Panel equivalent)..."
if ($scheme -match '^[a-f0-9-]{36}$') {
    powercfg /CHANGE monitor-timeout-ac 0 | Out-Null
    powercfg /CHANGE standby-timeout-ac 0 | Out-Null
    powercfg /CHANGE hibernate-timeout-ac 0 | Out-Null
    Write-Step "AC sleep/monitor timeouts set to 0 for active scheme"
}

Write-Step "Done. Reboot recommended before next cluster start."
