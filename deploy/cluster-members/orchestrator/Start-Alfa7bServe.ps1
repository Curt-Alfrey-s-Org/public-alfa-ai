#Requires -Version 5.1
<#
.SYNOPSIS
    Start standalone 7B llama-server on gaming-c and write alfa-7b-serve.lock on orchestrator.
    Full start needs an idle GPU on gaming-c; use -StageOnly for disk-only staging while gaming.
.DESCRIPTION
    Refuses when train lock is set or 7B serve lock already exists.
    Refuses when inference RPC shard is running on gaming-c (use full Start-Stop without gaming-c opt-in).
    See docs/operations/ALFA_7B_SERVE_ALONGSIDE_27B.md
.PARAMETER Port
    Host port for llama-server (default 8470).
.PARAMETER NoLora
    Serve base model only (eval base). Mutually exclusive with -LoraGguf.
.PARAMETER LoraGguf
    LoRA GGUF filename under hub lora dir (e.g. pool-7b-qlora-v2.gguf).
    Empty uses remote .env / example default (pool-7b-qlora-v1.gguf).
.PARAMETER StageOnly
    Stage GGUF and RPC tarball to gaming-c G:\alfa-ai-cache only. No GPU preflight,
    no docker compose, no serve lock. Safe while gaming on gaming-c.
.EXAMPLE
    cd C:/Users/operator\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Alfa7bServe.ps1
.EXAMPLE
    # Eval base then v2 adapter (sequential; stop between runs):
    .\Start-Alfa7bServe.ps1 -NoLora
    .\Stop-Alfa7bServe.ps1
    .\Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf
.EXAMPLE
    # Stage hub files while GPU is busy (e.g. BG3 on gaming-c); start serve later:
    .\Start-Alfa7bServe.ps1 -StageOnly
