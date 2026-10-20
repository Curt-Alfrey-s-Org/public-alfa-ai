#Requires -Version 5.1
<#
.SYNOPSIS
  Start or stop the four-rank .45b torchrun job. Does not run unless -MaxSteps or -Stop is passed.

.DESCRIPTION
  Called by train-45b-desktop-menu.ps1. Rank 0 is local WSL on orchestrator.
  Ranks 1 and 2 SSH to gaming-c and gaming-b. Rank 3 SSH to inference and selects the 3060.
  torchrun: https://docs.pytorch.org/docs/2.14/elastic/run.html
  CUDA_VISIBLE_DEVICES: https://docs.pytorch.org/docs/2.14/notes/cuda.html
#>
[CmdletBinding()]
param(
    [int]$MaxSteps = 0,
    [int]$BatchSize = 1,
    [int]$Seed = 1,
    [int]$LogEvery = 10,
    [int]$CheckpointEvery = 100,
    [ValidateSet('adamw', 'muon')]
    [string]$Optimizer = 'adamw',
    [double]$LearningRate = 0.0003,
    [double]$Beta1 = 0.9,
    [double]$Beta2 = 0.95,
    [double]$WeightDecay = 0.1,
    [double]$MuonLr = 0.02,
    [double]$MuonMomentum = 0.95,
    [double]$MuonWeightDecay = 0.1,
    [int]$DesktopReserveGb = 3,
    [int]$HeadlessReserveGb = 0,
    [int]$Upsample = 2,
    [int]$RetentionPatience = 3,
    [string]$ReplayFrom = '',
    [switch]$NoCompile,
    [switch]$ActivationCheckpoint,
    [switch]$Resume,
    [switch]$Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Master = 'orchestrator'
$Stamp = '/mnt/training/alfa-train/datasets/from-scratch/20261003T011725Z'
$Tok = '/mnt/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct/snapshots/c03e6d358207e414f1eca0bb1891e29f1db0e242/tokenizer.json'
$CkptHub = '/mnt/training/alfa-train/checkpoints/from-scratch'
$VenvBin = '/root/alfa-torch-cu130/bin'
$LogPath = Join-Path $env:TEMP 'alfa-45b-gui.log'

$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
$Key249 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_249'
$Key148 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_148'

function Write-Alfa45bLog {
    param([string]$Line)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f $stamp, $Line) -Encoding ASCII
}

function ConvertTo-Alfa45bBash64 {
    param([string]$Body)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Body))
}

