#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone Qwen2.5-Coder-7B llama-server on gaming-c WSL (:8470) with LoRA adapter.
.DESCRIPTION
    Not an RPC shard. Mutually exclusive with inference opt-in gaming-c and train island.
    Refuses when inference RPC containers are running (do not piecemeal-stop the shard).
    Hub GGUF via NFS /mnt/cluster. See docs/operations/ALFA_7B_SERVE_ALONGSIDE_27B.md
.PARAMETER Port
    Host port for llama-server (default 8470).
.PARAMETER NoLora
    Serve base model only. Mutually exclusive with -LoraGguf.
.PARAMETER LoraGguf
    LoRA GGUF filename (e.g. pool-7b-qlora-v2.gguf). Empty keeps .env / example default (v1).
.EXAMPLE
    cd C:\Users\YOURUSER\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\deploy-7b-llama-server.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\deploy-7b-llama-server.ps1 -LoraGguf pool-7b-qlora-v2.gguf
#>
[CmdletBinding()]
param(
    [int]$Port = 8470,
    [switch]$NoLora,
    [string]$LoraGguf = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($NoLora -and $LoraGguf -ne '') {
    throw 'Cannot use -NoLora and -LoraGguf together.'
}

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Common = Join-Path $RepoDir 'deploy\cluster-members\_common'
$Llc = Join-Path $RepoDir 'deploy\llamacpp-rpc'
$EnvExample = Join-Path $Llc '.env.7b-serve.example'
$EnvPath = Join-Path $Llc '.env.7b-serve'
$ComposeFile = Join-Path $Llc 'docker-compose.llama-server-7b.yml'

. (Join-Path $Common 'Get-AlfaWindowsCacheRoot.ps1')
. (Join-Path $Common 'Test-AlfaRpcImageDepsPreflight.ps1')
if (-not [string]::IsNullOrWhiteSpace($env:ALFA_59_CACHE_WIN)) {
    $env:ALFA_WINDOWS_CACHE_ROOT = $env:ALFA_59_CACHE_WIN.Trim()
}
$CacheRoot = Get-AlfaWindowsCacheRoot
if ($CacheRoot -match '^[Cc]:\\') {
    throw "7B cache must not be on C: (got $CacheRoot). Set ALFA_WINDOWS_CACHE_ROOT=G:\alfa-ai-cache."
}
$HubCacheWin = Join-Path $CacheRoot '7b-hub'
$HubCacheWsl = ConvertTo-AlfaWindowsCacheWslPath -WinPath $HubCacheWin
Write-Host ("  7B cache root: {0} (wsl {1})" -f $CacheRoot, $HubCacheWsl) -ForegroundColor DarkGray

function ConvertTo-Alfa7bWslPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    throw "Not a Windows path: $Path"
}

function Invoke-AlfaWslBashScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$EnvPrefix = ''
    )
    $wslScript = ConvertTo-Alfa7bWslPath -Path $ScriptPath
    wsl.exe -d Ubuntu bash -lc "${EnvPrefix}bash '$wslScript'"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL bash failed (exit $LASTEXITCODE): $ScriptPath"
    }
}

function Test-Alfa7bHubModelPresent {
    param(
        [Parameter(Mandatory)][string]$HubDirWsl,
        [Parameter(Mandatory)][string]$ModelFile,
        [Parameter(Mandatory)][string]$ModelsSubdir
    )
    $wslPath = "$HubDirWsl/$ModelsSubdir/$ModelFile"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    wsl.exe -d Ubuntu bash -lc "test -f '$wslPath' && echo OK" 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap
    return $ok
}

function Invoke-Alfa7bEnsureNfsHubMount {
    # Best-effort NFS; gaming-c WSL often cannot reach hub NFS (timeout). Local cache fallback below.
    $mountScript = Join-Path $RepoDir 'scripts\mount_nfs_models.sh'
    if (-not (Test-Path -LiteralPath $mountScript)) {
        Write-Host "  Skip NFS (missing $mountScript)" -ForegroundColor DarkGray
        return
    }
    Write-Host '== 7B serve: NFS hub /mnt/cluster (best effort) ==' -ForegroundColor Cyan
    try {
        Invoke-AlfaWslBashScript -ScriptPath $mountScript -EnvPrefix 'hub_IP=hub '
    } catch {
        Write-Host '  WARN: NFS mount failed; will use local hub cache if staged' -ForegroundColor Yellow
    }
}