#>
[CmdletBinding()]
param(
    [int]$Port = 8470,
    [switch]$NoLora,
    [string]$LoraGguf = '',
    [switch]$StageOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($NoLora -and $LoraGguf -ne '') {
    throw 'Cannot use -NoLora and -LoraGguf together.'
}

$CommonDir = Join-Path $PSScriptRoot '..\_common'
. (Join-Path $CommonDir 'Get-AlfaWindowsCacheRoot.ps1')
$LocalCacheRoot = Get-AlfaWindowsCacheRoot

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$TrainLock = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-train.lock'
$ServeLock = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-7b-serve.lock'
$EnvExample = Join-Path $RepoDir 'deploy\llamacpp-rpc\.env.7b-serve.example'
$Deploy59 = Join-Path $RepoDir 'deploy\cluster-members\gaming-worker-c\deploy-7b-llama-server.ps1'

$Ssh59 = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
$Repo59Win = if ($env:ALFA_REPO_59_WIN) { $env:ALFA_REPO_59_WIN } else { 'C:\alfa-ai-worker' }
# Remote cache on gaming-c (scripts stay under C:\alfa-ai-worker). Never stage 7B GGUF on C:.
# Official picker: Get-AlfaWindowsCacheRoot.ps1. Remote override ALFA_59_CACHE_WIN.
$Cache59Win = if ($env:ALFA_59_CACHE_WIN) { $env:ALFA_59_CACHE_WIN } else { 'G:\alfa-ai-cache' }
if ($Cache59Win -match '^[Cc]:\\') {
    throw "ALFA_59_CACHE_WIN must not be on C: (gaming-c C: is full). Use G:\alfa-ai-cache."
}

if (-not $StageOnly) {
    if (Test-Path -LiteralPath $TrainLock) {
        throw "Start blocked: train lock present ($TrainLock). Stop trainer first."
    }
    if (Test-Path -LiteralPath $ServeLock) {
        throw "Start blocked: 7B serve lock already present ($ServeLock). Run Stop-Alfa7bServe.ps1 first."
    }
}
if (-not (Test-Path -LiteralPath $Key59)) {
    throw "Missing SSH key: $Key59"
}
if (-not $StageOnly -and -not (Test-Path -LiteralPath $Deploy59)) {
    throw "Missing deploy script: $Deploy59"
}

function Invoke-Alfa7bEnsureHubGgufOn59 {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$SshKey,
        [Parameter(Mandatory)][string]$RemoteCacheWin,
        [string]$LoraGgufName = ''
    )
    $BaseGguf = 'Qwen2.5-Coder-7B-Instruct-Q8_0.gguf'
    $RemoteHubRoot = Join-AlfaRemoteWinPath -Parent $RemoteCacheWin -Child '7b-hub'
    $RemoteBaseDir = Join-AlfaRemoteWinPath -Parent $RemoteHubRoot -Child 'models\qwen25-coder-7b'
    $RemoteBasePath = Join-AlfaRemoteWinPath -Parent $RemoteBaseDir -Child $BaseGguf
    $LocalHubRoot = Join-Path $LocalCacheRoot '7b-hub'
    $LocalBasePath = Join-Path $LocalHubRoot "models\qwen25-coder-7b\$BaseGguf"
    if (-not (Test-Path -LiteralPath $LocalBasePath)) {
        $legacy93 = Join-Path 'C:\alfa-ai-cache\7b-hub' "models\qwen25-coder-7b\$BaseGguf"
        if (Test-Path -LiteralPath $legacy93) {
            $LocalBasePath = $legacy93
            $LocalHubRoot = 'C:\alfa-ai-cache\7b-hub'
        }
    }
    $Hub111Base = "operator@hub:/mnt/HDDs/Alfa-AI/llama-cpp/models/qwen25-coder-7b/$BaseGguf"
    $Key111 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_111'

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $remoteBaseOk = (ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "Test-Path -LiteralPath '$RemoteBasePath'" 2>$null)
    $ErrorActionPreference = $prevEap
    if ($remoteBaseOk -match 'True') {
        Write-Host ("  gaming-c base GGUF OK: {0}" -f $RemoteBasePath) -ForegroundColor DarkGray
    } else {
        if (-not (Test-Path -LiteralPath $LocalBasePath)) {
            if (-not (Test-Path -LiteralPath $Key111)) {
                throw "Missing $BaseGguf on gaming-c and no hub scp key at $Key111"
            }
            if (-not (Test-Path -LiteralPath (Split-Path -Parent $LocalBasePath))) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $LocalBasePath) -Force | Out-Null
            }
            Write-Host '== SCP base GGUF hub -> orchestrator cache (one-time) ==' -ForegroundColor Cyan
            & scp.exe -i $Key111 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $Hub111Base $LocalBasePath
            if ($LASTEXITCODE -ne 0) {
                throw "scp base GGUF from hub failed (exit $LASTEXITCODE)"
            }
        }
        ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "New-Item -ItemType Directory -Force -Path '$RemoteBaseDir' | Out-Null"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to mkdir $RemoteBaseDir on gaming-c (exit $LASTEXITCODE)"
        }
        Write-Host ("== SCP base GGUF orchestrator -> gaming-c ({0} MB) ==" -f [int]((Get-Item -LiteralPath $LocalBasePath).Length / 1MB)) -ForegroundColor Cyan
        $remoteScpPath = ($RemoteBasePath -replace '\\', '/')
        & scp.exe -i $SshKey -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $LocalBasePath "${SshTarget}:$remoteScpPath"
        if ($LASTEXITCODE -ne 0) {
            throw "scp base GGUF to gaming-c failed (exit $LASTEXITCODE)"
        }
        Write-Host '  Base GGUF staged on gaming-c' -ForegroundColor Green
    }

    if ($LoraGgufName -eq '') {
        return
    }
    $RemoteLoraDir = Join-AlfaRemoteWinPath -Parent $RemoteHubRoot -Child 'lora\qwen25-coder-7b'
    $RemoteLoraPath = Join-AlfaRemoteWinPath -Parent $RemoteLoraDir -Child $LoraGgufName
    $LocalLoraPath = Join-Path $LocalHubRoot "lora\qwen25-coder-7b\$LoraGgufName"
    $Hub111Lora = "operator@hub:/mnt/HDDs/Alfa-AI/llama-cpp/lora/qwen25-coder-7b/$LoraGgufName"

    # Always restage named LoRA. Hub convert reuses the same filename; skip-if-exists
    # would keep a stale GGUF on gaming-c. OpenSSH scp overwrites the dest file:
    # https://man.openbsd.org/scp
    if (Test-Path -LiteralPath $Key111) {
        if (-not (Test-Path -LiteralPath (Split-Path -Parent $LocalLoraPath))) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $LocalLoraPath) -Force | Out-Null
        }
        Write-Host ("== SCP LoRA hub -> orchestrator cache ({0}; overwrite) ==" -f $LoraGgufName) -ForegroundColor Cyan
        & scp.exe -i $Key111 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $Hub111Lora $LocalLoraPath
        if ($LASTEXITCODE -ne 0) {
            throw "scp LoRA from hub failed (exit $LASTEXITCODE)"
        }
    } elseif (-not (Test-Path -LiteralPath $LocalLoraPath)) {
        throw "Missing LoRA $LoraGgufName locally and no hub scp key"
    } else {
        Write-Host ("  No hub key; restaging LoRA from orchestrator cache {0}" -f $LocalLoraPath) -ForegroundColor Yellow
    }
    ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "New-Item -ItemType Directory -Force -Path '$RemoteLoraDir' | Out-Null"
    $remoteLoraScp = ($RemoteLoraPath -replace '\\', '/')
    Write-Host ("== SCP LoRA orchestrator -> gaming-c ({0}; overwrite) ==" -f $LoraGgufName) -ForegroundColor Cyan
    & scp.exe -i $SshKey -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $LocalLoraPath "${SshTarget}:$remoteLoraScp"
    if ($LASTEXITCODE -ne 0) {
        throw "scp LoRA to gaming-c failed (exit $LASTEXITCODE)"
    }
    Write-Host '  LoRA GGUF restaged on gaming-c' -ForegroundColor Green
}

