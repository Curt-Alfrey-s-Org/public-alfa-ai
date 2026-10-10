<#
.SYNOPSIS
    Hub-first Docker tarball loader for Windows workers. Copies the tarball
    from the hub SMB hub to a local cache (skipped when local size matches
    hub), then runs `docker load -i <local>`. Never `docker load -i \\SMB\...`
    directly: WSL2 streaming a 5-15 GB tarball over 9P is silent for 15-25 min
    and hides progress.

.DESCRIPTION
    Source-of-truth pattern lives in deploy/cluster-members/_common/deploy-worker-lan.ps1
    ("worker.2/4 Docker image" section). This file extracts the same logic as
    standalone functions so per-member deploy.ps1 scripts (operator-93, etc.)
    can call it without duplicating ~100 lines.

    Tarballs are produced by:
      * scripts/Publish-BuiltImage-ToHub.ps1   (Windows -> SMB hub)
      * scripts/publish-built-image-to-hub.sh  (Linux/NFS hub)
      * scripts/export_docker_images.sh        (apps batch export)

    Hub layout (see docs/HUB_ARTIFACTS.md):
      Linux:   /mnt/cluster/docker-images/*.tar.gz
      Windows: \\hub\docker-images\*.tar.gz

    Local cache (Windows): <Get-AlfaWindowsCacheRoot>\docker-images\*.tar.gz
      - Same-tarball check is by file SIZE (not hash): a 12 GB SHA-256 over
        SMB is slow, and tarball sizes are stable per image revision. The
        publish scripts write atomically via .<name>.tmp + Move-Item, so a
        size-match implies the bytes are the right bytes.
      - To force a re-copy, delete the local copy.

    Sharing across Windows machines: YES, when the GPU variant matches.
      * alfa-llamacpp-rpc-cuda128*.tar.gz -> llama.cpp RPC shards (Ampere/Ada/Blackwell per build)
      * dockge-1.tar.gz -> Dockge agent stacks
    Image internals are Linux/amd64; Docker Desktop + WSL2 + nvidia-container-toolkit
    runs them on every supported Windows host.

.EXAMPLE
    . "$PSScriptRoot\..\_common\load-hub-tarball.ps1"
    Invoke-AlfaHubTarballLoad -Tarball 'alfa-llamacpp-rpc-cuda128.tar.gz'

.EXAMPLE
    . "$PSScriptRoot\..\_common\load-hub-tarball.ps1"
    $localPath = Get-AlfaHubTarball -Tarball 'alfa-llamacpp-rpc-cuda128.tar.gz'
    if ($localPath) { docker load -i $localPath }
#>

Set-StrictMode -Version Latest

$hubPromptScript = Join-Path $PSScriptRoot 'hub-fallback-prompt.ps1'
if (Test-Path -LiteralPath $hubPromptScript) {
    . $hubPromptScript
}

$cacheRootScript = Join-Path $PSScriptRoot 'Get-AlfaWindowsCacheRoot.ps1'
if (-not (Test-Path -LiteralPath $cacheRootScript)) {
    throw "Missing shared cache helper: $cacheRootScript (run Get-AlfaWindowsCacheRoot or set ALFA_WINDOWS_CACHE_ROOT)"
}
. $cacheRootScript

function Resolve-AlfaHubLocalCacheDir {
    [CmdletBinding()]
    param(
        [string]$LocalCacheDir = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($LocalCacheDir)) {
        return $LocalCacheDir
    }
    Assert-AlfaWindowsCacheRootHelperLoaded
    return Get-AlfaWindowsDockerImagesCacheDir
}

# Resolve a tarball from the SMB hub to a local cache copy. Skips the copy
# when the local copy has the same size as the hub copy. Returns the local
# path on success, or $null when neither source nor pre-staged local copy is
# available.
function Get-AlfaHubTarball {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Tarball,

        [string]$HubRoot = '\\hub\docker-images',

        [string]$LocalCacheDir = '',

        [int]$HubProbeTimeoutSec = 8
    )

    $LocalCacheDir = Resolve-AlfaHubLocalCacheDir -LocalCacheDir $LocalCacheDir

    if (-not (Test-Path -LiteralPath $LocalCacheDir)) {
        New-Item -ItemType Directory -Path $LocalCacheDir -Force | Out-Null
    }

    $hubPath   = Join-Path $HubRoot       $Tarball
    $localPath = Join-Path $LocalCacheDir $Tarball

    $localBytes   = [int64]0
    $localPresent = $false
    if (Test-Path -LiteralPath $localPath) {
        try {
            $localBytes   = [int64]((Get-Item -LiteralPath $localPath -ErrorAction Stop).Length)
            $localPresent = ($localBytes -gt 0)
        } catch { $localPresent = $false }
    }

    # Time-boxed SMB stat: distinguish share down vs tarball missing on hub.
    $hubShareUp = $false
    $hubFilePresent = $false
    $hubBytes = [int64]0
    $shareProbeJob = Start-Job -ScriptBlock {
        param($root)
        Test-Path -LiteralPath $root
    } -ArgumentList $HubRoot
    if (Wait-Job -Job $shareProbeJob -Timeout $HubProbeTimeoutSec) {
        try {
            $hubShareUp = [bool](Receive-Job -Job $shareProbeJob -ErrorAction Stop)
        } catch { $hubShareUp = $false }
    } else {
        Write-Host "  WARN: SMB share probe $HubRoot timed out after ${HubProbeTimeoutSec}s" -ForegroundColor Yellow
        try { Stop-Job -Job $shareProbeJob -ErrorAction SilentlyContinue } catch {}
    }
    try { Remove-Job -Job $shareProbeJob -Force -ErrorAction SilentlyContinue } catch {}

    $fileProbeJob = Start-Job -ScriptBlock {
        param($p)
        if (Test-Path -LiteralPath $p) {
            $fi = Get-Item -LiteralPath $p -ErrorAction Stop
            [pscustomobject]@{ Exists = $true; Length = [int64]$fi.Length }
        } else {
            [pscustomobject]@{ Exists = $false; Length = [int64]0 }
        }
    } -ArgumentList $hubPath
    if (Wait-Job -Job $fileProbeJob -Timeout $HubProbeTimeoutSec) {
        try {
            $probe = Receive-Job -Job $fileProbeJob -ErrorAction Stop
            if ($probe -and $probe.Exists) {
                $hubFilePresent = $true
                $hubBytes = [int64]$probe.Length
            }
        } catch { $hubFilePresent = $false }
    } else {
        Write-Host "  WARN: SMB stat $hubPath timed out after ${HubProbeTimeoutSec}s" -ForegroundColor Yellow
        try { Stop-Job -Job $fileProbeJob -ErrorAction SilentlyContinue } catch {}
    }
    try { Remove-Job -Job $fileProbeJob -Force -ErrorAction SilentlyContinue } catch {}

    $hubReachable = $hubFilePresent
    if (-not $hubFilePresent) {
        if ($hubShareUp) {
            Write-Host "  Tarball not on hub (share OK): $hubPath" -ForegroundColor Yellow
            Write-Host '  Publish: bash scripts/publish-built-image-to-hub.sh <image:tag>' -ForegroundColor DarkGray
        } else {
            Write-Host "  SMB share not reachable: $HubRoot" -ForegroundColor Yellow
        }
    }

    if ($localPresent -and $hubReachable -and $hubBytes -gt 0) {
        if ($localBytes -eq $hubBytes) {
            Write-Host ("  Local cache size match ({0} MB) - skip SMB copy: {1}" -f [int]($localBytes/1MB), $localPath) -ForegroundColor Green
            return $localPath
        }
        Write-Host ("  Local {0} bytes != hub {1} bytes - re-copy from SMB" -f $localBytes, $hubBytes) -ForegroundColor Yellow
    } elseif ($localPresent -and -not $hubReachable) {
        Write-Host ("  Hub unreachable; using pre-staged local tarball as-is ({0} MB): {1}" -f [int]($localBytes/1MB), $localPath) -ForegroundColor Yellow
        return $localPath
    } elseif (-not $hubReachable) {
        if (-not $localPresent) {
            if (Get-Command Assert-AlfaHubFallbackProceed -ErrorAction SilentlyContinue) {
                Assert-AlfaHubFallbackProceed `
                    -Context 'docker-image-tarball' `
                    -HubPath $hubPath `
                    -FallbackDescription 'Skip hub tarball; deploy may docker build from source and download from PyPI/Docker Hub.'
            } else {
                Write-Host "  Hub not reachable at $hubPath and no local cache. Stopping (hub-fallback-prompt.ps1 missing)." -ForegroundColor Red
                return $null
            }
        }
        Write-Host "  Hub not reachable at $hubPath and no local cache. Skipping tarball load." -ForegroundColor Yellow
        Write-Host "    (publish from a host that built it: scripts\Publish-BuiltImage-ToHub.ps1 -ImageTag <tag>)" -ForegroundColor DarkGray
        return $null
    }

    # Copy with robocopy + destination-size polling (transcript-friendly).
    $srcDir   = Split-Path -Parent $hubPath
    $srcFile  = Split-Path -Leaf   $hubPath
    $totalMB  = [int]($hubBytes / 1MB)
    Write-Host ("  Staging from SMB ({0} MB) -> {1}" -f $totalMB, $localPath) -ForegroundColor Cyan

    $rcArgs = @(
        $srcDir, $LocalCacheDir, $srcFile,
        '/Z', '/J', '/R:2', '/W:2',
        '/NDL', '/NFL', '/NJH', '/NJS', '/NP'
    )
    $robocopyExe = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    if (-not (Test-Path -LiteralPath $robocopyExe)) {
        Write-Host "  ERROR: robocopy not found at $robocopyExe" -ForegroundColor Red
        return $null
    }
    $rcStart = Get-Date
    $rcProc  = Start-Process -FilePath $robocopyExe -ArgumentList $rcArgs -PassThru -NoNewWindow
    $lastBytes = [int64]0
    $lastTime  = $rcStart
    while (-not $rcProc.HasExited) {
        Start-Sleep -Seconds 5
        $curBytes = [int64]0
        if (Test-Path -LiteralPath $localPath) {
            try { $curBytes = [int64]((Get-Item -LiteralPath $localPath -ErrorAction Stop).Length) } catch {}
        }
        $now      = Get-Date
        $intvS    = ($now - $lastTime).TotalSeconds
        $speedMBs = if ($intvS -gt 0) { [double](($curBytes - $lastBytes) / 1MB) / $intvS } else { 0.0 }
        $doneMB   = [int]($curBytes / 1MB)
        $pct      = if ($hubBytes -gt 0) { [math]::Round(100.0 * $curBytes / $hubBytes, 1) } else { 0.0 }
        $etaStr   = '??:??:??'
        if ($speedMBs -gt 0.1 -and $doneMB -lt $totalMB) {
            $etaSec = [math]::Min(($totalMB - $doneMB) / $speedMBs, 86400)
            $etaStr = [TimeSpan]::FromSeconds([int]$etaSec).ToString('hh\:mm\:ss')
        }
        Write-Host ('    copy {0,5} / {1,5} MB  ({2,5:N1}%)  {3,5:N1} MB/s  ETA {4}' -f $doneMB, $totalMB, $pct, $speedMBs, $etaStr) -ForegroundColor Yellow
        $lastBytes = $curBytes
        $lastTime  = $now
    }
    [void]$rcProc.WaitForExit()
    try { $rcProc.Refresh() } catch { }
    $rc = $rcProc.ExitCode
    $finalBytesNow = [int64]0
    if (Test-Path -LiteralPath $localPath) {
        try { $finalBytesNow = [int64]((Get-Item -LiteralPath $localPath -ErrorAction Stop).Length) } catch { }
    }
    # ExitCode can stay unset until Refresh(); older builds mapped null -> 999 and failed good copies.
    if (($null -eq $rc -or $rc -ge 8) -and $hubBytes -gt 0 -and $finalBytesNow -eq $hubBytes) {
        Write-Host ("  WARN: robocopy exit code was unreliable ({0}); destination size matches hub - treating copy as OK." -f $rc) -ForegroundColor Yellow
        $rc = 1
    }
    if ($null -eq $rc) { $rc = 999 }
    if ($rc -ge 8) {
        Write-Host "  ERROR: robocopy failed staging $hubPath (exit $rc)" -ForegroundColor Red
        return $null
    }
    $finalMB = if (Test-Path -LiteralPath $localPath) { [int]((Get-Item -LiteralPath $localPath).Length / 1MB) } else { 0 }
    $dur     = [int]((Get-Date) - $rcStart).TotalSeconds
    Write-Host ("  Staged: {0} MB in {1}s (robocopy exit code {2})" -f $finalMB, $dur, $rc) -ForegroundColor Green
    return $localPath
}

# Stream docker load stdout/stderr line-by-line (PowerShell 5.1 hides native stderr otherwise).
# Periodic heartbeat while still running (large tarballs can go quiet for minutes - not necessarily stuck).
function Invoke-AlfaDockerLoadVerbose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TarballPath,

        [int]$HeartbeatSec = 20
    )

    Write-Host ("  docker load -i `"$TarballPath`" (streaming lines + heartbeat every {0}s while running)" -f $HeartbeatSec) -ForegroundColor Cyan

    # PS 5.1 / .NET Framework: ProcessStartInfo has no ArgumentList - use a single Arguments string.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ((Get-Variable -Name AlfaUseWslDocker -Scope Script -ErrorAction SilentlyContinue).Value -eq $true) {
        $distro = (Get-Variable -Name AlfaWslDockerDistro -Scope Script -ErrorAction SilentlyContinue).Value
        if (-not $distro) { $distro = 'Ubuntu' }
        $wslTarball = ConvertTo-AlfaWslPath -Path $TarballPath
        $psi.FileName = 'wsl.exe'
        $quotedPath = '"' + ($wslTarball.Replace('"', '\"')) + '"'
        $psi.Arguments = "-d $distro docker load -i $quotedPath"
    } else {
        $psi.FileName = 'docker'
        $quotedPath = '"' + ($TarballPath.Replace('"', '\"')) + '"'
        $psi.Arguments = "load -i $quotedPath"
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    # Register-ObjectEvent -Action receives $EventArgs (not param($sender,$e)).
    $action = {
        if ($null -ne $EventArgs.Data -and $EventArgs.Data -ne '') {
            Write-Host ("    {0}" -f $EventArgs.Data)
        }
    }

    # Unique-per-invocation source identifiers so a Ctrl-C'd previous run
    # (which left stale subscribers in this PS session) does not fail us with
    # "A subscriber with the source identifier 'X' already exists.".
    $idStamp = [Guid]::NewGuid().ToString('N')
    $idOut = "AlfaDockerLoadOut_$idStamp"
    $idErr = "AlfaDockerLoadErr_$idStamp"

    # Best-effort cleanup of any leftover ALFa docker-load subscribers from prior runs.
    Get-EventSubscriber -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -like 'AlfaDockerLoad*' } |
        ForEach-Object { Unregister-Event -SourceIdentifier $_.SourceIdentifier -ErrorAction SilentlyContinue }

    $subOut = $null
    $subErr = $null
    try {
        $subOut = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -SourceIdentifier $idOut -Action $action
        $subErr = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -SourceIdentifier $idErr -Action $action

        if (-not $p.Start()) {
            Write-Host '  ERROR: failed to start docker load process' -ForegroundColor Red
            return 999
        }
        $null = $p.BeginOutputReadLine()
        $null = $p.BeginErrorReadLine()

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $nextBeat = [double]$HeartbeatSec
        while (-not $p.HasExited) {
            [void]$p.WaitForExit(3000)
            if (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -ge $nextBeat) {
                Write-Host ('  [docker load] still running - {0:N0}s elapsed (heartbeat every {1}s)' -f $sw.Elapsed.TotalSeconds, $HeartbeatSec) -ForegroundColor DarkYellow
                $nextBeat += [double]$HeartbeatSec
            }
        }
        [void]$p.WaitForExit()
        # Allow async OutputDataReceived deliveries to drain before unsubscribing.
        Start-Sleep -Milliseconds 250

        $exit = $p.ExitCode
        Write-Host ("  docker load finished after {0:N0}s (exit {1})" -f $sw.Elapsed.TotalSeconds, $exit) -ForegroundColor $(if ($exit -eq 0) { 'Green' } else { 'Yellow' })
        return $exit
    }
    finally {
        # Register-ObjectEvent -Action returns a PSEventJob; the variable IS the job.
        # Don't access `.Job` (doesn't exist - StrictMode throws PropertyNotFoundStrict).
        foreach ($sub in @($subOut, $subErr)) {
            if ($null -eq $sub) { continue }
            try {
                Unregister-Event -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue
            }
            catch { }
            try {
                Remove-Job -Job $sub -Force -ErrorAction SilentlyContinue
            }
            catch { }
        }
        if ($null -ne $p) {
            try {
                if (-not $p.HasExited) {
                    $p.Kill()
                }
            }
            catch { }
            try {
                $p.Dispose()
            }
            catch { }
        }
    }
}

# Read images.json and return a FLAT list of real entries (each has image+file).
# Strict-mode safe (Set-StrictMode -Version Latest is active in this module):
# never dereferences a property that may be absent. Also unwraps a legacy
# {"value":[...],"Count":N} wrapper -- a PowerShell array-serialization artifact
# that some older writer left in the hub manifest -- so callers see a clean list.
function Get-AlfaHubManifestEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return @()
    }
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-Host "  WARN: could not parse images.json at $ManifestPath" -ForegroundColor Yellow
        return @()
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($node in @($raw)) {
        if ($null -eq $node) { continue }
        $names = @($node.PSObject.Properties.Name)
        if (($names -contains 'image') -and ($names -contains 'file')) {
            $out.Add($node)
        }
        elseif ($names -contains 'value') {
            foreach ($inner in @($node.value)) {
                if ($null -eq $inner) { continue }
                $innerNames = @($inner.PSObject.Properties.Name)
                if (($innerNames -contains 'image') -and ($innerNames -contains 'file')) {
                    $out.Add($inner)
                }
            }
        }
    }
    return $out.ToArray()
}

# Lookup one images.json row by tarball file (+ optional image tag).
function Get-AlfaHubImagesManifestEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,

        [Parameter(Mandatory)]
        [string]$Tarball,

        [string]$ImageTag = ''
    )

    foreach ($entry in (Get-AlfaHubManifestEntries -ManifestPath $ManifestPath)) {
        if ($entry.file -ne $Tarball) { continue }
        if ($ImageTag -and $entry.image -ne $ImageTag) { continue }
        return $entry
    }
    return $null
}

# Extract rpc-server SHA256 from a loaded image (parity with load-llamacpp-rpc-from-hub.sh).
function Get-AlfaRpcServerSha256FromImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImageTag
    )

    $useWsl = $false
    $distro = 'Ubuntu'
    if ((Get-Variable -Name AlfaUseWslDocker -Scope Script -ErrorAction SilentlyContinue).Value -eq $true) {
        $useWsl = $true
        $d = (Get-Variable -Name AlfaWslDockerDistro -Scope Script -ErrorAction SilentlyContinue).Value
        if ($d) { $distro = $d }
    }

    $tempPath = Join-Path $env:TEMP ("alfa-rpc-server-verify-{0}" -f ([Guid]::NewGuid().ToString('N')))
    $cid = ''
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($useWsl) {
            $cid = (& wsl.exe -d $distro docker create $ImageTag 2>$null | Select-Object -Last 1).Trim()
            if (-not $cid -or $LASTEXITCODE -ne 0) { return $null }
            $wslTemp = "/tmp/alfa-rpc-server-verify-$([Guid]::NewGuid().ToString('N'))"
            & wsl.exe -d $distro docker cp "${cid}:/usr/local/bin/ggml-rpc-server" $wslTemp 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & wsl.exe -d $distro docker cp "${cid}:/usr/local/bin/rpc-server" $wslTemp 2>$null | Out-Null
            }
            & wsl.exe -d $distro sha256sum $wslTemp 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
            $shaLine = (& wsl.exe -d $distro sha256sum $wslTemp 2>$null | Select-Object -First 1)
            & wsl.exe -d $distro rm -f $wslTemp 2>$null | Out-Null
            if ($shaLine -match '^([0-9a-f]{64})\b') { return $Matches[1] }
            return $null
        }

        $cid = (& docker create $ImageTag 2>$null | Select-Object -Last 1).Trim()
        if (-not $cid -or $LASTEXITCODE -ne 0) { return $null }
        & docker cp "${cid}:/usr/local/bin/ggml-rpc-server" $tempPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempPath)) {
            & docker cp "${cid}:/usr/local/bin/rpc-server" $tempPath 2>$null | Out-Null
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempPath)) { return $null }
        return (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLower()
    }
    finally {
        if ($cid) {
            if ($useWsl) {
                & wsl.exe -d $distro docker rm $cid 2>$null | Out-Null
            }
            else {
                & docker rm $cid 2>$null | Out-Null
            }
        }
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        $ErrorActionPreference = $prev
    }
}

# Self-register a loaded image into the hub images.json when no entry exists.
# Writes id + (for rpc/llamacpp images) rpc_server_sha256 so later loads verify.
# Returns $true when an entry was written to the hub manifest.
function Register-AlfaHubLoadedImageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ManifestPath,
        [Parameter(Mandatory)] [string]$Tarball,
        [Parameter(Mandatory)] [string]$ImageTag
    )

    $hubDir = Split-Path -Parent $ManifestPath
    if (-not (Test-Path -LiteralPath $hubDir)) {
        return $false
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $imgId = ''
    try {
        $imgId = (& docker image inspect $ImageTag --format '{{.Id}}' 2>$null).Trim()
    }
    catch { $imgId = '' }
    finally { $ErrorActionPreference = $prev }
    if (-not $imgId) { return $false }

    # rpc-server SHA256 is the cross-host source of truth (image IDs can differ
    # per daemon). Best-effort: only rpc/llamacpp images carry the binary.
    $rpcSha = ''
    try { $rpcSha = Get-AlfaRpcServerSha256FromImage -ImageTag $ImageTag } catch { $rpcSha = '' }

    # Read via the normalizer: flattens any legacy {value,Count} wrapper and
    # returns only real entries, so we never write the wrapper back or trip
    # Set-StrictMode on a property-less node.
    $entries = @(Get-AlfaHubManifestEntries -ManifestPath $ManifestPath)
    $entries = @($entries | Where-Object { $_.image -ne $ImageTag })
    $newEntry = [ordered]@{
        image       = $ImageTag
        file        = $Tarball
        id          = $imgId
        exported    = (Get-Date).ToUniversalTime().ToString('o')
        source_host = $env:COMPUTERNAME
        registered_on_load = $true
    }
    if ($rpcSha) { $newEntry['rpc_server_sha256'] = $rpcSha }
    $entries += [pscustomobject]$newEntry

    try {
        # images.json is read by Linux python json.load() on other hosts (e.g.
        # load-llamacpp-rpc-from-hub.sh on inference/pool-opt-in). PS 5.1 Set-Content
        # -Encoding UTF8 prepends a BOM, which crashes a plain open() with
        # "Unexpected UTF-8 BOM". Write UTF-8 WITHOUT BOM. Force array bracket
        # for a single entry (PS collapses a 1-element array to a JSON object).
        $json = $entries | ConvertTo-Json -Depth 6
        if (@($entries).Count -le 1) { $json = "[$json]" }
        [System.IO.File]::WriteAllText($ManifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    }
    catch {
        Write-Host "  WARN: manifest write failed at $ManifestPath : $_" -ForegroundColor Yellow
        return $false
    }
}

# Verify loaded image against hub images.json (id + optional rpc-server SHA256 fallback).
function Test-AlfaHubLoadedImageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HubRoot,

        [Parameter(Mandatory)]
        [string]$Tarball,

        [Parameter(Mandatory)]
        [string]$ImageTag
    )

    $manifestPath = Join-Path $HubRoot 'images.json'
    $entry = Get-AlfaHubImagesManifestEntry -ManifestPath $manifestPath -Tarball $Tarball -ImageTag $ImageTag
    if (-not $entry) {
        # Blind spot close: rather than silently trusting an unverifiable load,
        # self-register this host's loaded image into the hub manifest (id +
        # rpc-server SHA256). Subsequent loads on any host then verify against
        # it. Self-register only when the hub manifest dir is writable (the
        # source host that built/loaded the image); otherwise warn loudly with
        # the exact publish command so the gap is visible, not hidden.
        Write-Host "  NOTE: no images.json entry for $ImageTag / $Tarball" -ForegroundColor Yellow
        $registered = Register-AlfaHubLoadedImageManifest `
            -ManifestPath $manifestPath -Tarball $Tarball -ImageTag $ImageTag
        if ($registered) {
            Write-Host "  OK: self-registered manifest entry from loaded image (baseline for future verify)" -ForegroundColor Green
        } else {
            Write-Host "  WARN: could not self-register; verify skipped (blind spot). Publish from the build host:" -ForegroundColor Yellow
            Write-Host ("    .\scripts\Publish-BuiltImage-ToHub.ps1 -ImageTag '{0}' -Tarball '{1}'" -f $ImageTag, $Tarball) -ForegroundColor DarkGray
        }
        return $true
    }

    $expectedId = ''
    if ($entry.PSObject.Properties.Name -contains 'id') {
        $expectedId = [string]$entry.id
    }
    $expectedRpc = ''
    if ($entry.PSObject.Properties.Name -contains 'rpc_server_sha256') {
        $expectedRpc = [string]$entry.rpc_server_sha256
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $actualId = ''
    try {
        $actualId = (& docker image inspect $ImageTag --format '{{.Id}}' 2>$null).Trim()
    }
    finally {
        $ErrorActionPreference = $prev
    }
    if (-not $actualId) {
        Write-Host "  ERROR: $ImageTag missing after hub load (images.json id=$expectedId)" -ForegroundColor Red
        return $false
    }

    Write-Host ("  loaded {0} id={1}" -f $ImageTag, $actualId) -ForegroundColor DarkGray

    if ($expectedId -and $actualId -eq $expectedId) {
        Write-Host '  OK: matches hub images.json' -ForegroundColor Green
        return $true
    }

    if (-not $expectedRpc) {
        Write-Host '  ERROR: image ID mismatch after hub load and no rpc_server_sha256 in manifest' -ForegroundColor Red
        Write-Host ("    expected (images.json): $expectedId") -ForegroundColor Red
        Write-Host ("    actual:                 $actualId") -ForegroundColor Red
        return $false
    }

    $rpcSha = Get-AlfaRpcServerSha256FromImage -ImageTag $ImageTag
    if ($rpcSha -and $rpcSha -eq $expectedRpc) {
        Write-Host '  WARN: image ID differs from images.json; rpc-server SHA256 matches hub manifest' -ForegroundColor Yellow
        return $true
    }

    Write-Host '  ERROR: image ID mismatch after hub load' -ForegroundColor Red
    Write-Host ("    expected (images.json): $expectedId") -ForegroundColor Red
    Write-Host ("    actual:                 $actualId") -ForegroundColor Red
    if ($rpcSha) {
        Write-Host ("    rpc-server sha256:      $rpcSha") -ForegroundColor Red
    }
    Write-Host ("    expected rpc-server:    $expectedRpc") -ForegroundColor Red
    return $false
}

# Full pipeline: stage tarball locally (if needed), then docker load -i.
# Returns $true if docker load exits 0, else $false.
function Invoke-AlfaHubTarballLoad {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Tarball,

        [string]$HubRoot       = '\\hub\docker-images',
        [string]$LocalCacheDir = '',

        [int]$LoadHeartbeatSec = 20,

        # When set, verify against hub images.json after load (rpc-server SHA256 fallback).
        [string]$ImageTag = ''
    )

    $resolvedCacheDir = Resolve-AlfaHubLocalCacheDir -LocalCacheDir $LocalCacheDir
    $local = Get-AlfaHubTarball -Tarball $Tarball -HubRoot $HubRoot -LocalCacheDir $resolvedCacheDir
    if (-not $local) { return $false }

    # Skip-if-loaded sentinel: docker load on Docker Desktop/WSL2 can be 15-30 min
    # for a 1 GB tarball (gzip + 9P + AV) and idempotent re-loads waste that time.
    # After a successful load we write "<tarball>.loaded" containing the source
    # tarball size in bytes. On the next run, if the sizes match, skip the load.
    # To force a reload, delete the .loaded file (or the tarball itself).
    $sentinel = "$local.loaded"
    try {
        $localBytes = [int64]((Get-Item -LiteralPath $local -ErrorAction Stop).Length)
    }
    catch {
        $localBytes = [int64]0
    }
    if ($localBytes -gt 0 -and (Test-Path -LiteralPath $sentinel)) {
        $recorded = $null
        try { $recorded = (Get-Content -LiteralPath $sentinel -Raw -ErrorAction Stop).Trim() } catch { }
        $recordedBytes = [int64]0
        if ($recorded -and [int64]::TryParse($recorded, [ref]$recordedBytes) -and $recordedBytes -eq $localBytes) {
            Write-Host ("  Sentinel match ({0} MB): tarball already loaded; skipping docker load." -f [int]($localBytes / 1MB)) -ForegroundColor Green
            Write-Host ("    (force reload: del `"$sentinel`")") -ForegroundColor DarkGray
            if ($ImageTag) {
                $verified = Test-AlfaHubLoadedImageManifest -HubRoot $HubRoot -Tarball $Tarball -ImageTag $ImageTag
                if ($verified) { return $true }
                Write-Host "  Stale sentinel: $ImageTag missing from docker; reloading tarball." -ForegroundColor Yellow
                Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
            }
            else {
                return $true
            }
        }
        Write-Host ("  Sentinel size mismatch (have {0}, tarball {1}); reloading." -f $recordedBytes, $localBytes) -ForegroundColor Yellow
    }

    $exit = Invoke-AlfaDockerLoadVerbose -TarballPath $local -HeartbeatSec $LoadHeartbeatSec
    if ($exit -ne 0) {
        Write-Host "  WARN: docker load $Tarball exit $exit" -ForegroundColor Yellow
        return $false
    }

    if ($localBytes -gt 0) {
        try {
            Set-Content -LiteralPath $sentinel -Value ([string]$localBytes) -NoNewline -Encoding ASCII -ErrorAction Stop
            Write-Host ("  Wrote sentinel: $sentinel ({0} bytes)" -f $localBytes) -ForegroundColor DarkGreen
        }
        catch {
            Write-Host "  WARN: could not write sentinel $sentinel - next run will redo docker load: $_" -ForegroundColor Yellow
        }
    }

    if ($ImageTag) {
        $verified = Test-AlfaHubLoadedImageManifest -HubRoot $HubRoot -Tarball $Tarball -ImageTag $ImageTag
        if (-not $verified) { return $false }
    }
    return $true
}
