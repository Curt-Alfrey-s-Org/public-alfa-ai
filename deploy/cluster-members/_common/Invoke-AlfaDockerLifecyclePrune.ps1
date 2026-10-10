#Requires -Version 5.1
<#
.SYNOPSIS
  Best-effort Docker unused-data prune for cluster/trainer start and stop.

.DESCRIPTION
  Official prune only:
    https://docs.docker.com/reference/cli/docker/system/prune/
    https://docs.docker.com/reference/cli/docker/builder/prune/
    https://docs.docker.com/reference/cli/docker/container/prune/
    https://docs.docker.com/reference/cli/docker/image/rm/
  Never passes --volumes. Never deletes hub hub tarballs.
  Local Windows cache (<Get-AlfaWindowsCacheRoot>/docker-images in WSL) may be wiped (not hub).
  Docs: docs/operations/DOCKER_HOST_CLEANUP.md

  Dot-source this file, then call Invoke-AlfaDockerLifecyclePrune*.
#>

Set-StrictMode -Version Latest

$cacheRootScript = Join-Path $PSScriptRoot 'Get-AlfaWindowsCacheRoot.ps1'
if (Test-Path -LiteralPath $cacheRootScript) {
    . $cacheRootScript
}

function Get-AlfaLifecycleWinCacheWslPath {
    Assert-AlfaWindowsCacheRootHelperLoaded
    return ConvertTo-AlfaWindowsCacheWslPath -WinPath (Get-AlfaWindowsDockerImagesCacheDir)
}

function Get-AlfaLifecyclePruneBash {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('StartModels', 'StartTrain', 'Stop')]
        [string]$Phase,
        [switch]$KeepTaggedImages
    )
    $keep = if ($KeepTaggedImages) { '1' } else { '0' }
    $axolotl = 'axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0'
    $rpc = 'alfa-llamacpp-rpc:cuda128'
    $rpcPascal = 'alfa-llamacpp-rpc:cuda128-pascal'
    $winCache = Get-AlfaLifecycleWinCacheWslPath
    $header = @"
