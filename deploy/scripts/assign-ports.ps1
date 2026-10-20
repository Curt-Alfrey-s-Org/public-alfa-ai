#Requires -Version 5.1
<#
.SYNOPSIS
  Scans for free ports in the ALFa AI approved range (8400-8499) and writes
  assignments into deploy/.env.

.DESCRIPTION
  Run from the deploy/ directory (or pass -EnvFile).

  For each ALFa AI service that needs a host port, the script:
    1. Tries the default port first.
    2. If the default is occupied by a non-ALFa Docker container, walks
       the 8400-8499 range to find the next free port.
    3. Writes the result into deploy/.env.

  Ports owned by a running ALFa container (com.docker.backend / Docker Desktop)
  are treated as "ours" and kept as-is for a recreate.

.PARAMETER EnvFile
  Path to the .env file. Defaults to deploy/.env relative to this script.

.PARAMETER DryRun
  Show assignments without writing to .env.

#>
param(
    [string]$EnvFile = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $PSScriptRoot "..\.env" | Resolve-Path -ErrorAction SilentlyContinue
    if (-not $EnvFile) {
        $EnvFile = Join-Path $PSScriptRoot "..\.env"
    }
}

if (-not (Test-Path $EnvFile)) {
    Write-Error "Missing $EnvFile - create deploy/.env on this host first (gitignored)."
}

$RANGE_START = 8400
$RANGE_END   = 8499
$FORBIDDEN_LOW  = 8000
$FORBIDDEN_HIGH = 8030

$services = @(
    @{ EnvVar = "ALFA_AI_API_HOST_PORT";              Default = 8412; Container = "alfa-ai-api" }
    @{ EnvVar = "ALFA_AI_LITELLM_HOST_PORT";          Default = 8413; Container = "alfa-ai-litellm" }
    @{ EnvVar = "ALFA_AI_OPERATOR_CONSOLE_HOST_PORT";  Default = 8420; Container = "alfa-ai-api" }
)

$docker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
if (-not (Test-Path $docker)) {
    $docker = "docker"
}

function Get-RunningContainerId {
    param([string]$Name)
    $id = (& $docker ps --filter "name=^${Name}$" --format "{{.ID}}" 2>$null | Select-Object -First 1)
    return $id
}

function Test-PortOwnedByAlfa {
    param([int]$Port, [string]$ExpectedContainer)

    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) { return $false }

    $containerId = Get-RunningContainerId -Name $ExpectedContainer
    if (-not [string]::IsNullOrWhiteSpace($containerId)) {
        return $true
    }
    return $false
}

function Test-PortFree {
    param([int]$Port)
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    return ($listeners.Count -eq 0)
}

function Find-FreePort {
    param(
        [int]$Preferred,
        [string]$Container,
        [int[]]$AlreadyAssigned
    )

    if ($Preferred -ge $FORBIDDEN_LOW -and $Preferred -le $FORBIDDEN_HIGH) {
        Write-Warning "Default port $Preferred is in the forbidden 8000-8030 range; skipping."
    }
    elseif ((Test-PortFree -Port $Preferred) -or (Test-PortOwnedByAlfa -Port $Preferred -ExpectedContainer $Container)) {
        if ($AlreadyAssigned -notcontains $Preferred) {
            return $Preferred
        }
    }

    for ($candidate = $RANGE_START; $candidate -le $RANGE_END; $candidate++) {
        if ($candidate -ge $FORBIDDEN_LOW -and $candidate -le $FORBIDDEN_HIGH) { continue }
        if ($AlreadyAssigned -contains $candidate) { continue }
        if ((Test-PortFree -Port $candidate) -or (Test-PortOwnedByAlfa -Port $candidate -ExpectedContainer $Container)) {
            return $candidate
        }
    }

    Write-Error "No free port found in range $RANGE_START-$RANGE_END for container $Container."
}

function Set-EnvValue {
    param(
        [string]$FilePath,
        [string]$Key,
        [string]$Value
    )

    $lines = @(Get-Content $FilePath)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$Key=") {
            $lines[$i] = "$Key=$Value"
            $found = $true
            break
        }
    }
    if (-not $found) {
        $lines += "$Key=$Value"
    }
    $lines | Set-Content $FilePath -Encoding UTF8
}

Write-Host "== ALFa AI Port Assignment ==" -ForegroundColor Cyan
Write-Host "Env file : $EnvFile"
Write-Host "Range    : $RANGE_START - $RANGE_END"
Write-Host "Forbidden: $FORBIDDEN_LOW - $FORBIDDEN_HIGH"
Write-Host ""

$assigned = @()
$results = @()

foreach ($svc in $services) {
    $envVar    = $svc.EnvVar
    $default   = $svc.Default
    $container = $svc.Container

    $currentLine = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$envVar=" } | Select-Object -First 1
    $current = $default
    if ($null -ne $currentLine) {
        $current = [int](($currentLine -replace "^\s*$envVar=", '').Trim())
    }

    $port = Find-FreePort -Preferred $current -Container $container -AlreadyAssigned $assigned
    $assigned += $port

    $status = if ($port -eq $current) { "kept" } else { "reassigned from $current" }
    $results += [pscustomobject]@{
        Service   = $envVar
        Port      = $port
        Status    = $status
        Container = $container
    }
}

Write-Host "Port assignments:" -ForegroundColor Cyan
$results | Format-Table Service, Port, Status, Container -AutoSize

if ($DryRun) {
    Write-Host "`nDry run - no changes written." -ForegroundColor Yellow
    return
}

foreach ($r in $results) {
    $svc = $services | Where-Object { $_.EnvVar -eq $r.Service }
    Set-EnvValue -FilePath $EnvFile -Key $r.Service -Value $r.Port
}

Write-Host "`nWrote assignments to $EnvFile" -ForegroundColor Green
Write-Host "Next: from repo root run docker compose (see deploy/README paths) then bash scripts/smoke-litellm-tiers.sh deploy/.env" -ForegroundColor DarkGray