function Format-Alfa45bNum {
    param($Value)
    return ([double]$Value).ToString('G9', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-Alfa45bTrainBody {
    param(
        [int]$Rank,
        [int]$Steps,
        [int]$ReserveGb,
        [string]$Repo,
        [string]$DataDir,
        [string]$Tokenizer,
        [string]$Checkpoint,
        [string]$CudaDevices,
        [string]$ResumePath
    )
    $lines = @('set -e')
    if (-not [string]::IsNullOrWhiteSpace($CudaDevices)) {
        $lines += ("export CUDA_VISIBLE_DEVICES={0}" -f $CudaDevices)
    }
    $lines += ("export PATH='{0}':`$PATH" -f $VenvBin)
    $lines += ("cd '{0}'" -f $Repo)
    $lines += ("if [ ! -x '{0}/torchrun' ]; then echo FAIL missing torchrun; exit 6; fi" -f $VenvBin)
    $train = ("exec '{0}/torchrun' --nnodes=4 --nproc_per_node=1 --node_rank={1} --rdzv_id alfa45b --rdzv_endpoint={2} --rdzv_backend c10d '{3}/train/from-scratch/train.py' --max-steps {4} --batch-size {5} --seed {6} --log-every {7} --checkpoint-every {8} --desktop-reserve-gb {9} --data-dir '{10}' --tokenizer-json '{11}' --checkpoint-dir '{12}' --optimizer {13} --lr {14} --beta1 {15} --beta2 {16} --weight-decay {17} --muon-lr {18} --muon-momentum {19} --muon-weight-decay {20} --upsample {21} --retention-patience {22}" -f $VenvBin, $Rank, $Master, $Repo, $Steps, $BatchSize, $Seed, $LogEvery, $CheckpointEvery, $ReserveGb, $DataDir, $Tokenizer, $Checkpoint, $Optimizer, (Format-Alfa45bNum $LearningRate), (Format-Alfa45bNum $Beta1), (Format-Alfa45bNum $Beta2), (Format-Alfa45bNum $WeightDecay), (Format-Alfa45bNum $MuonLr), (Format-Alfa45bNum $MuonMomentum), (Format-Alfa45bNum $MuonWeightDecay), $Upsample, $RetentionPatience)
    if ($NoCompile) { $train = $train + ' --no-compile' }
    if ($ActivationCheckpoint) { $train = $train + ' --activation-checkpoint' }
    if (-not [string]::IsNullOrWhiteSpace($ReplayFrom)) {
        $train = $train + (" --replay-from '{0}'" -f $ReplayFrom)
    }
    if (-not [string]::IsNullOrWhiteSpace($ResumePath)) {
        $train = $train + (" --resume '{0}'" -f $ResumePath)
    }
    $lines += $train
    return ($lines -join "`n")
}

function Get-Alfa45bStopBody {
    $lines = @(
        'set -e',
        "if pgrep -f 'rdzv_id alfa45b' >/dev/null 2>&1; then pkill -f 'rdzv_id alfa45b'; fi",
        "if pgrep -f 'train/from-scratch/train.py' >/dev/null 2>&1; then pkill -f 'train/from-scratch/train.py'; fi",
        'echo STOP_OK'
    )
    return ($lines -join "`n")
}

function Write-Alfa45bCmdFile {
    param([string]$Path, [string]$Line)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, ("@echo off`r`n" + $Line + "`r`n"), $utf8)
}

function Start-Alfa45bCmd {
    param([string]$CmdPath, [string]$Label)
    # cmd.exe /c runs the file. CreateNoWindow requires UseShellExecute false.
    # https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = ('/d /c "{0}"' -f $CmdPath)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:TEMP
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    Write-Alfa45bLog ("spawn {0}" -f $Label)
}

function Start-Alfa45bLoggedBash {
    param(
        [string]$BashBody,
        [string]$Label,
        [string]$SshTarget,
        [string]$KeyPath,
        [switch]$UseWsl
    )
    $marked = ("echo '--- {0} ---'{1}{2}" -f $Label, "`n", $BashBody)
    $b64 = ConvertTo-Alfa45bBash64 -Body $marked
    $inner = "echo $b64 | base64 -d | bash"
    $safe = ($Label -replace '[^A-Za-z0-9]', '-')
    $cmdPath = Join-Path $env:TEMP ("alfa-45b-" + $safe + ".cmd")
    if ([string]::IsNullOrWhiteSpace($SshTarget)) {
        $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
        # cmd keeps a quote inside a quoted string when it is doubled.
        $line = ('{0} -d Ubuntu -u root -- bash -lc ""{1}"" >> {2} 2>&1' -f $wsl, $inner, $LogPath)
    } else {
        $ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
        $keyArg = ''
        if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
            $keyArg = ('-i {0} ' -f $KeyPath)
        }
        if ($UseWsl) {
            $remote = ('wsl -d Ubuntu -u root -- bash -lc ""{0}""' -f $inner)
        } else {
            $remote = ('bash -lc ""{0}""' -f $inner)
        }
        $line = ('{0} -o BatchMode=yes -o ConnectTimeout=20 {1}{2} "{3}" >> {4} 2>&1' -f $ssh, $keyArg, $SshTarget, $remote, $LogPath)
    }
    Write-Alfa45bCmdFile -Path $cmdPath -Line $line
    Start-Alfa45bCmd -CmdPath $cmdPath -Label $Label
}

if (-not $Stop -and $MaxSteps -lt 1) {
    throw '-MaxSteps is required unless -Stop is set.'
}

if (-not (Test-Path -LiteralPath $Key59)) { throw "Missing SSH key $Key59" }
if (-not (Test-Path -LiteralPath $Key249)) { throw "Missing SSH key $Key249" }

