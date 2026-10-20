#Requires -Version 5.1
<#
.SYNOPSIS
  Start 7B QLoRA DDP on train island (gaming-c + gaming-b; gaming-a optional; or gaming-c-only diagnostic).

.DESCRIPTION
  0. Refuse leftover Start/Stop-AlfaTrain7bQlora.ps1 on this orchestrator (Win32_Process CommandLine).
     Start/Stop-AlfaTrain14bQlora.ps1 are gone; preflight still refuses leftover PIDs
     from old 14B sessions that match those script names in CommandLine.
  1. Refuse if alfa-train.lock already exists
  2. Refuse leftover alfa-train-7b* / alfa-train-14b* containers (docker ps -a).
     Orphan llamacpp-rpc-server: auto gaming-stop-for-session.ps1 -NoPause when the
     host is not a live coordinator backend. Still refuse if the host is listed in
     inference-shards.active.env (do not docker-stop a live RPC backend).
  3. Write alfa-train.lock (blocks Pool72/80 and train-GPU opt-in; leftover stop skips gaming-c/gaming-b)
  3b. Refuse if ALFa Models Start/Stop is in flight (alfa-desktop-job.lock)
  4. If /mnt/cluster or /mnt/cluster-ssd is not an NFS mountpoint, remount (WSL -u root)
  4a. If hub log shows preprocess SIGBUS (exit -7) before first loss: one retry with
      docker rm, partial dataset_prepared_path rm, and --dataset-num-proc 4
  4b. git pull --ff-only origin main on trainer clones (C:\alfa-ai-train)
  4c. Build cluster FAQ chat JSONL (OpenAI messages; chat_template mix) and
      stage to hub for qlora_continue.py --extra-jsonl
  5. Launch Axolotl via official Docker image

  Default CLI: nnodes=2 (gaming-c + gaming-b) torchrun + yaml DDP QLoRA.
  DDP is Axolotl default when neither DeepSpeed nor FSDP is selected:
  https://docs.axolotl.ai/docs/multi-gpu.html
  Pass -Include219 for 3-node.
  Pass -SingleHost59 for gaming-c only with --launcher python (same 7B yaml).
  -Include219 and -SingleHost59 cannot be combined.
  inference is not a train rank (inference core stays up).

  Image: axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0
  Official: https://docs.axolotl.ai/docs/installation.html
  Multi-node: https://docs.axolotl.ai/docs/multi-node.html
  CLI: https://docs.axolotl.ai/docs/cli.html
  Allocator: https://docs.pytorch.org/docs/2.14/notes/cuda.html
  docker ps: https://docs.docker.com/reference/cli/docker/container/ps/
  docker load: https://docs.docker.com/reference/cli/docker/image/load/
  Get-CimInstance: https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance?view=powershell-5.1
  Win32_Process CommandLine: https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process

  Hub tarball (load once per host):
    \\hub\docker-images\axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz
    /mnt/cluster/docker-images/axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz

.EXAMPLE
  cd C:/Users/operator\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1 -SingleHost59

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1 -Include219

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1 -FreshAdapter
#>
[CmdletBinding()]
param(
    [string]$TrainRootWin = 'C:\alfa-ai-train',
    [string]$AxolotlImage = 'axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0',
    [switch]$Include219,
    [switch]$SingleHost59,
    [switch]$FreshAdapter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Include219 -and $SingleHost59) {
    throw 'Pass only one of -Include219 or -SingleHost59.'
}

$NNodes = 2
if ($Include219) { $NNodes = 3 }
if ($SingleHost59) { $NNodes = 1 }
$RdzvId = ('alfa-train-pool7b-n{0}' -f $NNodes)

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$LockPath = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-train.lock'
$ActiveShardsPath = Join-Path $RepoDir 'deploy\llamacpp-rpc\inference-shards.active.env'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$Ssh59 = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
$Ssh219 = if ($env:inference_SSH_219_TARGET) { $env:inference_SSH_219_TARGET } else { 'Corey@orchestrator' }
$Ssh249 = if ($env:inference_SSH_249_TARGET) { $env:inference_SSH_249_TARGET } else { 'cody@orchestrator' }

$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
$Key219 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_219'
$Key249 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_249'

$Repo59Win = if ($env:inference_REPO_59_WIN) { $env:inference_REPO_59_WIN } else { 'C:\Users\Colin\alfa-ai' }
$Repo219Win = if ($env:inference_REPO_219_WIN) { $env:inference_REPO_219_WIN } else { 'C:\Users\Corey\alfa-ai' }
$Repo249Win = if ($env:inference_REPO_249_WIN) { $env:inference_REPO_249_WIN } else { 'C:\Users\cody\alfa-ai' }

$RdzvEndpoint = 'orchestrator'
# Always the 7B DDP yaml (no DeepSpeed). Diagnostic is same yaml + --launcher python.
# https://docs.axolotl.ai/docs/multi-gpu.html
# https://docs.axolotl.ai/docs/cli.html
$AxolotlConfig = 'configs/pool-7b-qlora-sft.yaml'
$HubTrain = '/mnt/cluster/training/alfa-train'
# SSD hot HF cache (promote-hf-7b-to-ssd.sh). Not spinning /mnt/cluster/models/huggingface.
$HubHf = '/mnt/cluster-ssd/models/huggingface'
# datasets load_dataset Arrow cache; must not live under read-only SSD HF_HOME/datasets.
# https://huggingface.co/docs/datasets/cache
$HubDatasetsCache = "$HubTrain/cache/datasets"
# One stamp per Start so all ranks write into the same hub log folder.
$TrainLogStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$HubLogDir = "$HubTrain/logs/pool-7b-$TrainLogStamp"

# Set by Invoke-TrainQloraContinueResolve before Get-TrainDockerRunBash (all ranks share flags).
$TrainQloraMode = ''
$TrainLoraModelDir = ''
$TrainDatasetPreparedPath = ''

function ConvertTo-TrainWslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    if ($WinPath -match '^([A-Za-z]):\\?(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/').TrimStart('/')
        return "/mnt/$drive/$rest"
    }
    if ($WinPath -match '^([A-Za-z]):/(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        return "/mnt/$drive/$rest"
    }
    throw "Not a Windows drive path: $WinPath (expected C:\alfa-ai-train on gaming hosts)"
}

function ConvertTo-TrainRemoteBase64 {
    param([Parameter(Mandatory)][string]$BashBody)
    # Avoid nested quote hell (PS -> ssh -> wsl -> bash). Decode + exec on the remote.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BashBody)
    return [Convert]::ToBase64String($bytes)
}

function ConvertTo-TrainSshStdout {
    param($Output)
    # StrictMode: empty docker ps returns AutomationNull; never call .Trim() on that.
    $parts = @()
    if ($null -ne $Output) {
        foreach ($line in @($Output)) {
            if ($null -ne $line) {
                $parts += [string]$line
            }
        }
    }
    return (($parts -join "`n").Trim())
}

function Test-TrainSshKey {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        throw "Missing SSH key for $Label : $KeyPath"
    }
}