set +e
if ! command -v docker >/dev/null 2>&1; then echo SKIP_NO_DOCKER; exit 0; fi
if ! docker info >/dev/null 2>&1; then echo SKIP_DOCKER_DOWN; exit 0; fi
KEEP_TAGGED=$keep
WIN_CACHE='$winCache'
wipe_win_cache() {
  pat="`$1"
  if [ ! -d "`$WIN_CACHE" ]; then return 0; fi
  echo "== wipe local Windows docker-images cache (`$pat) =="
  case "`$pat" in
    all) rm -f "`$WIN_CACHE"/*.tar.gz "`$WIN_CACHE"/*.loaded ;;
    axolotl) rm -f "`$WIN_CACHE"/axolotl-uv-*.tar.gz "`$WIN_CACHE"/axolotl-uv-*.tar.gz.loaded ;;
    rpc) rm -f "`$WIN_CACHE"/alfa-llamacpp-rpc-*.tar.gz "`$WIN_CACHE"/alfa-llamacpp-rpc-*.tar.gz.loaded ;;
  esac
}

"@
    $header = $header.TrimEnd() + "`n"
    switch ($Phase) {
        'Stop' {
            return $header + @"
echo '== docker builder prune -af (lifecycle-stop) =='
docker builder prune -af
if [ "`$KEEP_TAGGED" = "1" ]; then
  echo '== docker system prune -f (keep tagged; no volumes) =='
  docker system prune -f
else
  echo '== docker system prune -af (no volumes) =='
  docker system prune -af
fi
wipe_win_cache all
echo LIFECYCLE_PRUNE_DONE
exit 0
"@
        }
        'StartModels' {
            return $header + @"
echo '== docker container prune -f =='
docker container prune -f
echo '== docker builder prune -af =='
docker builder prune -af
echo '== docker system prune -f (dangling only) =='
docker system prune -f
echo '== docker rmi leftover Axolotl =='
docker rmi -f $axolotl
wipe_win_cache axolotl
echo LIFECYCLE_PRUNE_DONE
exit 0
"@
        }
        default {
            return $header + @"
echo '== docker container prune -f =='
docker container prune -f
echo '== docker builder prune -af =='
docker builder prune -af
echo '== docker system prune -f (dangling only) =='
docker system prune -f
echo '== docker rmi leftover RPC =='
docker rmi -f $rpc $rpcPascal
wipe_win_cache rpc
echo LIFECYCLE_PRUNE_DONE
exit 0
"@
        }
    }
}

function ConvertTo-AlfaLifecycleBase64 {
    param([Parameter(Mandatory)][string]$BashBody)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($BashBody))
}

function Invoke-AlfaDockerLifecyclePruneWslLocal {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('StartModels', 'StartTrain', 'Stop')]
        [string]$Phase,
        [string]$Label = 'orchestrator WSL',
        [switch]$KeepTaggedImages
    )
    Write-Host ("== Docker lifecycle prune {0} ({1}) ==" -f $Phase, $Label)
    $bash = Get-AlfaLifecyclePruneBash -Phase $Phase -KeepTaggedImages:$KeepTaggedImages
    $b64 = ConvertTo-AlfaLifecycleBase64 -BashBody $bash
    try {
        wsl.exe -d Ubuntu -- bash -lc "echo $b64 | base64 -d | bash"
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("WARN: lifecycle prune {0} exit {1} (continuing)" -f $Label, $LASTEXITCODE)
        }
    } catch {
        Write-Host ("WARN: lifecycle prune {0}: {1}" -f $Label, $_.Exception.Message)
    }
}

function Invoke-AlfaDockerLifecyclePruneWslSsh {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('StartModels', 'StartTrain', 'Stop')]
        [string]$Phase,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [string]$KeyPath,
        [switch]$KeepTaggedImages
    )
    Write-Host ("== Docker lifecycle prune {0} ({1}) ==" -f $Phase, $Label)
    if ($KeyPath -and -not (Test-Path -LiteralPath $KeyPath)) {
        Write-Host ("WARN: lifecycle prune skip {0}: key missing" -f $Label)
        return
    }
    $bash = Get-AlfaLifecyclePruneBash -Phase $Phase -KeepTaggedImages:$KeepTaggedImages
    $b64 = ConvertTo-AlfaLifecycleBase64 -BashBody $bash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    try {
        if ($KeyPath) {
            & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $KeyPath $Target $remote
        } else {
            & ssh -o BatchMode=yes -o ConnectTimeout=20 $Target $remote
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("WARN: lifecycle prune {0} exit {1} (continuing)" -f $Label, $LASTEXITCODE)
        }
    } catch {
        Write-Host ("WARN: lifecycle prune {0}: {1}" -f $Label, $_.Exception.Message)
    }
}

function Invoke-AlfaDockerLifecyclePruneLinuxSsh {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('StartModels', 'StartTrain', 'Stop')]
        [string]$Phase,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [string]$KeyPath,
        [switch]$KeepTaggedImages
    )
    Write-Host ("== Docker lifecycle prune {0} ({1} native) ==" -f $Phase, $Label)
    $bash = Get-AlfaLifecyclePruneBash -Phase $Phase -KeepTaggedImages:$KeepTaggedImages
    $b64 = ConvertTo-AlfaLifecycleBase64 -BashBody $bash
    $remote = "bash -lc 'echo $b64 | base64 -d | bash'"
    try {
        if ($KeyPath -and (Test-Path -LiteralPath $KeyPath)) {
            & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $KeyPath $Target $remote
        } else {
            & ssh -o BatchMode=yes -o ConnectTimeout=20 $Target $remote
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("WARN: lifecycle prune {0} exit {1} (continuing)" -f $Label, $LASTEXITCODE)
        }
    } catch {
        Write-Host ("WARN: lifecycle prune {0}: {1}" -f $Label, $_.Exception.Message)
    }
}

function Get-AlfaAxolotlHubTarballNfs {
    return '/mnt/cluster/docker-images/axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz'
}

function Get-AlfaAxolotlImageTag {
    return 'axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0'
}

function Get-AlfaEnsureAxolotlImageBash {
    $image = Get-AlfaAxolotlImageTag
    $tarball = Get-AlfaAxolotlHubTarballNfs
    return @"
set -e
IMAGE='$image'
TARBALL='$tarball'
if docker image inspect "`$IMAGE" >/dev/null 2>&1; then
  echo AXOLOTL_IMAGE_OK
  exit 0
fi
if [ ! -f "`$TARBALL" ]; then
  echo "FAIL: Axolotl image missing and hub tarball not at `$TARBALL"
  exit 1
fi
echo "== docker load -i `$TARBALL (hub NFS; no registry pull) =="
docker load -i "`$TARBALL"
docker image inspect "`$IMAGE" >/dev/null
echo AXOLOTL_IMAGE_LOADED
"@
}

function Invoke-AlfaEnsureAxolotlImageWslSsh {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [string]$KeyPath
    )
    Write-Host ("== Ensure Axolotl image on {0} (hub NFS docker load) ==" -f $Label)
    if ($KeyPath -and -not (Test-Path -LiteralPath $KeyPath)) {
        throw ("Axolotl image ensure skipped; SSH key missing for {0}" -f $Label)
    }
    $bash = Get-AlfaEnsureAxolotlImageBash
    $b64 = ConvertTo-AlfaLifecycleBase64 -BashBody $bash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    if ($KeyPath) {
        & ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=120 -i $KeyPath $Target $remote
    } else {
        & ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=120 $Target $remote
    }
    if ($LASTEXITCODE -ne 0) {
        throw ("Axolotl image missing on {0} after hub load (exit {1})" -f $Label, $LASTEXITCODE)
    }
}

function Invoke-AlfaEnsureAxolotlImageLinuxSsh {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [string]$KeyPath
    )
    Write-Host ("== Ensure Axolotl image on {0} (hub NFS docker load) ==" -f $Label)
    $bash = Get-AlfaEnsureAxolotlImageBash
    $b64 = ConvertTo-AlfaLifecycleBase64 -BashBody $bash
    $remote = "bash -lc 'echo $b64 | base64 -d | bash'"
    if ($KeyPath -and (Test-Path -LiteralPath $KeyPath)) {
        & ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=120 -i $KeyPath $Target $remote
    } else {
        & ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=120 $Target $remote
    }
    if ($LASTEXITCODE -ne 0) {
        throw ("Axolotl image missing on {0} after hub load (exit {1})" -f $Label, $LASTEXITCODE)
    }
}