function Invoke-Alfa7bEnsureRpcCuda128Image {
    # WSL docker; use picker cache (never C: on gaming-c). Skip load when image exists.
    $ImageTag = 'alfa-llamacpp-rpc:cuda128'
    $Tarball = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
    $forceLoad = ($env:FORCE_HUB_RPC_LOAD -eq '1')

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    wsl.exe -d Ubuntu docker image inspect $ImageTag 2>$null | Out-Null
    $haveImage = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap
    if ($haveImage -and -not $forceLoad) {
        Write-Host ("  Using existing {0} (skip hub load; FORCE_HUB_RPC_LOAD=1 to reload)" -f $ImageTag) -ForegroundColor Green
        return
    }

    $LocalCache = Get-AlfaWindowsDockerImagesCacheDir
    if ($LocalCache -match '^[Cc]:\\') {
        throw "RPC tarball cache must not be on C: (got $LocalCache). Set ALFA_WINDOWS_CACHE_ROOT=G:\alfa-ai-cache."
    }
    if (-not (Test-Path -LiteralPath $LocalCache)) {
        New-Item -ItemType Directory -Path $LocalCache -Force | Out-Null
    }
    $dest = Join-Path $LocalCache $Tarball
    $src = Find-AlfaRpcTarballPath -TarballName $Tarball -LocalCache $LocalCache
    if ($src) {
        Write-Host ("  Hub docker tarball: {0} at {1}" -f $Tarball, (Split-Path -Parent $src)) -ForegroundColor DarkGray
    }

    if (-not $src) {
        $scpKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_111'
        $scpRemote = "operator@hub:/mnt/HDDs/Alfa-AI/docker-images/$Tarball"
        if (Test-Path -LiteralPath $scpKey) {
            Write-Host ("  Promoting RPC tarball via scp from hub -> {0}" -f $dest) -ForegroundColor Cyan
            $prevEa = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & scp.exe -i $scpKey -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $scpRemote $dest
            $scpEc = $LASTEXITCODE
            $ErrorActionPreference = $prevEa
            if (($scpEc -eq 0) -and (Test-Path -LiteralPath $dest)) {
                $src = $dest
                Write-Host '  Promoted RPC tarball via scp from hub' -ForegroundColor Green
            }
        }
    }

    if ($src -and ($src -ne $dest)) {
        $needCopy = $true
        if (Test-Path -LiteralPath $dest) {
            $srcLen = (Get-Item -LiteralPath $src).Length
            $dstLen = (Get-Item -LiteralPath $dest).Length
            if ($srcLen -eq $dstLen) {
                $needCopy = $false
            }
        }
        if ($needCopy) {
            Write-Host ("  Copying {0} -> {1} (local warm path)" -f $src, $dest) -ForegroundColor Cyan
            Copy-Item -LiteralPath $src -Destination "$dest.tmp" -Force
            Move-Item -LiteralPath "$dest.tmp" -Destination $dest -Force
        }
    }

    if (-not (Test-Path -LiteralPath $dest)) {
        throw ("Missing hub tarball {0}. Checked SMB roots and scp from hub. Copy to {1} manually." -f $Tarball, $LocalCache)
    }

    Write-Host ("== docker load {0} (WSL) ==" -f $ImageTag) -ForegroundColor Cyan
    $wslTar = ConvertTo-AlfaWindowsCacheWslPath -WinPath $dest
    wsl.exe -d Ubuntu docker load -i $wslTar
    if ($LASTEXITCODE -ne 0) {
        throw "docker load failed (exit $LASTEXITCODE). Is WSL Docker Engine up?"
    }
    wsl.exe -d Ubuntu docker image inspect $ImageTag --format '{{.Id}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "image missing after load: $ImageTag"
    }
    Write-Host ("  Loaded {0}" -f $ImageTag) -ForegroundColor Green
}

Write-Host '== 7B serve: cache root (ALFa models/trainer only; no GPU check) ==' -ForegroundColor Cyan