function Invoke-TrainGitPull {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label
    )
    # Trainer clone is Windows git (C:\alfa-ai-train). Fast-forward so yaml output_dir
    # matches origin/main (v2 fleet job). Official: https://git-scm.com/docs/git-pull
    $gitRoot = ($TrainRootWin -replace '\\', '/')
    Write-Host ("== git pull --ff-only origin main on {0} ({1}) ==" -f $Label, $gitRoot)
    & ssh -o BatchMode=yes -o ConnectTimeout=60 -i $KeyPath $Target ("git -C {0} pull --ff-only origin main" -f $gitRoot)
    if ($LASTEXITCODE -ne 0) {
        throw ("git pull --ff-only failed on {0} clone {1} (exit {2}). Push alfa-train from orchestrator first." -f $Label, $gitRoot, $LASTEXITCODE)
    }
}

function Invoke-TrainQloraContinueResolve {
    # Resolve continue vs fresh LoRA via alfa-train helper on gaming-c WSL (hub NFS paths).
    # Continue: --lora-model-dir (lora_model_dir) per https://docs.axolotl.ai/docs/lora.html
    # CLI kebab overrides before --launcher: https://docs.axolotl.ai/docs/cli.html
    # config-reference: lora_model_dir, dataset_prepared_path
    # https://docs.axolotl.ai/docs/config-reference.html
    # Do NOT pass --resume-from-checkpoint or enable auto_resume.
    $helperScript = ((ConvertTo-TrainWslPath -WinPath $TrainRootWin).TrimEnd('/') + '/scripts/qlora_continue.py')
    $outputDir = '/mnt/cluster/training/alfa-train/checkpoints/pool-7b-qlora-v2'
    $corpus = '/mnt/cluster/training/alfa-train/datasets/alfa-corpus-train.jsonl'
    $faq = '/mnt/cluster/training/alfa-train/datasets/alfa-7b-cluster-faq-chat.jsonl'
    $freshArg = ''
    if ($FreshAdapter) {
        $freshArg = ' --fresh'
    }
    $resolveBash = @"
set -e
if ! command -v python3 >/dev/null 2>&1; then
  echo 'FAIL: python3 missing in WSL on gaming-c'
  exit 7
fi
if [ ! -f '$helperScript' ]; then
  echo 'FAIL: missing helper script $helperScript (git pull alfa-train on gaming-c?)'
  exit 8
fi
if [ ! -f '$faq' ]; then
  echo 'FAIL: missing hub FAQ $faq (Start should have staged it)'
  exit 9
fi
python3 '$helperScript' --output-dir '$outputDir' --corpus '$corpus' --extra-jsonl '$faq'$freshArg
"@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $resolveBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host '== Resolve QLoRA continue vs fresh (gaming-c WSL qlora_continue.py) =='
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=120 -i $Key59 $Ssh59 $remote
    if ($LASTEXITCODE -ne 0) {
        throw ("qlora_continue.py failed on gaming-c (exit {0}). Fix python3, helper script, or hub paths." -f $LASTEXITCODE)
    }
    $text = ConvertTo-TrainSshStdout -Output $out
    $mode = ''
    $loraDir = ''
    $preparedPath = ''
    foreach ($line in @($text -split "`n")) {
        $trim = ([string]$line).Trim()
        if ($trim.Length -eq 0) { continue }
        if ($trim -match '^MODE=(.+)$') {
            $mode = $Matches[1].Trim()
            continue
        }
        if ($trim -match '^LORA_MODEL_DIR=(.*)$') {
            $loraDir = $Matches[1].Trim()
            continue
        }
        if ($trim -match '^DATASET_PREPARED_PATH=(.+)$') {
            $preparedPath = $Matches[1].Trim()
            continue
        }
    }
    if ([string]::IsNullOrWhiteSpace($mode)) {
        throw 'qlora_continue.py did not emit MODE= (stdout parse failed).'
    }
    if ([string]::IsNullOrWhiteSpace($preparedPath)) {
        throw 'qlora_continue.py did not emit DATASET_PREPARED_PATH= (stdout parse failed).'
    }
    $script:TrainQloraMode = $mode
    $script:TrainDatasetPreparedPath = $preparedPath
    $script:TrainLoraModelDir = ''
    if ($mode -eq 'continue') {
        if ([string]::IsNullOrWhiteSpace($loraDir)) {
            throw 'qlora_continue.py MODE=continue but LORA_MODEL_DIR is empty.'
        }
        $script:TrainLoraModelDir = $loraDir
    }
    if ($mode -eq 'continue' -and -not [string]::IsNullOrWhiteSpace($script:TrainLoraModelDir)) {
        Write-Host ("== QLoRA: CONTINUE from {0} ==" -f $script:TrainLoraModelDir)
    } elseif ($FreshAdapter) {
        Write-Host '== QLoRA: FRESH from-base (new LoRA on frozen 7B) =='
    } else {
        Write-Host '== QLoRA: FRESH no-adapter (no v2 checkpoint yet) =='
    }
    Write-Host ("dataset_prepared_path={0}" -f $script:TrainDatasetPreparedPath)
}

function Invoke-TrainStageClusterFaq {
    # Mix (yaml): completion corpus + this file as type chat_template.
    # https://docs.axolotl.ai/docs/dataset-formats/
    # OpenAI messages rows:
    # https://docs.axolotl.ai/docs/dataset-formats/conversation.html
    # Axolotl weight subsamples only (cannot upsample); --repeats duplicates
    # unique FAQ turns in the builder. Schema:
    # https://github.com/axolotl-ai-cloud/axolotl/blob/main/src/axolotl/utils/schemas/datasets.py
    # Hub copy is consumed by qlora_continue.py --extra-jsonl (cluster hash
    # suffix for dataset_prepared_path; not Axolotl internal cache key).
    $builder = Join-Path $RepoDir 'scripts\build_7b_cluster_faq_chat.py'
    if (-not (Test-Path -LiteralPath $builder)) {
        throw ("Missing FAQ builder: {0}" -f $builder)
    }
    $localOut = Join-Path $env:TEMP 'alfa-7b-cluster-faq-chat.jsonl'
    Write-Host '== Build cluster FAQ chat JSONL =='
    & python $builder --out $localOut --repeats 50 --extra-repeats-gate-fact13 50
    if ($LASTEXITCODE -ne 0) {
        throw ("build_7b_cluster_faq_chat.py failed (exit {0})" -f $LASTEXITCODE)
    }
    if ($Ssh59 -notmatch '^([^@]+)@(.+)$') {
        throw 'Ssh59 must be user@host (example: Colin@orchestrator)'
    }
    $remoteUser = $Matches[1]
    $winStage = ("C:/Users/{0}/AppData/Local/Temp/alfa-7b-cluster-faq-chat.jsonl" -f $remoteUser)
    $wslStage = ("/mnt/c/Users/{0}/AppData/Local/Temp/alfa-7b-cluster-faq-chat.jsonl" -f $remoteUser)
    $hubFaq = '/mnt/cluster/training/alfa-train/datasets/alfa-7b-cluster-faq-chat.jsonl'
    Write-Host '== SCP cluster FAQ to gaming-c =='
    & scp -o BatchMode=yes -o ConnectTimeout=60 -i $Key59 $localOut ("{0}:{1}" -f $Ssh59, $winStage)
    if ($LASTEXITCODE -ne 0) {
        throw ("scp FAQ failed (exit {0})" -f $LASTEXITCODE)
    }
    $copyBash = @"
set -e
if ! mountpoint -q /mnt/cluster; then
  echo 'FAIL: /mnt/cluster is not mounted on gaming-c WSL (NFS from hub hub)'
  exit 2
fi
mkdir -p /mnt/cluster/training/alfa-train/datasets
cp -f '$wslStage' '$hubFaq'
test -s '$hubFaq'
echo OK_FAQ_$hubFaq
"@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $copyBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host '== Hub copy cluster FAQ via gaming-c WSL NFS =='
    & ssh -o BatchMode=yes -o ConnectTimeout=30 -i $Key59 $Ssh59 $remote
    if ($LASTEXITCODE -ne 0) {
        throw ("Hub FAQ copy failed (exit {0})" -f $LASTEXITCODE)
    }
}

