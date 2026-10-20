#Requires -Version 5.1
<#
.SYNOPSIS
  TensorBoard sidecar + SSH tunnel for 7B QLoRA metrics on orchestrator loopback :6006.

.DESCRIPTION
  Always-on metrics sidecar on gaming-c (survives Stop trainer). Hub job dir
  pool-7b-qlora-v2 is mounted at /tb. TensorBoard --logdir is /tb/runs
  (Axolotl output_dir/runs). Walking the parent /tb tree (adapter weights)
  delayed /data/plugins_listing so the chrome showed Data could not be loaded.
  This script:
  1. Remounts hub NFS on gaming-c if needed (WSL -u root)
  2. Starts or refreshes TensorBoard Docker sidecar alfa-train-tb (--restart unless-stopped)
  3. Waits for HTTP inside gaming-c WSL (curl) before opening the SSH tunnel
  4. Opens SSH local forward 127.0.0.1:6006 on orchestrator -> gaming-c Windows loopback (recreates if HTTP dead)
  5. Optionally launches the default browser

  Official:
  - Axolotl TensorBoard: https://docs.axolotl.ai/docs/training_stability.html
  - TensorBoard recursive logdir: https://github.com/tensorflow/tensorboard/blob/master/README.md
  - --reload_interval: https://github.com/tensorflow/tensorboard/blob/master/tensorboard/plugins/core/core_plugin.py
  - UI Reload data (gear, not auto since 2.3): https://github.com/tensorflow/tensorboard/blob/master/README.md
  - --load_fast=false: https://github.com/tensorflow/tensorboard/issues/4784
  - Docker -p bind 127.0.0.1: https://docs.docker.com/reference/cli/docker/container/run/#publish
  - WSL mirrored localhost (tunnel target on gaming-c): https://learn.microsoft.com/en-us/windows/wsl/networking
  - curl health in WSL: https://curl.se/docs/manpage.html
  - OpenSSH -L: https://man.openbsd.org/ssh

.EXAMPLE
  cd C:/Users/operator\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrainTensorBoard.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrainTensorBoard.ps1 -NoBrowser -SkipIfHealthy