function Invoke-Alfa7bEnsureRpcTarballOn59 {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$SshKey,
        [Parameter(Mandatory)][string]$RemoteCacheWin
    )
    $Tarball = 'alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
    $RemoteDirWin = Join-AlfaRemoteWinPath -Parent $RemoteCacheWin -Child 'docker-images'
    $RemoteTarWin = Join-AlfaRemoteWinPath -Parent $RemoteDirWin -Child $Tarball
    $LocalDockerCache = Join-Path $LocalCacheRoot 'docker-images'
    $LocalTar = Join-Path $LocalDockerCache $Tarball

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $remoteImageOk = (ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "wsl -d Ubuntu docker image inspect alfa-llamacpp-rpc:cuda128 2>`$null; if (`$LASTEXITCODE -eq 0) { 'HAVE' }" 2>$null)
    $remoteOut = (ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "Test-Path -LiteralPath '$RemoteTarWin'" 2>$null)
    $ErrorActionPreference = $prevEap
    if ($remoteImageOk -match 'HAVE') {
        Write-Host '  gaming-c WSL docker image alfa-llamacpp-rpc:cuda128 OK (skip tarball scp)' -ForegroundColor DarkGray
        return
    }
    if ($remoteOut -match 'True') {
        Write-Host ("  gaming-c tarball OK: {0}" -f ($RemoteTarWin -replace '\\', '/')) -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $LocalTar)) {
        $hubRoots = @(
            $LocalDockerCache,
            '\\hub\docker-images',
            '\\hub\docker-images'
        )
        foreach ($root in $hubRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            $cand = Join-Path $root $Tarball
            if (Test-Path -LiteralPath $cand) {
                if (-not (Test-Path -LiteralPath (Split-Path -Parent $LocalTar))) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $LocalTar) -Force | Out-Null
                }
                Write-Host ("  Promoting tarball from {0} to orchestrator cache" -f $cand) -ForegroundColor Cyan
                Copy-Item -LiteralPath $cand -Destination $LocalTar -Force
                break
            }
        }
    }
    if (-not (Test-Path -LiteralPath $LocalTar)) {
        $scpKey111 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_111'
        if (Test-Path -LiteralPath $scpKey111) {
            if (-not (Test-Path -LiteralPath (Split-Path -Parent $LocalTar))) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $LocalTar) -Force | Out-Null
            }
            Write-Host '  Promoting RPC tarball from hub to orchestrator cache (one-time)' -ForegroundColor Cyan
            & scp.exe -i $scpKey111 -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
                -- "operator@hub:/mnt/HDDs/Alfa-AI/docker-images/$Tarball" $LocalTar
            if ($LASTEXITCODE -ne 0) {
                throw "scp from hub failed (exit $LASTEXITCODE). Cannot stage RPC image for gaming-c."
            }
        }
    }
    if (-not (Test-Path -LiteralPath $LocalTar)) {
        throw "Missing $Tarball on orchestrator. Need hub copy or scp from hub before 7B serve."
    }

    Write-Host ("== SCP RPC tarball orchestrator -> gaming-c ({0} MB) ==" -f [int]((Get-Item -LiteralPath $LocalTar).Length / 1MB)) -ForegroundColor Cyan
    ssh -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "New-Item -ItemType Directory -Force -Path '$RemoteDirWin' | Out-Null"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to mkdir $RemoteDirWin on gaming-c (exit $LASTEXITCODE)"
    }
    $remoteTarScp = ($RemoteTarWin -replace '\\', '/')
    & scp.exe -i $SshKey -o BatchMode=yes -o StrictHostKeyChecking=accept-new -- $LocalTar "${SshTarget}:$remoteTarScp"
    if ($LASTEXITCODE -ne 0) {
        throw "scp tarball to gaming-c failed (exit $LASTEXITCODE)"
    }
    Write-Host '  Tarball staged on gaming-c' -ForegroundColor Green
}