function Assert-TrainHubNfsMounted {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label
    )
    # mountpoint(1): https://man7.org/linux/man-pages/man1/mountpoint.1.html
    # mount(8): https://man7.org/linux/man-pages/man8/mount.8.html
    # timeout(1): https://man7.org/linux/man-pages/man1/timeout.1.html
    # WSL --user root: https://learn.microsoft.com/en-us/windows/wsl/basic-commands
    # Without NFS, Docker bind-mounts an empty local /mnt/cluster (WSL disk).
    # WSL restart drops NFS but can leave a non-mountpoint directory; self-heal:
    # lazy umount, then mount hub then storage fallback (CLUSTER_SHARED_STORAGE.md).
    $checkBash = @"
export PATH="/usr/local/sbin:/usr/sbin:/sbin:`$PATH"
alfa_mount_nfs() {
  local dest="`$1" export_path="`$2"
  local srv opt
  mkdir -p "`$dest"
  umount "`$dest" 2>/dev/null || true
  umount -l "`$dest" 2>/dev/null || true
  opt='vers=4.1,noresvport,soft,timeo=50,retrans=2'
  for srv in hub orchestrator; do
    echo "TRY_NFS `${srv}:`${export_path} -> `${dest}"
    if timeout 30 mount -t nfs -o "`$opt" "`${srv}:`${export_path}" "`$dest"; then
      echo "MOUNT_OK `${srv}:`${export_path}"
      return 0
    fi
  done
  echo "FAIL: nfs mount of `${export_path} onto `${dest} (hub and storage)"
  df -h "`$dest" 2>/dev/null || true
  return 1
}
if ! command -v mount.nfs >/dev/null 2>&1; then
  echo 'FAIL: mount.nfs missing. Install nfs-common in this WSL once.'
  exit 7
fi
if mountpoint -q /mnt/cluster; then
  echo ALREADY_MOUNTED_$Label
else
  echo REMOUNTING_$Label
  if ! alfa_mount_nfs /mnt/cluster /mnt/HDDs/Alfa-AI; then
    exit 2
  fi
fi
if ! mountpoint -q /mnt/cluster; then
  echo 'FAIL: /mnt/cluster is not an NFS mountpoint on $Label'
  df -h /mnt/cluster 2>/dev/null || true
  exit 2
fi
if [ ! -f /mnt/cluster/training/alfa-train/datasets/alfa-corpus-train.jsonl ]; then
  echo 'FAIL: missing hub dataset alfa-corpus-train.jsonl under /mnt/cluster/training/alfa-train/datasets'
  exit 3
fi
if mountpoint -q /mnt/cluster-ssd; then
  echo ALREADY_MOUNTED_SSD_$Label
else
  echo REMOUNTING_SSD_$Label
  if ! alfa_mount_nfs /mnt/cluster-ssd /mnt/ssd/Alfa-AI; then
    echo 'hub must export /mnt/ssd/Alfa-AI (not pool root /mnt/ssd). Run promote-hf-7b-to-ssd.sh on hub.'
    exit 8
  fi
fi
if ! mountpoint -q /mnt/cluster-ssd; then
  echo 'FAIL: /mnt/cluster-ssd is not an NFS mountpoint on $Label'
  df -h /mnt/cluster-ssd 2>/dev/null || true
  exit 8