#>
[CmdletBinding()]
param(
    [int]$Port = 6006,
    [string]$HubCheckpointDir = '/mnt/cluster/training/alfa-train/checkpoints/pool-7b-qlora-v2',
    [string]$AxolotlImage = 'axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0',
    [string]$TbContainerName = 'alfa-train-tb',
    [switch]$NoBrowser,
    [switch]$SkipIfHealthy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Ssh59 = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
$SshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$TbUrl = "http://127.0.0.1:${Port}/"

function Get-AlfaTrainTensorBoardBrowserUrl {
    param([int]$ListenPort)
    # Edge reuses an existing tab for the same URL, so a stuck
    # "Data could not be loaded" chrome never reloads. Unique query forces
    # a new navigation. Health checks still use $TbUrl (no query).
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return "http://127.0.0.1:${ListenPort}/?v=${stamp}#scalars"
}

function Test-AlfaTrainTensorBoardPortListening {
    param([int]$ListenPort)
    $conn = Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' -or $_.LocalAddress -eq '0.0.0.0' } |
        Select-Object -First 1
    return ($null -ne $conn)
}

function Test-AlfaTrainTensorBoardHttpHealthy {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 5
    )
    try {
        $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Method Get
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-AlfaTrainTbRemoteBase64 {
    param([Parameter(Mandatory)][string]$BashBody)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BashBody)
    return [Convert]::ToBase64String($bytes)
}

function Invoke-AlfaTrainTensorBoardRemote {
    param(
        [Parameter(Mandatory)][string]$BashBody,
        [switch]$AsRoot
    )
    $b64 = ConvertTo-AlfaTrainTbRemoteBase64 -BashBody $BashBody
    $connectTimeout = 30
    if ($AsRoot) {
        $remote = "wsl -d Ubuntu -u root -- bash -lc 'echo $b64 | base64 -d | bash'"
        $connectTimeout = 60
    }
    else {
        $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    }
    & $SshExe -o BatchMode=yes -o ConnectTimeout=$connectTimeout -i $Key59 $Ssh59 $remote
    if ($LASTEXITCODE -ne 0) {
        throw "SSH TensorBoard setup failed on gaming-c (exit $LASTEXITCODE)"
    }
}

function Test-AlfaTrainTensorBoardRemoteHttpHealthy {
    param([int]$ListenPort = 6006)
    # curl in gaming-c WSL hits Docker -p 127.0.0.1:6006 inside WSL before SSH tunnel.
    # Poll /data/plugins_listing (the official UI data handshake), not GET /.
    # GET / returns HTML while the multiplexer is still walking logdir; the
    # chrome then shows "Data could not be loaded".
    # https://github.com/tensorflow/tensorboard/issues/4844
    # Silent poll: TensorBoard often RST (curl 56) until event files load.
    # Do not use curl -S: stderr through ssh becomes a PS 5.1 ErrorRecord when
    # $ErrorActionPreference is Stop (script default).
    # https://curl.se/docs/manpage.html
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables
    # https://learn.microsoft.com/en-us/powershell/scripting/learn/shell/running-commands
    $checkBash = @"
if ! command -v curl >/dev/null 2>&1; then
  echo 'FAIL: curl missing in gaming-c WSL; install curl (apt install curl)'
  exit 2
fi
curl -4 -sf --max-time 10 -o /dev/null http://127.0.0.1:${ListenPort}/data/plugins_listing >/dev/null 2>&1
"@
    $b64 = ConvertTo-AlfaTrainTbRemoteBase64 -BashBody $checkBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $SshExe -o BatchMode=yes -o ConnectTimeout=30 -i $Key59 $Ssh59 $remote | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Wait-AlfaTrainTensorBoardRemoteHttp {
    param(
        [int]$ListenPort = 6006,
        [int]$TimeoutSec = 120
    )
    Write-Host '== Wait for TensorBoard HTTP inside gaming-c WSL (before SSH tunnel) =='
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-AlfaTrainTensorBoardRemoteHttpHealthy -ListenPort $ListenPort) {
            Write-Host '== TensorBoard HTTP OK inside gaming-c WSL =='
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host '== TensorBoard sidecar last logs (HTTP still not ready) =='
    Show-AlfaTrainTensorBoardRemoteLogs
    throw "TensorBoard HTTP check failed inside gaming-c WSL after ${TimeoutSec}s (curl http://127.0.0.1:${ListenPort}/data/plugins_listing)"
}

function Show-AlfaTrainTensorBoardRemoteLogs {
    $logsBash = @"
docker ps -a --filter name=^/${TbContainerName}$ --format '{{.Names}} {{.Status}}' || true
docker logs --tail 80 ${TbContainerName} 2>&1 || true
"@
    $b64 = ConvertTo-AlfaTrainTbRemoteBase64 -BashBody $logsBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $SshExe -o BatchMode=yes -o ConnectTimeout=30 -i $Key59 $Ssh59 $remote
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Test-AlfaTrainTensorBoardRemoteContainerUp {
    # Healthy only if running with current flags. /tb is pool-7b-qlora-v2 mount.
    # --logdir=/tb/runs matches Axolotl (output_dir/runs). Walking /tb (adapter
    # weights) delays /data/plugins_listing so the chrome shows Data could not
    # be loaded. Stale: --logdir=/tb without /runs.
    # docker inspect: https://docs.docker.com/reference/cli/docker/inspect/
    # Axolotl: https://docs.axolotl.ai/docs/training_stability.html
    $checkBash = @"
if ! docker ps --filter name=^/${TbContainerName}$ --filter status=running --format '{{.Names}}' | grep -q .; then
  echo TB_CONTAINER_DOWN
  exit 0
fi
tbargs=`$(docker inspect -f '{{json .Args}} {{json .Config.Cmd}}' ${TbContainerName} 2>/dev/null || true)
echo TB_ARGS:`$tbargs
case "`$tbargs" in
  *'"--logdir=/tb/runs"'*)
    ;;
  *)
    echo TB_CONTAINER_STALE
    exit 0
    ;;
esac
case "`$tbargs" in
  *'"--reload_interval=5"'*)
    ;;
  *)
    echo TB_CONTAINER_STALE
    exit 0
    ;;
