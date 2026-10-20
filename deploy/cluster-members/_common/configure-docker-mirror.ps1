<#
.SYNOPSIS
    Point Docker Desktop (Win11) at the hub pull-through registry mirror on hub:5000.
.DESCRIPTION
    Merges "registry-mirrors" and "insecure-registries" into Docker Desktop's
    %USERPROFILE%\.docker\daemon.json. Docker Desktop picks the file up on
    restart, pulling base images (postgres, redis, cuda, etc.) from the LAN
    instead of Docker Hub.

    Docs:
        https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file
        https://docs.docker.com/docker-hub/image-library/mirror/
.EXAMPLE
    Configure-AlfaDockerMirror -MirrorUrl 'http://hub'
#>

function Configure-AlfaDockerMirror {
    [CmdletBinding()]
    param(
        [string]$MirrorUrl = 'http://hub'
    )
    $ErrorActionPreference = 'Stop'

    $daemonJson = Join-Path $env:USERPROFILE '.docker\daemon.json'
    $daemonDir  = Split-Path -Parent $daemonJson
    if (-not (Test-Path $daemonDir)) { New-Item -ItemType Directory -Path $daemonDir -Force | Out-Null }

    # Convert PSCustomObject (from ConvertFrom-Json) to a hashtable so we can
    # mutate keys. We do this manually instead of using -AsHashtable because
    # that switch is PS7+ only; on Windows PowerShell 5.1 it raises
    # "A parameter cannot be found that matches parameter name 'AsHashtable'",
    # and the old catch-all fallback silently discarded the user's existing
    # daemon.json (wiping WSL integration, proxies, etc.).
    function ConvertTo-HashtableFromObject {
        param($InputObject)
        if ($null -eq $InputObject) { return @{} }
        if ($InputObject -is [hashtable]) { return $InputObject }
        $h = @{}
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $InputObject.PSObject.Properties) {
                $h[$p.Name] = $p.Value
            }
        }
        return $h
    }

    $current = @{}
    if (Test-Path $daemonJson) {
        try {
            $raw = Get-Content -Path $daemonJson -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed  = $raw | ConvertFrom-Json
                $current = ConvertTo-HashtableFromObject $parsed
            }
        } catch {
            Write-Warning "daemon.json unreadable ($($_.Exception.Message)); preserving file by bailing out"
            # Do NOT rewrite on parse failure -- preserving the user's file is
            # safer than silently wiping WSL / proxy / credsStore settings.
            return
        }
    }

    if (-not $current.ContainsKey('registry-mirrors'))    { $current['registry-mirrors']    = @() }
    if (-not $current.ContainsKey('insecure-registries')) { $current['insecure-registries'] = @() }

    # @(...) on BOTH sides is required under PS5:
    #   - JSON arrays with a single item deserialise to a scalar, not [object[]]
    #   - Where-Object with zero matches assigns $null to the variable, so
    #     @('x') + $null would inject a stray $null into the array.
    # Wrapping both input and output in @() keeps the collection well-typed.
    $existingMirrors  = @(@($current['registry-mirrors'])    | Where-Object { $_ -ne $MirrorUrl })
    $current['registry-mirrors'] = @($MirrorUrl) + $existingMirrors

    $bare = $MirrorUrl -replace '^https?://',''
    $existingInsecure = @(@($current['insecure-registries']) | Where-Object { $_ -ne $bare })
    $current['insecure-registries'] = @($bare) + $existingInsecure

    $desired = $current | ConvertTo-Json -Depth 6
    $existing = if (Test-Path $daemonJson) { Get-Content -Path $daemonJson -Raw } else { '' }
    if ($desired.Trim() -eq $existing.Trim()) {
        Write-Host ("[docker-mirror] {0} already current" -f $daemonJson) -ForegroundColor Green
        return
    }

    Set-Content -Path $daemonJson -Value $desired -Encoding UTF8
    Write-Host ("[docker-mirror] wrote {0}" -f $daemonJson) -ForegroundColor Green
    Write-Host '[docker-mirror] restart Docker Desktop for the change to take effect.' -ForegroundColor Yellow
}

if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\.\s') {
    $mirror = if ($args -and $args[0]) { $args[0] } else { 'http://hub' }
    Configure-AlfaDockerMirror -MirrorUrl $mirror
}