function Get-Alfa7bAdapterLockName {
    param(
        [bool]$UseNoLora,
        [string]$UseLoraGguf
    )
    if ($UseNoLora) {
        return '(none)'
    }
    if ($UseLoraGguf -ne '') {
        return $UseLoraGguf
    }
    if (Test-Path -LiteralPath $EnvExample) {
        foreach ($line in Get-Content -LiteralPath $EnvExample) {
            if ($line -match '^\s*LORA_GGUF=(.*)$') {
                $val = $Matches[1].Trim()
                if ($val -ne '') {
                    return $val
                }
                return '(none)'
            }
        }
    }
    return 'pool-7b-qlora-v1.gguf'
}

Write-Host '== 7B: stage hub artifacts to gaming-c (no GPU required) ==' -ForegroundColor Cyan
Invoke-Alfa7bEnsureRpcTarballOn59 -SshTarget $Ssh59 -SshKey $Key59 -RemoteCacheWin $Cache59Win
$stageLora = ''
if (-not $NoLora) {
    if ($LoraGguf -ne '') {
        $stageLora = $LoraGguf
    } else {
        $stageLora = Get-Alfa7bAdapterLockName -UseNoLora $false -UseLoraGguf ''
    }
}
Invoke-Alfa7bEnsureHubGgufOn59 -SshTarget $Ssh59 -SshKey $Key59 -RemoteCacheWin $Cache59Win -LoraGgufName $stageLora

if ($StageOnly) {
    Write-Host ("OK: 7B artifacts staged on gaming-c under {0} (StageOnly; no GPU check or compose)" -f $Cache59Win) -ForegroundColor Green
    exit 0
}

$remoteArgs = @("-Port $Port")
if ($NoLora) {
    $remoteArgs += '-NoLora'
}
if ($LoraGguf -ne '') {
    $remoteArgs += "-LoraGguf `"$LoraGguf`""
}
$remoteCmd = "`$env:ALFA_WINDOWS_CACHE_ROOT='$Cache59Win'; `$env:ALFA_59_CACHE_WIN='$Cache59Win'; powershell -NoProfile -ExecutionPolicy Bypass -File `"$Repo59Win\deploy\cluster-members\gaming-worker-c\deploy-7b-llama-server.ps1`" $($remoteArgs -join ' ')"

Write-Host "== SSH gaming-c: deploy 7B llama-server :$Port (GPU preflight on remote) ==" -ForegroundColor Cyan
ssh -i $Key59 -o BatchMode=yes -o ConnectTimeout=15 $Ssh59 $remoteCmd
if ($LASTEXITCODE -ne 0) {
    throw "Remote deploy on gaming-c failed (exit $LASTEXITCODE)"
}

$adapterName = Get-Alfa7bAdapterLockName -UseNoLora $NoLora -UseLoraGguf $LoraGguf
$lockDir = Split-Path -Parent $ServeLock
if (-not (Test-Path -LiteralPath $lockDir)) {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
}
@(
    '# ALFa 7B serve lock (gitignored runtime; local to orchestrator)'
    ("STARTED_UTC={0}" -f (Get-Date).ToUniversalTime().ToString('o'))
    'MODE=7b-llama-server'
    'HOST=orchestrator'
    ("PORT={0}" -f $Port)
    ("ADAPTER={0}" -f $adapterName)
) | Set-Content -LiteralPath $ServeLock -Encoding ASCII

Write-Host "OK: 7B serve lock written ($ServeLock)" -ForegroundColor Green
Write-Host 'Eval: live FAQ Yes/No on :8470 first. Do not set LLAMACPP_7B_URL unless the operator asks after that chat.' -ForegroundColor DarkGray