Write-Host '== 7B serve: Docker preflight on gaming-c ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-docker-engine.sh') -EnvPrefix 'HOST_LABEL=59 '

Write-Host '== 7B serve: hub image alfa-llamacpp-rpc:cuda128 ==' -ForegroundColor Cyan
Invoke-Alfa7bEnsureRpcCuda128Image

if (-not (Test-Path -LiteralPath $EnvPath)) {
    if (-not (Test-Path -LiteralPath $EnvExample)) {
        throw "Missing $EnvExample"
    }
    Copy-Item -LiteralPath $EnvExample -Destination $EnvPath
    Write-Host "Created $EnvPath from example" -ForegroundColor Yellow
}

$envLines = Get-Content -LiteralPath $EnvPath
$envMap = @{}
foreach ($line in $envLines) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $envMap[$Matches[1]] = $Matches[2]
    }
}
$envMap['MAIN_PORT'] = [string]$Port
if ($LoraGguf -ne '') {
    $envMap['LORA_GGUF'] = $LoraGguf
}
# -NoLora: do not persist LORA_GGUF= into .env (would make the next unflagged
# start serve base while the lock example still names v1). Empty LoRA for this
# up comes from the shell (Compose interpolation: shell > --env-file).
# https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/
$newLines = New-Object System.Collections.Generic.List[string]
foreach ($key in @('MAIN_PORT','MODEL_FILE','MODEL_ALIAS','LORA_GGUF','LLAMA_7B_HUB_DIR','LLAMA_7B_MODELS_SUBDIR','LLAMA_7B_LORA_SUBDIR','CUDA_VISIBLE_DEVICES','CTX_SIZE','PARALLEL')) {
    if ($envMap.ContainsKey($key)) {
        [void]$newLines.Add(("{0}={1}" -f $key, $envMap[$key]))
    }
}
Set-Content -LiteralPath $EnvPath -Value $newLines -Encoding ASCII

$loraStatus = '(none)'
if (-not $NoLora) {
    if ($envMap.ContainsKey('LORA_GGUF') -and $envMap['LORA_GGUF'] -ne '') {
        $loraStatus = $envMap['LORA_GGUF']
    }
}
Write-Host "Wrote $EnvPath (port=$Port lora=$loraStatus)" -ForegroundColor Green

$modelFile = if ($envMap.ContainsKey('MODEL_FILE') -and $envMap['MODEL_FILE'] -ne '') {
    $envMap['MODEL_FILE']
} else {
    'Qwen2.5-Coder-7B-Instruct-Q8_0.gguf'
}
$modelsSub = if ($envMap.ContainsKey('LLAMA_7B_MODELS_SUBDIR') -and $envMap['LLAMA_7B_MODELS_SUBDIR'] -ne '') {
    $envMap['LLAMA_7B_MODELS_SUBDIR']
} else {
    'models/qwen25-coder-7b'
}
$hubDirWsl = $null
if (Test-Alfa7bHubModelPresent -HubDirWsl $HubCacheWsl -ModelFile $modelFile -ModelsSubdir $modelsSub) {
    $hubDirWsl = $HubCacheWsl
    Write-Host ("  Hub GGUF OK at {0}" -f $HubCacheWsl) -ForegroundColor Green
}
if (-not $hubDirWsl) {
    Invoke-Alfa7bEnsureNfsHubMount
    if (Test-Alfa7bHubModelPresent -HubDirWsl '/mnt/cluster/llama-cpp' -ModelFile $modelFile -ModelsSubdir $modelsSub) {
        $hubDirWsl = '/mnt/cluster/llama-cpp'
        Write-Host '  Hub GGUF OK at /mnt/cluster/llama-cpp' -ForegroundColor Green
    }
}
if (-not $hubDirWsl) {
    throw @"
Missing base GGUF on gaming-c ($modelFile).
From orchestrator run Start-Alfa7bServe.ps1 (stages hub artifacts via scp when NFS is unavailable).
"@
}
$envMap['LLAMA_7B_HUB_DIR'] = $hubDirWsl
$rewriteLines = New-Object System.Collections.Generic.List[string]
foreach ($key in @('MAIN_PORT','MODEL_FILE','MODEL_ALIAS','LORA_GGUF','LLAMA_7B_HUB_DIR','LLAMA_7B_MODELS_SUBDIR','LLAMA_7B_LORA_SUBDIR','CUDA_VISIBLE_DEVICES','CTX_SIZE','PARALLEL')) {
    if ($envMap.ContainsKey($key)) {
        [void]$rewriteLines.Add(("{0}={1}" -f $key, $envMap[$key]))
    }
}
Set-Content -LiteralPath $EnvPath -Value $rewriteLines -Encoding ASCII

