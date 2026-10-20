#Requires -Version 5.1
<#
.SYNOPSIS
    Compatibility wrapper. Starts primary Dockge UI only (no inference).
    Canonical script: Start-AlfaDockgePrimary.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Start-AlfaDockgePrimary.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
