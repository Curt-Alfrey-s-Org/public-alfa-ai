<#
.SYNOPSIS
    Publish a locally-built Docker image from a Windows worker (orchestrator) up to the
    hub hub so Blackwell workers (gaming-b/gaming-c/gaming-a) docker-load it instead of
    rebuilding.
.DESCRIPTION
    Policy: .cursor\rules\hub-hub-first.mdc, docs\HUB_ARTIFACTS.md.
    Large artifacts (>200 MB) must be published to the hub; workers must never
    rebuild what another LAN host already built.
.PARAMETER ImageTag
    Local Docker image tag, e.g. 'alfa-petals-ml-base:cuda'.
.PARAMETER Tarball
    Optional filename. Defaults to <tag-with-slashes-and-colons-as-dashes>.tar.gz.
.PARAMETER HubDir
    Destination SMB dir. Defaults to the standard cluster images share.
.EXAMPLE
    .\scripts\Publish-BuiltImage-ToHub.ps1 -ImageTag 'alfa-petals-ml-base:cuda'
.EXAMPLE
    .\scripts\Publish-BuiltImage-ToHub.ps1 `
        -ImageTag 'alfa-petals-worker-gpu:12.8.0-cuda-blackwell' `
        -Tarball  'alfa-petals-worker-gpu-12.8.0-cuda-blackwell.tar.gz'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ImageTag,
    [string]$Tarball,
    [string]$HubDir = '\\hub\docker-images'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Tarball) {
    $Tarball = ($ImageTag -replace '[:/]', '-') + '.tar.gz'
}

& docker image inspect $ImageTag 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Image not found locally: $ImageTag. Build it first."
}

if (-not (Test-Path $HubDir)) {
    throw "Hub dir not reachable: $HubDir. Create the SMB share 'docker-images' on hub (hub) pointing at /mnt/HDDs/Alfa-AI/docker-images (sharing.smb.create, purpose DEFAULT_SHARE, browsable true)."
}

$destPath = Join-Path $HubDir $Tarball
$tmpPath  = Join-Path $HubDir ".$Tarball.tmp"

Write-Host "==> docker save $ImageTag -> $destPath" -ForegroundColor Cyan

# docker save writes a tar to stdout. On Windows, pipe through gzip via
# Compress-Archive is wrong (zip, not gzip). Use 7-Zip if available, else
# fall back to uncompressed .tar. For hub policy it's fine -- the hub is LAN,
# so uncompressed saves CPU on both ends.
$use7z = Get-Command 7z -ErrorAction SilentlyContinue
if ($use7z -and $Tarball.EndsWith('.tar.gz')) {
    $tarOnly = $Tarball -replace '\.gz$', ''
    $tmpTar  = Join-Path $HubDir ".$tarOnly.tmp"
    & docker save -o $tmpTar $ImageTag
    if ($LASTEXITCODE -ne 0) { throw "docker save failed (exit $LASTEXITCODE)" }
    & 7z a -tgzip -mx=1 "$tmpPath" "$tmpTar" | Out-Null
    Remove-Item $tmpTar -Force
} else {
    if ($Tarball.EndsWith('.tar.gz')) {
        Write-Host "  (7-Zip not installed; saving uncompressed .tar instead)" -ForegroundColor Yellow
        $Tarball = $Tarball -replace '\.gz$', ''
        $destPath = Join-Path $HubDir $Tarball
        $tmpPath  = Join-Path $HubDir ".$Tarball.tmp"
    }
    & docker save -o $tmpPath $ImageTag
    if ($LASTEXITCODE -ne 0) { throw "docker save failed (exit $LASTEXITCODE)" }
}

Move-Item -Force $tmpPath $destPath

$imgId = (& docker image inspect $ImageTag --format '{{.Id}}').Trim()
$sizeB = (Get-Item $destPath).Length
$sizeH = if ($sizeB -gt 1GB) { "{0:N2} GB" -f ($sizeB / 1GB) }
        elseif ($sizeB -gt 1MB) { "{0:N2} MB" -f ($sizeB / 1MB) }
        else { "$sizeB B" }
Write-Host "==> published $Tarball ($sizeH) id=$imgId" -ForegroundColor Green

# Dot-source the hub loader first: it defines Get-AlfaHubManifestEntries (flattens
# any legacy {value,Count} wrapper, strict-mode safe) and Get-AlfaRpcServerSha256FromImage.
$loaderScript = Join-Path $PSScriptRoot '..\deploy\cluster-members\_common\load-hub-tarball.ps1'
if (Test-Path -LiteralPath $loaderScript) {
    try { . $loaderScript } catch { }
}

# Update manifest
$manifest = Join-Path $HubDir 'images.json'
if (Get-Command Get-AlfaHubManifestEntries -ErrorAction SilentlyContinue) {
    $entries = @(Get-AlfaHubManifestEntries -ManifestPath $manifest)
}
else {
    $entries = @()
    if (Test-Path $manifest) {
        try { $entries = @(Get-Content $manifest -Raw | ConvertFrom-Json) } catch { $entries = @() }
    }
}
$entries = @($entries | Where-Object { $_.image -ne $ImageTag })

# For rpc/llamacpp images, record the rpc-server binary SHA256. Docker image
# IDs can differ per daemon, so cross-host verify (load-hub-tarball.ps1) falls
# back to this binary SHA. Recording it here closes the orchestrator verify blind spot.
$rpcSha = ''
if (Get-Command Get-AlfaRpcServerSha256FromImage -ErrorAction SilentlyContinue) {
    try { $rpcSha = Get-AlfaRpcServerSha256FromImage -ImageTag $ImageTag } catch { $rpcSha = '' }
}

$newEntry = [ordered]@{
    image       = $ImageTag
    file        = $Tarball
    id          = $imgId
    size        = $sizeH
    exported    = (Get-Date).ToUniversalTime().ToString('o')
    source_host = $env:COMPUTERNAME
}
if ($rpcSha) {
    $newEntry['rpc_server_sha256'] = $rpcSha
    Write-Host "  rpc-server sha256=$rpcSha" -ForegroundColor DarkGray
}
$entries += [pscustomobject]$newEntry
# images.json is read by Linux python json.load() on other hosts. PS 5.1
# Set-Content -Encoding UTF8 prepends a BOM that crashes a plain open(); write
# UTF-8 WITHOUT BOM. Force array bracket when only one entry remains.
$manifestJson = $entries | ConvertTo-Json -Depth 6
if (@($entries).Count -le 1) { $manifestJson = "[$manifestJson]" }
[System.IO.File]::WriteAllText($manifest, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "updated manifest: $manifest"

Write-Host ''
Write-Host 'Workers can now load (no rebuild, no internet):'
Write-Host "  docker load -i `"$destPath`""