esac
case "`$tbargs" in
  *'"--load_fast=false"'*)
    ;;
  *)
    echo TB_CONTAINER_STALE
    exit 0
    ;;
esac
case "`$tbargs" in
  *'"--detect_file_replacement=true"'*)
    ;;
  *)
    echo TB_CONTAINER_STALE
    exit 0
    ;;
esac
case "`$tbargs" in
  *'"--reload_multifile=true"'*)
    ;;
  *)
    echo TB_CONTAINER_STALE
    exit 0
    ;;
esac
src=`$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' ${TbContainerName} 2>/dev/null || true)
echo TB_MOUNTS:`$src
case "`$src" in
  *pool-7b-qlora-v2*)
    ;;
  *)
    echo TB_CONTAINER_STALE
    exit 0
    ;;
esac
echo TB_CONTAINER_UP
"@
    $b64 = ConvertTo-AlfaTrainTbRemoteBase64 -BashBody $checkBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $SshExe -o BatchMode=yes -o ConnectTimeout=30 -i $Key59 $Ssh59 $remote
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        $text = ($out | Out-String)
        return ($text -match 'TB_CONTAINER_UP')
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Stop-AlfaTrainTensorBoardSshTunnel {
    param([int]$ListenPort)
    $fwdNeedle = "127.0.0.1:${ListenPort}:127.0.0.1:${ListenPort}"
    $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'"
    foreach ($proc in @($procs)) {
        $cl = $proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cl)) { continue }
        if ($cl -notmatch '\-L') { continue }
        if ($cl -notlike "*${fwdNeedle}*") { continue }
        Write-Host ("Stopping stale TensorBoard SSH tunnel (PID {0})" -f $proc.ProcessId)
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-AlfaTrainTensorBoardSshTunnel {
    param([int]$ListenPort)
    Write-Host ("== SSH tunnel 127.0.0.1:{0} -> gaming-c:{0} ==" -f $ListenPort)
    $tunnelArgs = @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15',
        '-o', 'ExitOnForwardFailure=yes',
        '-N',
        '-L', "127.0.0.1:${ListenPort}:127.0.0.1:${ListenPort}",
        '-i', $Key59,
        $Ssh59
    )
    Start-Process -FilePath $SshExe -ArgumentList $tunnelArgs -WindowStyle Hidden | Out-Null
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-AlfaTrainTensorBoardPortListening -ListenPort $ListenPort) {
            break
        }
        Start-Sleep -Milliseconds 400
    }
    if (-not (Test-AlfaTrainTensorBoardPortListening -ListenPort $ListenPort)) {
        throw "TensorBoard tunnel did not open on 127.0.0.1:${ListenPort} within 15s"
    }
}

function Ensure-AlfaTrainTensorBoardSshTunnel {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$ListenPort
    )
    if (Test-AlfaTrainTensorBoardPortListening -ListenPort $ListenPort) {
        if (Test-AlfaTrainTensorBoardHttpHealthy -Url $Url) {
            Write-Host '== TensorBoard SSH tunnel healthy =='
            return
        }
        Write-Host '== Port :6006 listens but HTTP failed; recreating SSH tunnel =='
        Stop-AlfaTrainTensorBoardSshTunnel -ListenPort $ListenPort
        Start-Sleep -Milliseconds 500
    }
    Start-AlfaTrainTensorBoardSshTunnel -ListenPort $ListenPort
    $httpDeadline = [datetime]::UtcNow.AddSeconds(60)
    while ([datetime]::UtcNow -lt $httpDeadline) {
        if (Test-AlfaTrainTensorBoardHttpHealthy -Url $Url) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "TensorBoard HTTP check failed at $Url after tunnel open (60s)"
}

if (-not (Test-Path -LiteralPath $Key59)) {
    throw "Missing SSH key: $Key59 (run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).)"
}

$remountTbBash = @"
export PATH="/usr/local/sbin:/usr/sbin:/sbin:`$PATH"
if mountpoint -q /mnt/cluster; then
  echo ALREADY_MOUNTED_gaming-c