fi
if ! ls /mnt/cluster-ssd/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct/snapshots/*/config.json >/dev/null 2>&1; then
  echo 'FAIL: missing SSD 7B HF snapshot config.json under /mnt/cluster-ssd/models/huggingface/hub'
  echo 'Run sudo bash deploy/cluster-members/hub/promote-hf-7b-to-ssd.sh on hub. Do not load 7B from HDD /mnt/cluster.'
  exit 9
fi
# huggingface_hub writes cache .locks even for a local snapshot
# https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache
# Paths are literal: this is a PowerShell here-string under StrictMode.
mkdir -p /mnt/cluster-ssd/models/huggingface/hub/.locks
if ! touch /mnt/cluster-ssd/models/huggingface/hub/.locks/.alfa-write-test 2>/dev/null; then
  echo 'FAIL: HF hub/.locks is not writable on NFS (Permission denied).'
  echo 'On hub: sudo mkdir -p /mnt/ssd/Alfa-AI/models/huggingface/hub/.locks'
  echo '         sudo chmod a+rwx /mnt/ssd/Alfa-AI/models/huggingface/hub /mnt/ssd/Alfa-AI/models/huggingface/hub/.locks'
  echo 'chmod a+rX is not enough; lock files need other-write on this Maproot share.'
  ls -lad /mnt/cluster-ssd/models/huggingface/hub /mnt/cluster-ssd/models/huggingface/hub/.locks 2>/dev/null || true
  exit 10
fi
rm -f /mnt/cluster-ssd/models/huggingface/hub/.locks/.alfa-write-test
mkdir -p /mnt/cluster/training/alfa-train/cache/datasets
if ! touch /mnt/cluster/training/alfa-train/cache/datasets/.alfa-write-test 2>/dev/null; then
  echo 'FAIL: HF datasets cache is not writable on NFS (Permission denied).'
  echo 'On hub: sudo mkdir -p /mnt/HDDs/Alfa-AI/training/alfa-train/cache/datasets'
  echo '         sudo chmod a+rwx /mnt/HDDs/Alfa-AI/training/alfa-train/cache /mnt/HDDs/Alfa-AI/training/alfa-train/cache/datasets'
  ls -lad /mnt/cluster/training/alfa-train/cache /mnt/cluster/training/alfa-train/cache/datasets 2>/dev/null || true
  exit 11
fi
rm -f /mnt/cluster/training/alfa-train/cache/datasets/.alfa-write-test
echo NFS_OK_$Label
"@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $checkBash
    $remote = "wsl -d Ubuntu -u root -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host ("== Preflight hub NFS on {0} ==" -f $Label)
    & ssh -o BatchMode=yes -o ConnectTimeout=60 -i $KeyPath $Target $remote
    if ($LASTEXITCODE -ne 0) {
        throw ("Hub NFS preflight failed on {0} (exit {1}). Need HDD /mnt/cluster (corpus), SSD /mnt/cluster-ssd (7B HF), writable hub/.locks, and writable training/alfa-train/cache/datasets (HF_DATASETS_CACHE)." -f $Label, $LASTEXITCODE)
    }
}

function Test-TrainCoordinatorUp {
    # Coordinator :31360 only (not shard RPC). Used to decide if active.env is live.
    $ok = $false
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('hub', 31360, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok) {
            $client.EndConnect($iar) | Out-Null
        }
        $client.Close()
    } catch {
        $ok = $false
    }
    return $ok
}

function Assert-TrainHostsNotInActivePool {
    # Only when coordinator is up. Stale active.env after Stop must not block train.
    if (-not (Test-TrainCoordinatorUp)) {
        Write-Host '== Coordinator :31360 down; skip live active.env membership check =='
        return
    }
    if (-not (Test-Path -LiteralPath $ActiveShardsPath)) {
        Write-Host '== Coordinator up but no inference-shards.active.env; GPU check is docker ps =='
        return
    }
    $raw = Get-Content -LiteralPath $ActiveShardsPath
    $needles = New-Object System.Collections.Generic.List[hashtable]
    [void]$needles.Add(@{ Host = 'orchestrator'; Port = '31351'; Label = 'gaming-c' })
    if (-not $SingleHost59) {
        [void]$needles.Add(@{ Host = 'orchestrator'; Port = '31358'; Label = 'gaming-b' })
    }
    if ($Include219) {
        [void]$needles.Add(@{ Host = 'orchestrator'; Port = '31352'; Label = 'gaming-a' })
    }
    foreach ($n in $needles) {
        foreach ($line in $raw) {
            $trim = ([string]$line).Trim()
            if ($trim.StartsWith('#')) { continue }
            if ($trim.Length -eq 0) { continue }
            if ($trim.Contains($n.Host) -and $trim.Contains($n.Port)) {
                throw ("Train GPU in use by inference: {0} is in inference-shards.active.env ({1} {2}). Core 27B can stay up. Full cluster Stop then Start WITHOUT this host opted in. Do not docker-stop the shard. Docs: docs/operations/TRAIN_7B_QLORA_GUI.md" -f $n.Label, $n.Host, $n.Port)
            }
        }
    }
    Write-Host '== Active shard list does not include train hosts =='
}

function Assert-NoLeftoverTrainLaunchers {
    # 14B Start/Stop scripts are removed; still match leftover PIDs from old sessions.
    # Win32_Process CommandLine: https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process
    Write-Host '== Preflight leftover Start/Stop trainer processes on orchestrator =='
    $found = New-Object System.Collections.Generic.List[string]
    $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'"
    foreach ($proc in @($procs)) {
        if ($proc.ProcessId -eq $PID) { continue }
        $cl = $proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cl)) { continue }
        if ($cl -notmatch 'Start-AlfaTrain7bQlora\.ps1|Stop-AlfaTrain7bQlora\.ps1|Start-AlfaTrain14bQlora\.ps1|Stop-AlfaTrain14bQlora\.ps1') { continue }
        [void]$found.Add(('{0}' -f $proc.ProcessId))
    }
    if ($found.Count -gt 0) {
        $ids = ($found -join ',')
        throw ("Leftover trainer launcher still running (PID {0}). From orchestrator: Stop-Process -Id {0} -Force then Stop-AlfaTrain7bQlora.ps1. Do not Start until those PIDs are gone. https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process" -f $ids)
    }
    Write-Host '== No leftover trainer Start/Stop processes =='
}

function Join-TrainRemoteWinPath {
    # Path.Combine: remote drive need not exist on orchestrator (Join-Path Example 5).
    # https://learn.microsoft.com/en-us/dotnet/api/system.io.path.combine
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )
    return [System.IO.Path]::Combine($Parent.TrimEnd(), $Child)
}

function Test-TrainHostInActiveShardFile {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Port
    )
    if (-not (Test-Path -LiteralPath $ActiveShardsPath)) {
        return $false
    }
    foreach ($line in (Get-Content -LiteralPath $ActiveShardsPath)) {
        $trim = ([string]$line).Trim()
        if ($trim.StartsWith('#')) { continue }
        if ($trim.Length -eq 0) { continue }
        if ($trim.Contains($Ip) -and $trim.Contains($Port)) {
            return $true
        }
    }
    return $false
}

function Test-TrainOrphanRpcSafeToStop {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Port
    )
    # Coordinator down: leftover rpc-server cannot be a live --rpc backend.
    # llama-server lists hosts at start: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
    if (-not (Test-TrainCoordinatorUp)) {
        return $true
    }
    # Coordinator up, no membership file: do not guess. llama-server --rpc is
    # set at start: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
    if (-not (Test-Path -LiteralPath $ActiveShardsPath)) {
        return $false
    }
    if (Test-TrainHostInActiveShardFile -Ip $Ip -Port $Port) {
        return $false
    }
    return $true
}

function Invoke-TrainGpuFreeRemoteCheck {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label
    )
    # docker ps -- filter names only. Do not TCP-probe shard RPC ports.
    # alfa-train-14b* is leftover from removed 14B trainer (no live Start script).
    # https://docs.docker.com/reference/cli/docker/container/ps/
    $checkBash = @'
set -e
if ! command -v docker >/dev/null 2>&1; then
  echo FAIL: docker not on PATH
  exit 7
fi
if ! docker info >/dev/null 2>&1; then
  echo FAIL: docker daemon not reachable
  exit 8
fi
leftover14=$(docker ps -a --filter name=alfa-train-14b --format '{{.Names}}')
leftover7=$(docker ps -a --filter name=alfa-train-7b --format '{{.Names}}')
if [ -n "$leftover14" ] || [ -n "$leftover7" ]; then
  echo "FAIL: leftover train container: $leftover14 $leftover7"
  echo 'Run Stop-AlfaTrain7bQlora.ps1 first. Do not docker rm by hand.'
  exit 9
fi
busy=$(docker ps --format '{{.Names}}' | grep -E 'llamacpp-rpc|alfa-llamacpp-rpc' || true)
if [ -n "$busy" ]; then
  echo "RPC_BUSY $busy"
  exit 5
fi
echo GPU_FREE
'@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $checkBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host ("== Preflight GPU free (docker ps) on {0} ==" -f $Label)
    # ssh stdout (GPU_FREE / RPC_BUSY) must not join LASTEXITCODE on the
    # success stream. about_Return: every statement is function output
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_return?view=powershell-5.1
    $sshOut = $null
    $exitCode = 1
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $sshOut = & ssh -o BatchMode=yes -o ConnectTimeout=30 -i $KeyPath $Target $remote 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $text = ConvertTo-TrainSshStdout -Output $sshOut
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-Host $text
    }
    if ($null -eq $exitCode) {
        return 1
    }
    return [int]$exitCode
}

function Invoke-TrainGamingStopOrphanRpc {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$StopScriptWin
    )
    $remote = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -NoPause' -f $StopScriptWin)
    Write-Host ("== Orphan RPC: gaming-stop-for-session.ps1 -NoPause on {0} (no ShutdownWsl) ==" -f $Label)
    & ssh -o BatchMode=yes -o ConnectTimeout=60 -i $KeyPath $Target $remote
    if ($LASTEXITCODE -ne 0) {
        throw ("gaming-stop-for-session.ps1 failed on {0} (exit {1})." -f $Label, $LASTEXITCODE)
    }
}

function Assert-TrainGpuFreeOnHost {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$StopScriptWin
    )
    $code = Invoke-TrainGpuFreeRemoteCheck -KeyPath $KeyPath -Target $Target -Label $Label
    if ($code -eq 9) {
        throw ("Leftover alfa-train-7b or alfa-train-14b container on {0}. Run Stop-AlfaTrain7bQlora.ps1 first. docker ps: https://docs.docker.com/reference/cli/docker/container/ps/" -f $Label)
    }
    if ($code -eq 5) {
        if (-not (Test-TrainOrphanRpcSafeToStop -Ip $Ip -Port $Port)) {
            throw ("Train GPU not free on {0}: live or unknown inference membership. Full cluster Stop then Start WITHOUT this host opted in. Do not docker-stop the shard. Docs: docs/operations/TRAIN_7B_QLORA_GUI.md" -f $Label)
        }
        Invoke-TrainGamingStopOrphanRpc -KeyPath $KeyPath -Target $Target -Label $Label -StopScriptWin $StopScriptWin
        $code = Invoke-TrainGpuFreeRemoteCheck -KeyPath $KeyPath -Target $Target -Label $Label
        if ($code -ne 0) {
            throw ("Train GPU still not free on {0} after orphan RPC stop (exit {1})." -f $Label, $code)
        }
        return
    }
    if ($code -ne 0) {
        throw ("Train GPU not free on {0} (exit {1}). Core 27B can stay up; this host must not be an opted-in shard." -f $Label, $code)
    }
}

function Assert-TrainAxolotlImage {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label
    )
    # Hub tarball first. Official docker load: https://docs.docker.com/reference/cli/docker/image/load/
    $tar = '/mnt/cluster/docker-images/axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz'
    $checkBash = @"
set -e
if docker image inspect '$AxolotlImage' >/dev/null 2>&1; then
  echo IMAGE_OK
  exit 0
fi
if [ ! -f '$tar' ]; then
  echo 'FAIL: missing hub tarball $tar'
  exit 6
fi
echo LOADING_FROM_HUB
docker load -i '$tar'
docker image inspect '$AxolotlImage' >/dev/null
echo IMAGE_LOADED
"@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $checkBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host ("== Preflight Axolotl image on {0} ==" -f $Label)
    & ssh -o BatchMode=yes -o ConnectTimeout=900 -i $KeyPath $Target $remote
    if ($LASTEXITCODE -ne 0) {
        throw ("Axolotl image missing on {0} (exit {1}). Load hub tarball under /mnt/cluster/docker-images/." -f $Label, $LASTEXITCODE)
    }
}

function Write-TrainLockFile {
    $dir = Split-Path -Parent $LockPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    @(
        '# ALFa train lock (gitignored runtime; local to orchestrator)'
        ("STARTED_UTC={0}" -f (Get-Date).ToUniversalTime().ToString('o'))
        'MODE=7b-qlora-docker'
        ("NNODES={0}" -f $NNodes)
        ("INCLUDE_219={0}" -f $(if ($Include219) { '1' } else { '0' }))
        ("SINGLE_HOST_59={0}" -f $(if ($SingleHost59) { '1' } else { '0' }))
        'BASE_MODEL=Qwen/Qwen2.5-Coder-7B-Instruct'
        ("IMAGE={0}" -f $AxolotlImage)
        ("LOGDIR={0}" -f $HubLogDir)
    ) | Set-Content -LiteralPath $LockPath -Encoding ASCII
}

function Test-TrainHubLogPreprocessSigBus {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)\bloss\b|Total train batch') { return $false }
    return ($Text -match 'SIGBUS|Signal 7 \(SIGBUS\)|exitcode:\s*-7|Unexpected bus error|insufficient shared memory \(shm\)')
}

function Invoke-TrainRmContainersOnly {
    $killBash = @'
docker rm -f alfa-train-7b-59 alfa-train-7b-249 alfa-train-7b-219 alfa-train-14b-59 alfa-train-14b-249 alfa-train-14b-219 >/dev/null 2>&1 || true
exit 0
'@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $killBash
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host '== Self-heal: docker rm train containers (lock kept) =='
    & ssh -o BatchMode=yes -o ConnectTimeout=60 -i $Key59 $Ssh59 $remote
    if (-not $SingleHost59) {
        & ssh -o BatchMode=yes -o ConnectTimeout=60 -i $Key249 $Ssh249 $remote
    }
    if ($Include219) {
        & ssh -o BatchMode=yes -o ConnectTimeout=60 -i $Key219 $Ssh219 $remote
    }
}

function Invoke-TrainClearPartialPreparedDataset {
    if ([string]::IsNullOrWhiteSpace($script:TrainDatasetPreparedPath)) {
        Write-Host '== Self-heal: no DATASET_PREPARED_PATH; skip hub rm =='
        return
    }
    $prep = $script:TrainDatasetPreparedPath
    $clearBash = @"
if [ -d '$prep' ]; then
  echo "RM_PARTIAL_PREPARED=$prep"
  rm -rf '$prep'
else
  echo "SKIP_PARTIAL_PREPARED_MISSING=$prep"
fi
"@
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $clearBash
    $remote = "wsl -d Ubuntu -u root -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host ("== Self-heal: clear partial dataset_prepared_path on hub ({0}) ==" -f $prep)
    & ssh -o BatchMode=yes -o ConnectTimeout=120 -i $Key59 $Ssh59 $remote
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Self-heal hub rm failed (exit {0}); retry may still help with lower dataset_num_proc." -f $LASTEXITCODE)
    }
}

function Get-TrainDockerRunBash {
    param(
        [Parameter(Mandatory)][int]$NodeRank,
        [Parameter(Mandatory)][string]$TrainDir,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string]$LocalAddr,
        [string]$GpuDevices = '0',
        [bool]$IsRdzvHost = $false,
        [int]$DatasetNumProc = 0
    )
    # Official Axolotl multi-node torchrun inside the published Blackwell image.
    # --network host so rdzv on :29500 works across LAN (WSL Docker engine / Linux).
    # Image ENTRYPOINT is /workspace/axolotl/scripts/uv-entrypoint.sh
    # (https://docs.axolotl.ai/docs/installation.html) -- do NOT bind-mount over
    # /workspace or the entrypoint disappears. Mount the alfa-train clone beside it.
    # rdzv_endpoint is unquoted host:port (https://docs.pytorch.org/docs/stable/elastic/run.html).
    # is_host: c10d only creates TCPStore when hostname/IP matches the endpoint, or when
    # --rdzv_conf is_host=1 is set. Gaming WSL hostnames often resolve to 127.0.1.1, so
    # the gaming-c head must force is_host=1 (https://docs.pytorch.org/docs/stable/elastic/rendezvous.html).
    # Peer FQDNs are not in LAN DNS; Docker --add-host maps them
    # (https://docs.docker.com/reference/cli/docker/container/run/#add-host).
    # --local-addr: advertise LAN IP instead of getfqdn() for secondary stores
    # (https://docs.pytorch.org/docs/stable/elastic/run.html).
    # --embeddings-skip-upcast before --launcher per https://docs.axolotl.ai/docs/cli.html
    # It is a Click boolean flag pair (--x/--no-x) with NO value: axolotl cli/utils/args.py
    # add_options_from_config. Passing "true" after it sends "true" through allow_extra_args
    # into torchrun as the training script -> "true FAILED" (2026-09-08 log).
    # --no-eval-sample-packing: same Click pair. Packed eval on 12 GB WSL hit
    # CUDA driver error: device not ready in logits.float() (2026-09-11).
    # https://docs.axolotl.ai/docs/config-reference.html
    # --eval-batch-size 1 takes a value (not a boolean pair).
    # https://docs.axolotl.ai/docs/multi-gpu.html
    # Do NOT pass --bf16 full: this image (cu130-2.12.0) pydantic is
    # Literal['auto'] | bool only. pool-14b-20260911T200119Z ValidationError.
    # Mixed-precision page mentions bf16: full but the running schema rejects it.
    # https://docs.axolotl.ai/docs/config-reference.html
    # --eval-strategy=no: string "no" (equals form). Bare "no" is YAML 1.1 bool false
    # and Click can pass False. https://yaml.org/type/bool.html
    # https://docs.axolotl.ai/docs/config-reference.html (eval_strategy: no)
    # Continue LoRA: --lora-model-dir before --launcher (lora.html; not auto_resume).
    # https://docs.axolotl.ai/docs/lora.html
    # https://docs.axolotl.ai/docs/cli.html
    $trainMount = '/workspace/alfa-train'
    $rdzvConf = if ($IsRdzvHost) { 'is_host=1,join_timeout=180' } else { 'is_host=0,join_timeout=180' }
    $logFile = "$HubLogDir/$ContainerName.log"
    $cliPrefix = @(
        'axolotl train'
        $AxolotlConfig
        '--embeddings-skip-upcast'
        '--no-eval-sample-packing'
        '--eval-batch-size 1'
        '--eval-strategy=no'
    )
    if (-not [string]::IsNullOrWhiteSpace($script:TrainLoraModelDir)) {
        $cliPrefix += ("--lora-model-dir {0}" -f $script:TrainLoraModelDir)
    }
    if (-not [string]::IsNullOrWhiteSpace($script:TrainDatasetPreparedPath)) {
        $cliPrefix += ("--dataset-prepared-path {0}" -f $script:TrainDatasetPreparedPath)
    }
    # dataset_num_proc: https://docs.axolotl.ai/docs/config-reference.html
    # Self-heal retry passes 4 after preprocess SIGBUS (yaml default is higher).
    if ($DatasetNumProc -gt 0) {
        $cliPrefix += ("--dataset-num-proc {0}" -f $DatasetNumProc)
    }
    if ($SingleHost59) {
        # Official single-process launch (no torchrun / no DDP wrap).
        # https://docs.axolotl.ai/docs/cli.html
        $trainCmd = ($cliPrefix + '--launcher python') -join ' '
    } else {
        $trainCmd = @(
            $cliPrefix
            '--launcher torchrun --'
            ("--nnodes {0} --nproc_per_node 1 --node_rank {1}" -f $NNodes, $NodeRank)
            "--rdzv_id $RdzvId"
            '--rdzv_backend c10d'
            "--rdzv_endpoint $RdzvEndpoint"
            "--rdzv_conf $rdzvConf"
            ("--local-addr {0}" -f $LocalAddr)
        ) -join ' '
    }
    $bashLc = 'set -o pipefail; mkdir -p "' + $HubLogDir + '"; /workspace/axolotl/scripts/uv-entrypoint.sh ' + $trainCmd + ' 2>&1 | tee "' + $logFile + '"; exit ${PIPESTATUS[0]}'
    # --ipc=host: NCCL / torch shared memory (https://docs.docker.com/engine/reference/run/#ipc-settings---ipc)
    # --shm-size: default Docker /dev/shm is 64m; PyTorch DataLoader workers bus-error after load
    # (2026-09-11 pool-14b-20260911T191138Z). WSL may not honor ipc=host; set shm explicitly.
    # NCCL_SOCKET_IFNAME: Axolotl multi-node Ethernet prefixes (not NCCL debug-section vars).
    # https://docs.axolotl.ai/docs/multi-node.html
    # https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html#nccl-socket-ifname
    # PYTORCH_ALLOC_CONF: official name; PYTORCH_CUDA_ALLOC_CONF is alias.
    # expandable_segments default is False. Pin False so the image cannot enable True
    # (WSL2 reports can mask OOM as CUDA device not ready).
    # https://docs.pytorch.org/docs/2.14/notes/cuda.html
    $run = @(
        "docker run -d --rm --name $ContainerName"
        "--gpus device=$GpuDevices"
        '--network host'
        '--ipc=host'
        '--shm-size=16g'
        '--add-host=QuantumExampleX:orchestrator'
        '--add-host=QuantumExampleX:orchestrator'
        '--add-host=QuantumBladeX.localdomain:orchestrator'
        '--add-host=QuantumBladeX:orchestrator'
        '--add-host=DESKTOP-7EOGC3R.localdomain:orchestrator'
        '--add-host=DESKTOP-7EOGC3R:orchestrator'
        '-e HF_HOME=/data/hf'
        '-e HF_HUB_CACHE=/data/hf/hub'
        ("-e HF_DATASETS_CACHE={0}" -f $HubDatasetsCache)
        '-e HF_HUB_OFFLINE=1'
        '-e NCCL_DEBUG=WARN'
        '-e TORCH_NCCL_ASYNC_ERROR_HANDLING=1'
        '-e NCCL_SOCKET_IFNAME=eth0,en,eth,em,bond'
        '-e PYTORCH_ALLOC_CONF=expandable_segments:False'
        "-v ${TrainDir}:${trainMount}"
        "-v ${HubTrain}:${HubTrain}"
        "-v ${HubHf}:/data/hf"
        "-w $trainMount"
        '--entrypoint /bin/bash'
        $AxolotlImage
        '-lc'
        ("'{0}'" -f ($bashLc -replace "'", "'\''"))
    ) -join ' '
    return ("docker rm -f $ContainerName >/dev/null 2>&1 || true; mkdir -p '$HubLogDir'; $run; echo LOGFILE=$logFile")
}

function Invoke-TrainWindowsWslSsh {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$BashBody,
        [Parameter(Mandatory)][string]$Label
    )
    $b64 = ConvertTo-TrainRemoteBase64 -BashBody $BashBody
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d > /tmp/alfa-train-run.sh; chmod +x /tmp/alfa-train-run.sh; bash /tmp/alfa-train-run.sh'"
    Write-Host ("== SSH {0} (docker run -d) ==" -f $Label)
    Write-Host ("remote: base64 launch script ({0} bytes decoded)" -f $BashBody.Length)
    & ssh -o BatchMode=yes -o ConnectTimeout=30 -i $KeyPath $Target $remote
    if ($LASTEXITCODE -ne 0) {
        throw "SSH failed on $Label (exit $LASTEXITCODE)"
    }
}

function Get-Train59ContainerId {
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $Key59 $Ssh59 'wsl -d Ubuntu docker ps -q -f name=alfa-train-7b-59'
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return ConvertTo-TrainSshStdout -Output $out
}

function Show-Train59DockerLogs {
    param([int]$Tail = 120)
    Write-Host ("== gaming-c docker logs (tail {0}) ==" -f $Tail)
    & ssh -o BatchMode=yes -o ConnectTimeout=30 -i $Key59 $Ssh59 ('wsl -d Ubuntu docker logs --tail ' + $Tail + ' alfa-train-7b-59')
}

function Get-TrainHubRank0LogTail {
    param([int]$Bytes = 16000)
    $log59 = "$HubLogDir/alfa-train-7b-59.log"
    if ($NNodes -gt 1) {
        $log249 = "$HubLogDir/alfa-train-7b-249.log"
        $remote = ("wsl -d Ubuntu -- bash -lc 'echo ===alfa-train-7b-59.log===; if [ -f ""{0}"" ]; then tail -c {2} ""{0}""; else echo LOG_MISSING; fi; echo ===alfa-train-7b-249.log===; if [ -f ""{1}"" ]; then tail -c {2} ""{1}""; else echo LOG_MISSING; fi'" -f $log59, $log249, $Bytes)
    } else {
        $remote = ("wsl -d Ubuntu -- bash -lc 'if [ -f ""{0}"" ]; then tail -c {1} ""{0}""; else echo LOG_MISSING; fi'" -f $log59, $Bytes)
    }
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $Key59 $Ssh59 $remote 2>$null
    return ConvertTo-TrainSshStdout -Output $out
}

function Test-TrainHubLogFailed {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match 'DistNetworkError|DistStoreError|timed out after|ChildFailedError|RendezvousTimeoutError|RendezvousConnectionError|CUDA out of memory|device not ready|CUDA driver error|PermissionError|bus error|SIGBUS|exitcode:\s*-7|insufficient shared memory|Traceback \(most recent call last\)')
}

function Test-TrainHubLogProgress {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # Real train loop only: loss or Total train batch. trainable params / load finish are STARTING.
    return ($Text -match '(?i)\bloss\b|Total train batch')
}

function Wait-TrainHubLogProgress {
    param([int]$TimeoutSec = 600)
    $log59 = "$HubLogDir/alfa-train-7b-59.log"
    $log249 = "$HubLogDir/alfa-train-7b-249.log"
    $watchMsg = 'hub rank-0 log'
    $watchFiles = $log59
    if ($NNodes -gt 1) {
        $watchMsg = 'hub gaming-c or gaming-b train logs'
        $watchFiles = ("{0} or {1}" -f $log59, $log249)
    }
    Write-Host ("== Watching {0} for progress or fail (up to {1}s; no 30min silent wait) ==" -f $watchMsg, $TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $cid = Get-Train59ContainerId
        $tail = Get-TrainHubRank0LogTail
        if (Test-TrainHubLogFailed -Text $tail) {
            Write-Host '== Hub log shows a hard error; dumping tail then abort =='
            Write-Host $tail
            throw ("Train failed in hub log {0}. DistNetworkError/timeout/traceback is not a silent hang -- Stop trainer will run." -f $watchFiles)
        }
        if ([string]::IsNullOrWhiteSpace($cid)) {
            Write-Host '== gaming-c train container exited during startup =='
            Show-Train59DockerLogs
            Write-Host $tail
            throw 'Rank-0 container exited before train progress. See hub log / docker logs above.'
        }
        if (Test-TrainHubLogProgress -Text $tail) {
            Write-Host '== Hub log shows train progress (loss / Total train batch) =='
            return
        }
        Start-Sleep -Seconds 10
    }
    Write-Host '== No train progress in hub log within timeout =='
    Write-Host (Get-TrainHubRank0LogTail)
    throw ("Train wedged: no loss/Total train batch in {0} after {1}s. Check --add-host/--local-addr and Hyper-V LAN TCP (not 29500-only)." -f $watchFiles, $TimeoutSec)
}

function Wait-TrainRdzvPort {
    param(
        [string]$ComputerName = 'orchestrator',
        [int]$Port = 29500,
        [int]$TimeoutSec = 180
    )
    Write-Host ("== Waiting for rdzv TCP {0}:{1} (up to {2}s) ==" -f $ComputerName, $Port, $TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $cid = Get-Train59ContainerId
        if ([string]::IsNullOrWhiteSpace($cid)) {
            Write-Host '== gaming-c container alfa-train-7b-59 is not running =='
            Show-Train59DockerLogs
            throw 'rdzv wait aborted: gaming-c train container exited before TCP 29500 opened. See docker logs above.'
        }
        $ok = $false
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(2000, $false)
            if ($ok) {
                $client.EndConnect($iar) | Out-Null
            }
            $client.Close()
        } catch {
            $ok = $false
        }
        if ($ok) {
            Write-Host ("== rdzv port open: {0}:{1} ==" -f $ComputerName, $Port)
            return
        }
        Start-Sleep -Seconds 3
    }
    Write-Host '== rdzv TCP still closed; dumping gaming-c logs before Stop =='
    Show-Train59DockerLogs
    throw ("rdzv port {0}:{1} not open after {2}s (container still running). On gaming-c Admin PowerShell allow Hyper-V inbound TCP {1} (mirrored WSL): New-NetFirewallHyperVRule -Name AlfaTrainRdzv -DisplayName AlfaTrainRdzv -Direction Inbound -VMCreatorId '{{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}}' -Protocol TCP -LocalPorts {1}  Docs: https://learn.microsoft.com/en-us/windows/wsl/networking" -f $ComputerName, $Port, $TimeoutSec)
}

$jobLockHelper = Join-Path $PSScriptRoot 'AlfaDesktopJobLock.ps1'
if (-not (Test-Path -LiteralPath $jobLockHelper)) {
    throw "Missing $jobLockHelper"
}
. $jobLockHelper

Assert-NoLeftoverTrainLaunchers

$heldDesktopJob = $false
Lock-AlfaDesktopJob -Kind train -Action start -RepoDir $RepoDir
$heldDesktopJob = $true
try {

if (Test-Path -LiteralPath $LockPath) {
    throw "Train lock already set: $LockPath. Run Stop-AlfaTrain7bQlora.ps1 first."
}

Test-TrainSshKey -KeyPath $Key59 -Label 'gaming-c'
if (-not $SingleHost59) {
    Test-TrainSshKey -KeyPath $Key249 -Label 'gaming-b'
}
if ($Include219) {
    Test-TrainSshKey -KeyPath $Key219 -Label 'gaming-a'
}

Write-Host '== Preflight SSH BatchMode (before lock) =='
& ssh -o BatchMode=yes -o ConnectTimeout=20 -i $Key59 $Ssh59 'echo OK59'
if ($LASTEXITCODE -ne 0) { throw "SSH preflight failed for gaming-c ($Ssh59)" }
if (-not $SingleHost59) {
    & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $Key249 $Ssh249 'echo OK249'
    if ($LASTEXITCODE -ne 0) { throw "SSH preflight failed for gaming-b ($Ssh249)" }
}
if ($Include219) {
    & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $Key219 $Ssh219 'echo OK219'
    if ($LASTEXITCODE -ne 0) { throw "SSH preflight failed for gaming-a ($Ssh219)" }
}

Assert-TrainHubNfsMounted -KeyPath $Key59 -Target $Ssh59 -Label 'gaming-c'
if (-not $SingleHost59) {
    Assert-TrainHubNfsMounted -KeyPath $Key249 -Target $Ssh249 -Label 'gaming-b'
}
if ($Include219) {
    Assert-TrainHubNfsMounted -KeyPath $Key219 -Target $Ssh219 -Label 'gaming-a'
}

Assert-TrainHostsNotInActivePool

Invoke-TrainGitPull -KeyPath $Key59 -Target $Ssh59 -Label 'gaming-c'
if (-not $SingleHost59) {
    Invoke-TrainGitPull -KeyPath $Key249 -Target $Ssh249 -Label 'gaming-b'
}
if ($Include219) {
    Invoke-TrainGitPull -KeyPath $Key219 -Target $Ssh219 -Label 'gaming-a'
}

Invoke-TrainStageClusterFaq
Invoke-TrainQloraContinueResolve

Assert-TrainGpuFreeOnHost -KeyPath $Key59 -Target $Ssh59 -Label 'gaming-c' -Ip 'orchestrator' -Port '31351' -StopScriptWin (Join-TrainRemoteWinPath -Parent $Repo59Win -Child 'deploy\cluster-members\gaming-worker-c\gaming-stop-for-session.ps1')
if (-not $SingleHost59) {
    Assert-TrainGpuFreeOnHost -KeyPath $Key249 -Target $Ssh249 -Label 'gaming-b' -Ip 'orchestrator' -Port '31358' -StopScriptWin (Join-TrainRemoteWinPath -Parent $Repo249Win -Child 'deploy\cluster-members\gaming-worker-b\gaming-stop-for-session.ps1')
}
if ($Include219) {
    Assert-TrainGpuFreeOnHost -KeyPath $Key219 -Target $Ssh219 -Label 'gaming-a' -Ip 'orchestrator' -Port '31352' -StopScriptWin (Join-TrainRemoteWinPath -Parent $Repo219Win -Child 'deploy\cluster-members\gaming-worker-a\gaming-stop-for-session.ps1')
}

Assert-TrainAxolotlImage -KeyPath $Key59 -Target $Ssh59 -Label 'gaming-c'
if (-not $SingleHost59) {
    Assert-TrainAxolotlImage -KeyPath $Key249 -Target $Ssh249 -Label 'gaming-b'
}
if ($Include219) {
    Assert-TrainAxolotlImage -KeyPath $Key219 -Target $Ssh219 -Label 'gaming-a'
}

$TrainRootWsl = ConvertTo-TrainWslPath -WinPath $TrainRootWin
$trainSigBusRetried = $false
$trainDatasetNumProc = 0

$include219Text = if ($Include219) { 'yes' } else { 'no' }
$singleText = if ($SingleHost59) { 'yes' } else { 'no' }
Write-Host ("== 7B QLoRA train island nnodes={0} include_219={1} single_host_59={2} (core 27B not stopped) ==" -f $NNodes, $include219Text, $singleText)
Write-Host ("image={0}" -f $AxolotlImage)
Write-Host ("axolotl_config={0}" -f $AxolotlConfig)
Write-Host ("nnodes={0}" -f $NNodes)
Write-Host ("rdzv_id={0}" -f $RdzvId)
Write-Host ("include_219={0}" -f $include219Text)
Write-Host ("single_host_59={0}" -f $singleText)
Write-Host ("train_wsl={0}" -f $TrainRootWsl)
Write-Host ("hub_logs={0}" -f $HubLogDir)

Write-TrainLockFile
Write-Host ("== Lock written: {0} ==" -f $LockPath)

try {
    $launchOk = $false
    while (-not $launchOk) {
        $trainBash59 = Get-TrainDockerRunBash -NodeRank 0 -TrainDir $TrainRootWsl -ContainerName 'alfa-train-7b-59' -LocalAddr 'orchestrator' -GpuDevices '0' -IsRdzvHost:$true -DatasetNumProc $trainDatasetNumProc
        $trainBash249 = $null
        if (-not $SingleHost59) {
            $trainBash249 = Get-TrainDockerRunBash -NodeRank 1 -TrainDir $TrainRootWsl -ContainerName 'alfa-train-7b-249' -LocalAddr 'orchestrator' -GpuDevices '0' -IsRdzvHost:$false -DatasetNumProc $trainDatasetNumProc
        }
        $trainBash219 = $null
        if ($Include219) {
            $trainBash219 = Get-TrainDockerRunBash -NodeRank 2 -TrainDir $TrainRootWsl -ContainerName 'alfa-train-7b-219' -LocalAddr 'orchestrator' -GpuDevices '0' -IsRdzvHost:$false -DatasetNumProc $trainDatasetNumProc
        }
        if ($trainDatasetNumProc -gt 0) {
            Write-Host ("== Launch attempt with --dataset-num-proc {0} (SIGBUS self-heal retry) ==" -f $trainDatasetNumProc)
        }
        try {
            Invoke-TrainWindowsWslSsh -KeyPath $Key59 -Target $Ssh59 -BashBody $trainBash59 -Label 'gaming-c gaming-worker-c (rank 0)'
            Write-Host '== gaming-c docker ps after run -d =='
            & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $Key59 $Ssh59 'wsl -d Ubuntu docker ps -a -f name=alfa-train-7b-59'
            if (-not $SingleHost59) {
                # c10d store listens on rdzv_endpoint (gaming-c). Start that host first, then workers.
                # https://docs.pytorch.org/docs/stable/elastic/run.html
                Wait-TrainRdzvPort -ComputerName 'orchestrator' -Port 29500 -TimeoutSec 180
                Invoke-TrainWindowsWslSsh -KeyPath $Key249 -Target $Ssh249 -BashBody $trainBash249 -Label 'gaming-b gaming-worker-b (rank 1)'
                if ($Include219) {
                    Invoke-TrainWindowsWslSsh -KeyPath $Key219 -Target $Ssh219 -BashBody $trainBash219 -Label 'gaming-a gaming-worker-a (rank 2)'
                }
            }

            Wait-TrainHubLogProgress -TimeoutSec 600
            $launchOk = $true
        } catch {
            $healTail = Get-TrainHubRank0LogTail -Bytes 32000
            if ((-not $trainSigBusRetried) -and (Test-TrainHubLogPreprocessSigBus -Text $healTail)) {
                $trainSigBusRetried = $true
                Write-Host '== Self-heal: preprocess SIGBUS before first loss; one retry with lower dataset_num_proc =='
                Write-Host $healTail
                Invoke-TrainRmContainersOnly
                Invoke-TrainClearPartialPreparedDataset
                $trainDatasetNumProc = 4
                continue
            }
            throw
        }
    }

    Write-Host '== Sample gaming-c docker logs (train continues detached; Stop trainer to end) =='
    & ssh -o BatchMode=yes -o ConnectTimeout=30 -i $Key59 $Ssh59 "wsl -d Ubuntu -- docker logs --tail 40 alfa-train-7b-59"
} catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    Write-Host '== Launch failed; running Stop trainer to clear containers/lock =='
    $stopScript = Join-Path $PSScriptRoot 'Stop-AlfaTrain7bQlora.ps1'
    if (Test-Path -LiteralPath $stopScript) {
        $env:ALFA_DESKTOP_JOB_NEST = '1'
        try {
            & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $stopScript
        } finally {
            Remove-Item Env:\ALFA_DESKTOP_JOB_NEST -ErrorAction SilentlyContinue
        }
    } elseif (Test-Path -LiteralPath $LockPath) {
        Remove-Item -LiteralPath $LockPath -Force
        Write-Host ("== Lock removed: {0} ==" -f $LockPath)
    }
    throw
}

Write-Host '== Launcher finished (containers keep running). Lock until Stop-AlfaTrain7bQlora.ps1. Metrics: TensorBoard at http://127.0.0.1:6006/ =='
$tbScript = Join-Path $PSScriptRoot 'Start-AlfaTrainTensorBoard.ps1'
if (Test-Path -LiteralPath $tbScript) {
    try {
        & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $tbScript -NoBrowser -SkipIfHealthy
    }
    catch {
        Write-Warning ("TensorBoard sidecar/tunnel setup failed (training continues): {0}" -f $_.Exception.Message)
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("TensorBoard sidecar/tunnel setup exited {0} (training continues)." -f $LASTEXITCODE)
    }
}
} finally {
    if ($heldDesktopJob) {
        Unlock-AlfaDesktopJob -RepoDir $RepoDir
    }
}
