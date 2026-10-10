<#
.SYNOPSIS
    Shared helper: build/bring up llama.cpp RPC tier 3b (Coder-Next 80B shards or coordinator).
.DESCRIPTION
    LAN-first: optionally `docker load` alfa-llamacpp-rpc:cuda128 from \\hub\temp hub tarballs
    before `docker compose build`. Matches deploy.ps1 patterns on Win11 workers.

    Roles:
      - Shard        - one rpc-server (docker-compose.rpc-server.yml)
      - ShardDual93  - two rpc-servers on orchestrator (docker-compose.rpc-server.dual-gpu-93.yml)
      - Coordinator  - llama-server on gaming-b (docker-compose.rpc-main.yml)

    Prerequisites: stop Petals workers on GPUs used for 3b (mutual exclusion). See
    docs/LLAMACPP_RPC_OPERATOR.md.

.PARAMETER RepoDir
    Git repo root (e.g. C:\alfa-ai or C:\alfa-ai-worker).
.PARAMETER EnvFileRpc
    Path to deploy/llamacpp-rpc/.env.rpc (must exist on this host; gitignored).
.PARAMETER Role
    Shard | ShardDual93 | Coordinator
.PARAMETER SmbDockerImages
    Optional directory of *.tar.gz for docker load (same hub layout as deploy.ps1).
#>

# Directory of this file (_common) - stable when dot-sourced from member scripts.
$script:AlfaLlamacppRpcCommonDir = $PSScriptRoot

$hubTarballLoader = Join-Path $script:AlfaLlamacppRpcCommonDir 'load-hub-tarball.ps1'
if (Test-Path -LiteralPath $hubTarballLoader) {
    . $hubTarballLoader
}

$cacheRootScript = Join-Path $script:AlfaLlamacppRpcCommonDir 'Get-AlfaWindowsCacheRoot.ps1'
if (-not (Test-Path -LiteralPath $cacheRootScript)) {
    throw "Missing shared cache helper: $cacheRootScript (run Get-AlfaWindowsCacheRoot or set ALFA_WINDOWS_CACHE_ROOT)"
}
. $cacheRootScript

$wslDockerHelper = Join-Path $script:AlfaLlamacppRpcCommonDir 'wsl-docker.ps1'
if (Test-Path -LiteralPath $wslDockerHelper) {
    . $wslDockerHelper
}

$wslNetHelper = Join-Path $script:AlfaLlamacppRpcCommonDir 'install-wsl-nat-portproxy.ps1'
if (Test-Path -LiteralPath $wslNetHelper) {
    . $wslNetHelper
}

function Test-AlfaRpcCacheReuseEnabled {
    param(
        [Parameter(Mandatory)]
        [string]$EnvRpcPath
    )
    if (-not (Test-Path -LiteralPath $EnvRpcPath)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $EnvRpcPath) {
        if ($line -match '^\s*CACHE_REUSE=(.+)$') {
            $val = $Matches[1].Trim()
            if ($val -and $val -ne '0') {
                return $true
            }
        }
    }
    return $false
}

function Test-AlfaRpcSpeculativeDraftEnabled {
    param(
        [Parameter(Mandatory)]
        [string]$EnvRpcPath
    )
    if (-not (Test-Path -LiteralPath $EnvRpcPath)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $EnvRpcPath) {
        if ($line -match '^\s*MODEL_DRAFT_FILE=(.+)$') {
            $val = $Matches[1].Trim()
            if ($val) {
                return $true
            }
        }
    }
    return $false
}

function Test-AlfaRpcCpuCoordinatorEnabled {
    param(
        [Parameter(Mandatory)]
        [string]$EnvRpcPath
    )
    if (-not (Test-Path -LiteralPath $EnvRpcPath)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $EnvRpcPath) {
        if ($line -match '^\s*CUDA_VISIBLE_DEVICES=(.*)$') {
            return ($Matches[1].Trim().Length -eq 0)
        }
    }
    return $false
}

function Invoke-AlfaLlamacppRpcDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Shard', 'ShardDual93', 'Coordinator')]
        [string]$Role,
        [Parameter(Mandatory)]
        [string]$RepoDir,
        [Parameter(Mandatory)]
        [string]$EnvFileRpc,
        [string]$SmbDockerImages = '\\hub\docker-images'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $Llc = Join-Path $RepoDir 'deploy\llamacpp-rpc'
    if (-not (Test-Path $Llc)) {
        throw "Missing llama.cpp RPC stack: $Llc"
    }
    if (-not (Test-Path $EnvFileRpc)) {
        throw "Missing $EnvFileRpc - create deploy\llamacpp-rpc\.env.rpc on this host before deploy (gitignored)."
    }

    $initScript = Join-Path $script:AlfaLlamacppRpcCommonDir 'initialize-windows-deploy.ps1'
    if (Test-Path -LiteralPath $initScript) {
        . $initScript
    }

    Initialize-AlfaWindowsDockerMirror
    Assert-AlfaWindowsDockerEngine

    # Warm path (same as Linux load-llamacpp-rpc-from-hub.sh): if the image is
    # already loaded, skip SMB vendor sync, UNC probes, and docker load.
    $rpcImage = 'alfa-llamacpp-rpc:cuda128'
    $forceHubLoad = ($env:FORCE_HUB_RPC_LOAD -eq '1')
    $haveRpcImage = $false
    if (-not $forceHubLoad) {
        $dcPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & docker image inspect $rpcImage 2>$null | Out-Null
        $haveRpcImage = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $dcPref
    }
    if ($haveRpcImage) {
        Write-Host ("  Using existing image {0} (skip hub tarball / vendor sync; FORCE_HUB_RPC_LOAD=1 to reload)" -f $rpcImage) -ForegroundColor Green
    } else {
        # FORCE_HUB_RPC_LOAD / cold load: image tarball is enough. Vendor source
        # tree is only for docker build; SMB Access Denied on gaming/orchestrator must not
        # abort start (docs/inference_GAMING_HOST_JOIN.md).
        if (-not $forceHubLoad) {
            $syncVendor = Join-Path $script:AlfaLlamacppRpcCommonDir 'sync-llamacpp-vendor-from-hub.ps1'
            if (Test-Path $syncVendor) {
                & $syncVendor -RepoDir $RepoDir
            }
        } else {
            Write-Host '  FORCE_HUB_RPC_LOAD=1 - skip llama.cpp vendor SMB sync (docker load only)' -ForegroundColor DarkGray
        }

        $canonicalRpcTarball = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
        # Permanent local cache (same policy as Linux ensure-rpc-image-local-cache.sh).
        Assert-AlfaWindowsCacheRootHelperLoaded
        $localRpcCache = Get-AlfaWindowsDockerImagesCacheDir
        if (-not (Test-Path -LiteralPath $localRpcCache)) {
            New-Item -ItemType Directory -Path $localRpcCache -Force | Out-Null
        }
        $smbDockerSearchRoots = @(
            $localRpcCache,
            '\\hub\docker-images',
            '\\hub\docker-images',
            $SmbDockerImages,
            'H:\',
            '\\hub\temp\cluster_members\_common\docker-images'
        )
        $seenRoots = @{}
        $smbDockerSearchRoots = @($smbDockerSearchRoots | Where-Object {
            if (-not $_ -or $seenRoots.ContainsKey($_)) { return $false }
            $seenRoots[$_] = $true
            return $true
        })

        $b8552Tarball = $null
        foreach ($root in $smbDockerSearchRoots) {
            # UNC roots can throw Access Denied under StrictMode; skip and try next.
            $rootOk = $false
            try {
                $rootOk = Test-Path -LiteralPath $root
            } catch {
                $rootOk = $false
            }
            if (-not $rootOk) { continue }
            if ($root -match '^[A-Za-z]:\\?$') {
                $driveLetter = $root.Substring(0, 1)
                if (-not (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue)) {
                    continue
                }
            }
            try {
                $candidate = Join-Path $root $canonicalRpcTarball
                if (Test-Path -LiteralPath $candidate) {
                    $b8552Tarball = Get-Item -LiteralPath $candidate
                    Write-Host ("  Hub docker tarballs: {0} at {1}" -f $canonicalRpcTarball, $root) -ForegroundColor DarkGray
                    break
                }
            } catch {
                continue
            }
        }
        if (-not $b8552Tarball) {
            throw ("Missing hub tarball {0} under {1}. Build on hub: sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh" -f $canonicalRpcTarball, ($smbDockerSearchRoots -join '; '))
        }
        # Promote hub/UNC copy into local docker-images cache once so later starts skip SMB.
        # orchestrator often can Test-Path \\hub\docker-images but Copy-Item gets Access
        # Denied (SMB ACL / OpenSSH). Fall back: WSL NFS /mnt/cluster, then other
        # non-UNC roots. See docs/inference_GAMING_HOST_JOIN.md.
        $localTbPath = Join-Path $localRpcCache $canonicalRpcTarball
        $tbFull = $b8552Tarball.FullName
        if ($tbFull -ne $localTbPath) {
            if (-not (Test-Path -LiteralPath $localTbPath)) {
                Write-Host ("  Promoting RPC tarball -> {0}" -f $localTbPath) -ForegroundColor Cyan
                $promotedOk = $false
                try {
                    Copy-Item -LiteralPath $tbFull -Destination $localTbPath -Force -ErrorAction Stop
                    $promotedOk = $true
                } catch {
                    Write-Warning ("Promote from {0} failed: {1}" -f $tbFull, $_.Exception.Message)
                }
                if (-not $promotedOk) {
                    $wslSrc = "/mnt/cluster/docker-images/$canonicalRpcTarball"
                    $wslDest = ConvertTo-AlfaWindowsCacheWslPath -WinPath $localTbPath
                    $wslDestDir = ($wslDest -replace '/[^/]+$', '')
                    $wslLc = "if [ -f `"$wslSrc`" ]; then mkdir -p `"$wslDestDir`" && cp -f `"$wslSrc`" `"$wslDest`" && ls -lh `"$wslDest`"; else echo NO_NFS_TARBALL; exit 2; fi"
                    $prevEa = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    $wslOut = & wsl.exe -d Ubuntu bash -lc $wslLc 2>&1
                    $wslEc = $LASTEXITCODE
                    $ErrorActionPreference = $prevEa
                    if ($null -ne $wslOut) {
                        Write-Host ($wslOut | Out-String).Trim()
                    }
                    if (($wslEc -eq 0) -and (Test-Path -LiteralPath $localTbPath)) {
                        $promotedOk = $true
                        Write-Host '  Promoted RPC tarball via WSL /mnt/cluster (NFS)' -ForegroundColor Green
                    }
                }
                if (-not $promotedOk) {
                    foreach ($root in $smbDockerSearchRoots) {
                        if ($root -eq $localRpcCache) { continue }
                        if ($root -match '^\\\\') { continue }
                        try {
                            $alt = Join-Path $root $canonicalRpcTarball
                            if (-not (Test-Path -LiteralPath $alt)) { continue }
                            Copy-Item -LiteralPath $alt -Destination $localTbPath -Force -ErrorAction Stop
                            $promotedOk = $true
                            Write-Host ("  Promoted RPC tarball from {0}" -f $root) -ForegroundColor Green
                            break
                        } catch {
                            continue
                        }
                    }
                }
                if (-not $promotedOk) {
                    # Members pull from hub: scp from hub (key id_ed25519_93_111 on orchestrator).
                    $scpKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_111'
                    $scpRemote = "operator@hub:/mnt/HDDs/Alfa-AI/docker-images/$canonicalRpcTarball"
                    if (Test-Path -LiteralPath $scpKey) {
                        Write-Host ("  Promoting RPC tarball via scp from hub -> {0}" -f $localTbPath) -ForegroundColor Cyan
                        $prevEa2 = $ErrorActionPreference
                        $ErrorActionPreference = 'Continue'
                        & scp.exe -i $scpKey -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $scpRemote $localTbPath
                        $scpEc = $LASTEXITCODE
                        $ErrorActionPreference = $prevEa2
                        if (($scpEc -eq 0) -and (Test-Path -LiteralPath $localTbPath)) {
                            $promotedOk = $true
                            Write-Host '  Promoted RPC tarball via scp from hub' -ForegroundColor Green
                        }
                    }
                }
                if (-not $promotedOk) {
                    throw ("Cannot stage {0} into {1}. SMB Access Denied; WSL /mnt/cluster and scp from hub failed. Copy the tarball to {1} manually, then retry." -f $canonicalRpcTarball, $localRpcCache)
                }
            }
            if (Test-Path -LiteralPath $localTbPath) {
                $b8552Tarball = Get-Item -LiteralPath $localTbPath
            }
        }
        $tarballs = @($b8552Tarball)
        if ($tarballs -and $tarballs.Count -gt 0) {
            foreach ($tb in $tarballs) {
                $hubRoot = Split-Path -Parent $tb.FullName
                Write-Host "  docker load: $($tb.Name) ..." -ForegroundColor Cyan
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $loaded = Invoke-AlfaHubTarballLoad -Tarball $tb.Name -HubRoot $hubRoot -ImageTag $rpcImage
                    if (-not $loaded) {
                        throw ("docker load failed for {0}" -f $tb.Name)
                    }
                } finally {
                    $ErrorActionPreference = $prev
                }
            }
        }
        $dcPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & docker image inspect $rpcImage 2>$null | Out-Null
        $haveRpcImage = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $dcPref
        if (-not $haveRpcImage) {
            if (Get-Command Assert-AlfaHubFallbackProceed -ErrorAction SilentlyContinue) {
                Assert-AlfaHubFallbackProceed `
                    -Context 'llamacpp-docker-image' `
                    -HubPath ($SmbDockerImages) `
                    -FallbackDescription "docker compose build $rpcImage (GitHub git clone + apt inside builder; public indexes)."
            }
            Write-Warning "No local image $rpcImage; compose build will run (operator approved)."
        } else {
            Write-Host ("  Using existing image {0} (skip build; hub tarball or prior load)." -f $rpcImage) -ForegroundColor Green
        }
    }

    # WSL docker compose cannot read Windows absolute --env-file paths; use repo-relative name.
    $envRpcLeaf = '.env.rpc'
    $envRpcInLlc = Join-Path $Llc $envRpcLeaf
    if (-not (Test-Path -LiteralPath $envRpcInLlc)) {
        Copy-Item -Force -Path $EnvFileRpc -Destination $envRpcInLlc
    }

    Push-Location $Llc
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        switch ($Role) {
            'Shard' {
                Write-Host '== llama.cpp rpc-server (single GPU) ==' -ForegroundColor Cyan
                $shardFiles = @('-f', 'docker-compose.rpc-server.yml')
                if (Get-Command Test-AlfaUseWslDockerCli -ErrorAction SilentlyContinue) {
                    if (Test-AlfaUseWslDockerCli) {
                        if (Get-Command Test-AlfaWslNatPortProxyRequired -ErrorAction SilentlyContinue) {
                            if (Test-AlfaWslNatPortProxyRequired) {
                                $wslShard = Join-Path $Llc 'docker-compose.rpc-server.wsl-93.yml'
                                if (Test-Path -LiteralPath $wslShard) {
                                    Write-Host '  WSL NAT (no mirrored): publish RPC_PORT via bridge+ports' -ForegroundColor DarkGray
                                    $shardFiles += '-f', 'docker-compose.rpc-server.wsl-93.yml'
                                }
                            } else {
                                Write-Host '  WSL mirrored: network_mode host (LAN-visible; Hyper-V firewall required)' -ForegroundColor DarkGray
                            }
                        } else {
                            $wslShard = Join-Path $Llc 'docker-compose.rpc-server.wsl-93.yml'
                            if (Test-Path -LiteralPath $wslShard) {
                                Write-Host '  WSL Docker: publishing RPC_PORT (not host network)' -ForegroundColor DarkGray
                                $shardFiles += '-f', 'docker-compose.rpc-server.wsl-93.yml'
                            }
                        }
                    }
                }
                if (-not $haveRpcImage) {
                    & docker compose --env-file $envRpcLeaf @shardFiles build
                    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed ($LASTEXITCODE)" }
                }
                if ($haveRpcImage) {
                    & docker compose --env-file $envRpcLeaf @shardFiles up -d --no-build --force-recreate
                } else {
                    & docker compose --env-file $envRpcLeaf @shardFiles up -d --force-recreate
                }
                if ($LASTEXITCODE -ne 0) { throw "docker compose up failed ($LASTEXITCODE)" }
                $waitRpc = Join-Path $script:AlfaLlamacppRpcCommonDir 'wait-rpc-server-port.ps1'
                if (Test-Path -LiteralPath $waitRpc) {
                    . $waitRpc
                    $rpcPort = 31350
                    foreach ($line in Get-Content -LiteralPath $envRpcInLlc) {
                        if ($line -match '^\s*RPC_PORT=(.+)$') {
                            $rpcPort = [int]$Matches[1].Trim()
                            break
                        }
                    }
                    Wait-AlfaRpcServerPort -Port $rpcPort -HostName '127.0.0.1'
                    # LAN probe must use THIS host's IP (not hardcoded orchestrator). Win10 NAT
                    # workers (gaming-a) listen on orchestrator; probing orchestrator:RPC_PORT always fails.
                    # Official: Get-NetIPAddress (NetTCPIP)
                    # https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netipaddress
                    # Scalar [string] required (Wait-AlfaRpcServerPort -HostName). Do not wrap in @().
                    $lanIp = [string]$env:ALFA_RPC_LAN_IP
                    if ([string]::IsNullOrWhiteSpace($lanIp)) {
                        try {
                            $lanIp = [string](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                                Where-Object {
                                    $_.IPAddress -like 'orchestrator0.*' -and
                                    $_.IPAddress -ne '127.0.0.1' -and
                                    $_.PrefixOrigin -ne 'WellKnown'
                                } |
                                Select-Object -ExpandProperty IPAddress -First 1)
                        } catch {
                            $lanIp = ''
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($lanIp)) {
                        throw 'Could not determine LAN IPv4 for rpc-server probe (set ALFA_RPC_LAN_IP)'
                    }
                    Wait-AlfaRpcServerPort -Port $rpcPort -HostName $lanIp -TimeoutSec 120
                }
                $assertCuda = Join-Path $script:AlfaLlamacppRpcCommonDir 'assert-rpc-server-cuda.sh'
                if (Test-Path -LiteralPath $assertCuda) {
                    if (Get-Command Test-AlfaUseWslDockerCli -ErrorAction SilentlyContinue) {
                        if (Test-AlfaUseWslDockerCli) {
                            if ($assertCuda -match '^([A-Za-z]):\\(.*)$') {
                                $wslAssert = '/mnt/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
                                Write-Host '  CUDA assert (no CPU fallback)...' -ForegroundColor DarkGray
                                wsl.exe -d Ubuntu bash -lc "bash '$wslAssert' llamacpp-rpc-server"
                                if ($LASTEXITCODE -ne 0) {
                                    throw 'rpc-server CUDA assert failed (no CPU fallback allowed)'
                                }
                            }
                        }
                    }
                }
            }
            'ShardDual93' {
                Write-Host '== llama.cpp rpc-server (orchestrator dual GPU :31350 + :31355) ==' -ForegroundColor Cyan
                if (-not $haveRpcImage) {
                    & docker compose --env-file $envRpcLeaf -f docker-compose.rpc-server.dual-gpu-93.yml build
                    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed ($LASTEXITCODE)" }
                }
                if ($haveRpcImage) {
                    & docker compose --env-file $envRpcLeaf -f docker-compose.rpc-server.dual-gpu-93.yml up -d --no-build
                } else {
                    & docker compose --env-file $envRpcLeaf -f docker-compose.rpc-server.dual-gpu-93.yml up -d
                }
                if ($LASTEXITCODE -ne 0) { throw "docker compose up failed ($LASTEXITCODE)" }
            }
            'Coordinator' {
                Write-Host '== llama.cpp coordinator (llama-server) ==' -ForegroundColor Cyan
                $mainFiles = @('-f', 'docker-compose.rpc-main.yml')
                if (Get-Command Test-AlfaUseWslDockerCli -ErrorAction SilentlyContinue) {
                    if (Test-AlfaUseWslDockerCli) {
                        if (Get-Command Test-AlfaWslNatPortProxyRequired -ErrorAction SilentlyContinue) {
                            if (Test-AlfaWslNatPortProxyRequired) {
                                $wslMain = Join-Path $Llc 'docker-compose.rpc-main.wsl-93.yml'
                                if (Test-Path -LiteralPath $wslMain) {
                                    Write-Host '  WSL NAT (no mirrored): publish :31360 via bridge+ports' -ForegroundColor DarkGray
                                    $mainFiles += '-f', 'docker-compose.rpc-main.wsl-93.yml'
                                }
                            } else {
                                Write-Host '  WSL mirrored: network_mode host for coordinator' -ForegroundColor DarkGray
                            }
                        } else {
                            $wslMain = Join-Path $Llc 'docker-compose.rpc-main.wsl-93.yml'
                            if (Test-Path -LiteralPath $wslMain) {
                                Write-Host '  WSL Docker: publishing :31360 (not host network)' -ForegroundColor DarkGray
                                $mainFiles += '-f', 'docker-compose.rpc-main.wsl-93.yml'
                            }
                        }
                    }
                }
                if (Test-AlfaRpcSpeculativeDraftEnabled -EnvRpcPath $envRpcInLlc) {
                    $specMain = Join-Path $Llc 'docker-compose.rpc-main.speculative.yml'
                    if (Test-Path -LiteralPath $specMain) {
                        Write-Host '  Speculative draft enabled (MODEL_DRAFT_FILE in .env.rpc)' -ForegroundColor DarkGray
                        $mainFiles += '-f', 'docker-compose.rpc-main.speculative.yml'
                    } else {
                        Write-Warning "MODEL_DRAFT_FILE set but missing $specMain"
                    }
                }
                if (Test-AlfaRpcCacheReuseEnabled -EnvRpcPath $envRpcInLlc) {
                    $codeCache = Join-Path $Llc 'docker-compose.rpc-main.code-cache.yml'
                    $cpuEnabled = Test-AlfaRpcCpuCoordinatorEnabled -EnvRpcPath $envRpcInLlc
                    if ($cpuEnabled) {
                        Write-Host '  CACHE_REUSE via code27-cpu overlay' -ForegroundColor DarkGray
                    }
                    elseif (Test-Path -LiteralPath $codeCache) {
                        Write-Host '  CACHE_REUSE enabled (Code profile dense model only)' -ForegroundColor DarkGray
                        $mainFiles += '-f', 'docker-compose.rpc-main.code-cache.yml'
                    } else {
                        Write-Warning "CACHE_REUSE set but missing $codeCache"
                    }
                }
                if (Test-AlfaRpcCpuCoordinatorEnabled -EnvRpcPath $envRpcInLlc) {
                    $cpuMain = Join-Path $Llc 'docker-compose.rpc-main.cpu-coordinator.yml'
                    $code27Cpu = Join-Path $Llc 'docker-compose.rpc-main.code27-cpu.yml'
                    if (Test-Path -LiteralPath $cpuMain) {
                        Write-Host '  CPU coordinator (CUDA_VISIBLE_DEVICES empty; 3060 free for Ollama 35B)' -ForegroundColor DarkGray
                        $mainFiles += '-f', 'docker-compose.rpc-main.cpu-coordinator.yml'
                    } else {
                        Write-Warning "CUDA_VISIBLE_DEVICES empty but missing $cpuMain"
                    }
                    if (Test-Path -LiteralPath $code27Cpu) {
                        Write-Host '  Code27: --tensor-split + --fit off + --no-mmap (no fit probe loop)' -ForegroundColor DarkGray
                        $mainFiles += '-f', 'docker-compose.rpc-main.code27-cpu.yml'
                    }
                    $code27Load = Join-Path $Llc 'docker-compose.rpc-main.code27-load.yml'
                    if (Test-Path -LiteralPath $code27Load) {
                        Write-Host '  Code27: restart=no (single load pass; no reload loop)' -ForegroundColor DarkGray
                        $mainFiles += '-f', 'docker-compose.rpc-main.code27-load.yml'
                    }
                }
                if (-not $haveRpcImage) {
                    & docker compose --env-file $envRpcLeaf @mainFiles build
                    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed ($LASTEXITCODE)" }
                }
                if ($haveRpcImage) {
                    & docker compose --env-file $envRpcLeaf @mainFiles up -d --no-build --remove-orphans
                } else {
                    & docker compose --env-file $envRpcLeaf @mainFiles up -d --remove-orphans
                }
                if ($LASTEXITCODE -ne 0) { throw "docker compose up failed ($LASTEXITCODE)" }
            }
        }
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
    Write-Host '== llama.cpp RPC compose up complete ==' -ForegroundColor Green
}