else
  echo REMOUNTING_gaming-c
  mkdir -p /mnt/cluster
  if ! command -v mount.nfs >/dev/null 2>&1; then
    echo 'FAIL: mount.nfs missing. Install nfs-common in this WSL once.'
    exit 7
  fi
  if ! timeout 30 mount -t nfs -o vers=4.1,noresvport,soft,timeo=50,retrans=2 hub:/mnt/HDDs/Alfa-AI /mnt/cluster; then
    echo 'FAIL: nfs mount of hub:/mnt/HDDs/Alfa-AI onto /mnt/cluster'
    df -h /mnt/cluster 2>/dev/null || true
    exit 2
  fi
fi
if ! mountpoint -q /mnt/cluster; then
  echo 'FAIL: /mnt/cluster is not an NFS mountpoint on gaming-c'
  df -h /mnt/cluster 2>/dev/null || true
  exit 2
fi
echo NFS_OK_gaming-c
"@

$startTbBash = @"
set -e
if ! mountpoint -q /mnt/cluster; then
  echo 'FAIL: /mnt/cluster is not an NFS mountpoint on gaming-c WSL after remount'
  df -h /mnt/cluster 2>/dev/null || true
  exit 2
fi
mkdir -p '${HubCheckpointDir}'
docker rm -f ${TbContainerName} >/dev/null 2>&1 || true
docker run -d --restart unless-stopped --name ${TbContainerName} \
  -p 127.0.0.1:${Port}:${Port} \
  -v ${HubCheckpointDir}:/tb:ro \
  --entrypoint tensorboard \
  ${AxolotlImage} \
  --logdir=/tb/runs --host=0.0.0.0 --port=${Port} \
  --load_fast=false --reload_interval=5 \
  --detect_file_replacement=true --reload_multifile=true
echo TB_STARTED
"@

$skipSidecarStart = $false
if ($SkipIfHealthy) {
    $containerUp = Test-AlfaTrainTensorBoardRemoteContainerUp
    $remoteHttpOk = Test-AlfaTrainTensorBoardRemoteHttpHealthy -ListenPort $Port
    $localHttpOk = Test-AlfaTrainTensorBoardHttpHealthy -Url $TbUrl
    if ($containerUp -and $remoteHttpOk -and $localHttpOk) {
        Write-Host ("TensorBoard already healthy at {0}" -f $TbUrl)
        Write-Host 'Enable Reload data in the TensorBoard gear menu to refresh curves (UI does not auto-reload since TB 2.3).' -ForegroundColor DarkGray
        if (-not $NoBrowser) {
            $openUrl = Get-AlfaTrainTensorBoardBrowserUrl -ListenPort $Port
            Write-Host ("Opening {0}" -f $openUrl)
            Start-Process $openUrl
        }
        Write-Host 'TensorBoard ready. Metrics: train/loss, train/learning_rate, eval/loss (after logging_steps).' -ForegroundColor Green
        return
    }
    if ($containerUp -and $remoteHttpOk -and -not $localHttpOk) {
        Write-Host '== TensorBoard sidecar HTTP OK on gaming-c WSL; fixing SSH tunnel only =='
        $skipSidecarStart = $true
    }
}

if (-not $skipSidecarStart) {
    Write-Host '== Preflight hub NFS on gaming-c =='
    Invoke-AlfaTrainTensorBoardRemote -BashBody $remountTbBash -AsRoot
    Write-Host '== Start TensorBoard sidecar on gaming-c (pool-7b-qlora-v2 at /tb) =='
    Invoke-AlfaTrainTensorBoardRemote -BashBody $startTbBash
    Wait-AlfaTrainTensorBoardRemoteHttp -ListenPort $Port -TimeoutSec 120
}

Ensure-AlfaTrainTensorBoardSshTunnel -Url $TbUrl -ListenPort $Port

if (-not $NoBrowser) {
    $openUrl = Get-AlfaTrainTensorBoardBrowserUrl -ListenPort $Port
    Write-Host ("Opening {0}" -f $openUrl)
    Start-Process $openUrl
}

Write-Host ("TensorBoard at {0} (gear: enable Reload data for live curves)." -f $TbUrl) -ForegroundColor Green
Write-Host 'TensorBoard ready. Metrics: train/loss, train/learning_rate, eval/loss (after logging_steps).' -ForegroundColor Green
