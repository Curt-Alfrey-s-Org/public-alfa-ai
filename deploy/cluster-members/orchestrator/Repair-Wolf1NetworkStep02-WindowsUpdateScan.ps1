#Requires -Version 5.1
<#
.SYNOPSIS
  Step 2: Trigger Windows Update driver scan (Microsoft distribution path).

.DESCRIPTION
  Drivers should come from Windows Update / Optional updates first:
  https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/understanding-windows-update-automatic-and-optional-rules-for-driver-distribution

  Runs UsoClient scan (documented update orchestrator). Operator installs any
  Intel/Ethernet/NVIDIA optional driver updates from Settings when listed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Write-Host "[Repair-Step02] Adapter drivers before update:"
Get-NetAdapter -Physical |
    Where-Object { $_.InterfaceDescription -match 'Intel|Ethernet Controller X540|NVIDIA|' } |
    Format-Table Name, InterfaceDescription, DriverVersion, DriverDate -AutoSize

Write-Host "[Repair-Step02] Starting Windows Update scan (UsoClient)..."
if (Get-Command UsoClient.exe -ErrorAction SilentlyContinue) {
    Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList "StartScan" -Wait -NoNewWindow
    Write-Host "[Repair-Step02] StartScan finished. If Optional updates list Intel/NVIDIA drivers, install them then reboot."
} else {
    Write-Host "[Repair-Step02] UsoClient.exe not found; use Settings - Windows Update - Check for updates."
}

Write-Host "[Repair-Step02] Recent bugcheck (9F) from System log:"
Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
    StartTime = (Get-Date).AddDays(-14)
} -MaxEvents 3 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Message |
    Format-List