$initScript = Join-Path $Common 'initialize-windows-deploy.ps1'
if (Test-Path -LiteralPath $initScript) {
    . $initScript
    Initialize-AlfaWindowsDockerMirror
}
Assert-AlfaWindowsDockerEngine

Write-Host '== 7B serve: refuse inference RPC shard if running ==' -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dockerNames = ''
try {
    $dockerNames = (wsl.exe -d Ubuntu docker ps --format '{{.Names}}' 2>&1 | Out-String)
} finally {
    $ErrorActionPreference = $prevEap
}
if ($dockerNames -match '(?m)^llamacpp-rpc') {
    throw @"
FAIL: inference RPC container is running on gaming-c (llamacpp-rpc*). Stopping it piecemeal can crash the coordinator.
From orchestrator run Start-Stop-AlfaAi.ps1 stop, then start without opting in gaming-c, then Start-Alfa7bServe.ps1.
"@
}

Write-Host '== 7B serve: GPU must be free before compose up ==' -ForegroundColor Cyan
Invoke-AlfaWslBashScript -ScriptPath (Join-Path $Common 'preflight-gpu-empty.sh') -EnvPrefix 'HOST_LABEL=59 MAX_MIB=3072 '

$pathConv = if (Get-Command ConvertTo-AlfaWslPath -ErrorAction SilentlyContinue) {
    { param($p) ConvertTo-AlfaWslPath -Path $p }
} else {
    { param($p) ConvertTo-Alfa7bWslPath -Path $p }
}
$llcWsl = & $pathConv $Llc
$composeWsl = & $pathConv $ComposeFile
$envWsl = & $pathConv $EnvPath

Write-Host '== 7B serve: docker compose up ==' -ForegroundColor Cyan
if ($NoLora) {
    wsl.exe -d Ubuntu bash -lc "cd '$llcWsl'; LORA_GGUF= docker compose --env-file '$envWsl' -f '$composeWsl' -p alfa-7b-serve up -d --force-recreate llamacpp-7b-serve"
} else {
    wsl.exe -d Ubuntu bash -lc "cd '$llcWsl'; docker compose --env-file '$envWsl' -f '$composeWsl' -p alfa-7b-serve up -d --force-recreate llamacpp-7b-serve"
}
if ($LASTEXITCODE -ne 0) {
    throw "docker compose up failed (exit $LASTEXITCODE)"
}

$wslNetHelper = Join-Path $Common 'install-wsl-nat-portproxy.ps1'
if (Test-Path -LiteralPath $wslNetHelper) {
    . $wslNetHelper
    if (Get-Command Set-AlfaWslNatPortProxy -ErrorAction SilentlyContinue) {
        if (Test-AlfaWslNatPortProxyRequired) {
            Write-Host "== 7B serve: WSL NAT portproxy :$Port ==" -ForegroundColor Cyan
            Set-AlfaWslNatPortProxy -TcpPorts @($Port)
        }
    }
}

Write-Host "== 7B serve: wait /health on :$Port ==" -ForegroundColor Cyan
$waitHelper = Join-Path $Common 'Wait-AlfaHttpPoll.ps1'
if (-not (Test-Path -LiteralPath $waitHelper)) {
    throw "Missing wait helper: $waitHelper"
}
. $waitHelper
$healthOk = Wait-AlfaHttpPoll -Url "http://127.0.0.1:$Port/health" -TimeoutSec 300
if (-not $healthOk) {
    throw "7B llama-server /health not OK on :$Port within 300s"
}

Write-Host "OK: 7B llama-server listening on :$Port" -ForegroundColor Green