$use148Key = Test-Path -LiteralPath $Key148
$stepsToRun = $MaxSteps
$resumeHub = ''
$resume249 = ''
$resume148 = ''
if ((-not $Stop) -and $Resume) {
    $wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $latest = & $wslExe -d Ubuntu -u root -- bash -lc "ls -1 /mnt/training/alfa-train/checkpoints/from-scratch/step-*.pt 2>/dev/null | sort | tail -n 1"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latest)) {
        throw 'No step checkpoint under /mnt/training/alfa-train/checkpoints/from-scratch.'
    }
    $lines = @($latest -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match 'step-\d+\.pt$' })
    if ($lines.Count -lt 1) {
        throw 'No step checkpoint under /mnt/training/alfa-train/checkpoints/from-scratch.'
    }
    $resumeHub = $lines[$lines.Count - 1]
    $slash = $resumeHub.LastIndexOf('/')
    if ($slash -lt 0) {
        throw ("Checkpoint path has no file name: {0}" -f $resumeHub)
    }
    $leaf = $resumeHub.Substring($slash + 1).Trim()
    if ($leaf -notmatch '^step-(\d+)\.pt$') {
        throw ("Checkpoint name is not step-NNNNNNNN.pt: {0}" -f $leaf)
    }
    $savedStep = [int]$Matches[1]
    $stepsToRun = $MaxSteps - $savedStep
    if ($stepsToRun -lt 1) {
        throw ("Checkpoint step {0} is already at Max steps {1}." -f $savedStep, $MaxSteps)
    }
    $resume148 = ('/mnt/cluster/training/alfa-train/checkpoints/from-scratch/{0}' -f $leaf)
    $resume249 = ('/mnt/c/Users/Cody/alfa-train-45b-checkpoints/{0}' -f $leaf)
    $winPath = (& $wslExe -d Ubuntu -u root -- wslpath -w $resumeHub)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($winPath)) {
        throw 'wslpath could not map the checkpoint onto a Windows path.'
    }
    $winPath = $winPath.Trim()
    $sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    $scpExe = Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe'
    & $sshExe -o BatchMode=yes -o ConnectTimeout=20 -i $Key249 cody@orchestrator 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path C:\Users\Cody\alfa-train-45b-checkpoints"'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the rank 2 checkpoint folder on gaming-b.'
    }
    & $scpExe -o BatchMode=yes -o ConnectTimeout=20 -i $Key249 $winPath ("cody@orchestrator:alfa-train-45b-checkpoints/{0}" -f $leaf)
    if ($LASTEXITCODE -ne 0) {
        throw 'Copy of the checkpoint to gaming-b failed.'
    }
    Write-Alfa45bLog ("resume step {0} remaining {1} file {2}" -f $savedStep, $stepsToRun, $leaf)
}
$rank0 = Get-Alfa45bTrainBody -Rank 0 -Steps $stepsToRun -ReserveGb $DesktopReserveGb -Repo '/mnt/c/Users/operator/alfa-ai' -DataDir $Stamp -Tokenizer $Tok -Checkpoint $CkptHub -CudaDevices '' -ResumePath $resumeHub
$rank1 = Get-Alfa45bTrainBody -Rank 1 -Steps $stepsToRun -ReserveGb $DesktopReserveGb -Repo '/mnt/c/Users/Colin/alfa-ai' -DataDir $Stamp -Tokenizer $Tok -Checkpoint $CkptHub -CudaDevices '' -ResumePath $resumeHub
$rank2 = Get-Alfa45bTrainBody -Rank 2 -Steps $stepsToRun -ReserveGb $DesktopReserveGb -Repo '/mnt/c/Users/Cody/alfa-ai' -DataDir '/mnt/c/Users/Cody/alfa-train-45b-stamp' -Tokenizer '/mnt/c/Users/Cody/alfa-train-45b-tokenizer.json' -Checkpoint '/mnt/c/Users/Cody/alfa-train-45b-checkpoints' -CudaDevices '' -ResumePath $resume249
$rank3 = Get-Alfa45bTrainBody -Rank 3 -Steps $stepsToRun -ReserveGb $HeadlessReserveGb -Repo '/home/operator/alfa-ai' -DataDir '/mnt/cluster/training/alfa-train/datasets/from-scratch/20261003T011725Z' -Tokenizer '/mnt/cluster/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct/snapshots/c03e6d358207e414f1eca0bb1891e29f1db0e242/tokenizer.json' -Checkpoint '/mnt/cluster/training/alfa-train/checkpoints/from-scratch' -CudaDevices '1' -ResumePath $resume148
# Rank 3 venv is not /root. Rewrite the venv bin in that body.
$rank3 = $rank3.Replace('/root/alfa-torch-cu130/bin', '/home/operator/alfa-torch-cu130/bin')

if ($Stop) {
    $stopBody = Get-Alfa45bStopBody
    Write-Alfa45bLog 'stop requested'
    Start-Alfa45bLoggedBash -BashBody $stopBody -Label 'local stop'
    Start-Alfa45bLoggedBash -BashBody $stopBody -Label 'gaming-c stop' -SshTarget 'Colin@orchestrator' -KeyPath $Key59 -UseWsl
    Start-Alfa45bLoggedBash -BashBody $stopBody -Label 'gaming-b stop' -SshTarget 'cody@orchestrator' -KeyPath $Key249 -UseWsl
    $key148arg = ''
    if ($use148Key) { $key148arg = $Key148 }
    Start-Alfa45bLoggedBash -BashBody $stopBody -Label 'inference stop' -SshTarget 'operator@orchestrator' -KeyPath $key148arg
    Write-Alfa45bLog 'stop spawned'
    exit 0
}

Write-Alfa45bLog ("start max-steps {0}" -f $MaxSteps)
Start-Alfa45bLoggedBash -BashBody $rank1 -Label 'gaming-c rank 1' -SshTarget 'Colin@orchestrator' -KeyPath $Key59 -UseWsl
Start-Alfa45bLoggedBash -BashBody $rank2 -Label 'gaming-b rank 2' -SshTarget 'cody@orchestrator' -KeyPath $Key249 -UseWsl
$key148arg = ''
if ($use148Key) { $key148arg = $Key148 }
Start-Alfa45bLoggedBash -BashBody $rank3 -Label 'inference rank 3' -SshTarget 'operator@orchestrator' -KeyPath $key148arg
Start-Alfa45bLoggedBash -BashBody $rank0 -Label 'local rank 0'
Write-Alfa45bLog 'start spawned'
exit 0
