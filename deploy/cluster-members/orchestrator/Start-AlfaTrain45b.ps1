#Requires -Version 5.1
<#
.SYNOPSIS
  Operator launcher for .45b from-scratch distributed training (preflight by default).

.DESCRIPTION
  Operator runs this locally on each Windows train host. Do not run from an agent.
  Default is preflight only. Pass -Start to launch torchrun in WSL (training).

  Rank map:
    0  orchestrator WSL, desktop reserve 3 GiB, CUDA device is the 3060
    1  gaming-c WSL, desktop reserve 3 GiB, RTX 5070
    2  gaming-b WSL, desktop reserve 3 GiB, RTX 5070
    3  inference native Linux, desktop reserve 0 GiB, CUDA_VISIBLE_DEVICES must select the 3060 not the 5060

  Rank 3 is not this script. Use a native Linux launcher on inference.

  torchrun: https://docs.pytorch.org/docs/2.14/elastic/run.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(0, 1, 2, 3)]
    [int]$Rank,

    [string]$MasterAddr = 'orchestrator',

    [int]$MasterPort = 29500,

    [Parameter(Mandatory = $true)]
    [string]$DataDir,

    [Parameter(Mandatory = $true)]
    [string]$TokenizerJson,

    [Parameter(Mandatory = $true)]
    [string]$CheckpointDir,

    [Parameter(Mandatory = $true)]
    [int]$DesktopReserveGb,

    [int]$MaxSteps = 0,

    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Alfa45bWslPath {
    param([Parameter(Mandatory = $true)][string]$WinPath)
    if ([string]::IsNullOrWhiteSpace($WinPath)) {
        throw 'Empty path cannot be translated for WSL.'
    }
    $normalized = $WinPath.Trim()
    if ($normalized -match '^/') {
        return ($normalized -replace '\\', '/').TrimEnd('/')
    }
    if ($normalized -match '^\\\\') {
        throw 'Pass a drive-letter path WSL can read (C:\... becomes /mnt/c/...). This script does not map UNC to /mnt/cluster. NFS from WSL on orchestrator and gaming-c timed out, and gaming-b cannot DrvFs-mount \\hub.'
    }
    if ($normalized -match '^([A-Za-z]):\\?(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/').TrimStart('/')
        return "/mnt/$drive/$rest"
    }
    if ($normalized -match '^([A-Za-z]):/(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        return "/mnt/$drive/$rest"
    }
    throw "Cannot translate path for WSL: $WinPath"
}

function Write-Alfa45bRankMap {
    Write-Host '== .45b train rank map =='
    Write-Host '  rank 0: orchestrator WSL, desktop reserve 3 GiB, CUDA device is the 3060'
    Write-Host '  rank 1: gaming-c WSL, desktop reserve 3 GiB, RTX 5070'
    Write-Host '  rank 2: gaming-b WSL, desktop reserve 3 GiB, RTX 5070'
    Write-Host '  rank 3: inference native Linux, desktop reserve 0 GiB, CUDA_VISIBLE_DEVICES must select the 3060 not the 5060'
}

$Alfa45bVenvPython = '/root/alfa-torch-cu130/bin/python'

function Test-Alfa45bWslPython3 {
    & wsl -d Ubuntu -u root -e bash -lc 'test -x /root/alfa-torch-cu130/bin/python'
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'WSL venv python is missing at /root/alfa-torch-cu130/bin/python. This script does not pip-install.'
        exit 1
    }
}

function Invoke-Alfa45bPreflight {
    param(
        [string]$RepoWsl,
        [string]$DataDirWsl,
        [string]$CheckpointDirWsl,
        [string]$TokenizerJsonWsl,
        [int]$ReserveGb
    )
    $preflight = "$RepoWsl/train/from-scratch/preflight.py"
    $pyArgs = @(
        $preflight
        '--data-dir'
        $DataDirWsl
        '--checkpoint-dir'
        $CheckpointDirWsl
        '--desktop-reserve-gb'
        [string]$ReserveGb
        '--tokenizer-json'
        $TokenizerJsonWsl
        '--distributed'
    )
    Write-Host '== Preflight (train/from-scratch/preflight.py) =='
    & wsl -d Ubuntu -u root -e $Alfa45bVenvPython @pyArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("preflight.py failed (exit {0}). Fix paths, GPU, or hub mount before -Start." -f $LASTEXITCODE)
        exit 1
    }
}

function Invoke-Alfa45bTorchrun {
    param(
        [string]$RepoWsl,
        [int]$NodeRank,
        [string]$RdzvEndpoint,
        [int]$Steps,
        [int]$ReserveGb,
        [string]$DataDirWsl,
        [string]$TokenizerJsonWsl,
        [string]$CheckpointDirWsl
    )
    $venvBin = '/root/alfa-torch-cu130/bin'
    $trainPy = "$RepoWsl/train/from-scratch/train.py"
    $bashBody = @(
        'set -e'
        ('export PATH="{0}:$PATH"' -f $venvBin)
        ("cd '{0}'" -f $RepoWsl)
        ('if [ ! -x "{0}/torchrun" ]; then' -f $venvBin)
        ('  echo "FAIL: missing {0}/torchrun (hub venv on this host?)"' -f $venvBin)
        '  exit 6'
        'fi'
        ('exec torchrun --nnodes=4 --nproc_per_node=1 --node_rank={0} \' -f $NodeRank)
        ('  --rdzv_id alfa45b --rdzv_endpoint={0} --rdzv_backend c10d \' -f $RdzvEndpoint)
        ("  '{0}' \\" -f $trainPy)
        ('  --max-steps {0} \' -f $Steps)
        ('  --desktop-reserve-gb {0} \' -f $ReserveGb)
        ("  --data-dir '{0}' \\" -f $DataDirWsl)
        ("  --tokenizer-json '{0}' \\" -f $TokenizerJsonWsl)
        ("  --checkpoint-dir '{0}' \\" -f $CheckpointDirWsl)
        '  --optimizer adamw'
    ) -join "`n"
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bashBody))
    Write-Host '== Launch torchrun in WSL (foreground) =='
    Write-Host ("nnodes=4 node_rank={0} rdzv_endpoint={1} rdzv_id=alfa45b" -f $NodeRank, $RdzvEndpoint)
    & wsl -d Ubuntu -u root -- bash -lc ("echo {0} | base64 -d | bash" -f $b64)
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("torchrun exited {0}" -f $LASTEXITCODE)
        exit 1
    }
}

Write-Alfa45bRankMap

if ($Rank -eq 3) {
    throw 'Rank 3 runs on inference native Linux with CUDA_VISIBLE_DEVICES selecting the 3060. Do not run Start-AlfaTrain45b.ps1 for rank 3.'
}

if ($Start) {
    if ($MaxSteps -lt 1) {
        throw '-Start requires -MaxSteps (positive integer).'
    }
    if ($Rank -in 0, 1, 2) {
        if ($DesktopReserveGb -ne 3) {
            throw ('-Start on rank {0} requires -DesktopReserveGb 3 (Win11 desktop reserve).' -f $Rank)
        }
    }
}

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$RepoWsl = ConvertTo-Alfa45bWslPath -WinPath $RepoDir
$DataDirWsl = ConvertTo-Alfa45bWslPath -WinPath $DataDir
$TokenizerJsonWsl = ConvertTo-Alfa45bWslPath -WinPath $TokenizerJson
$CheckpointDirWsl = ConvertTo-Alfa45bWslPath -WinPath $CheckpointDir
$RdzvEndpoint = ('{0}:{1}' -f $MasterAddr, $MasterPort)

Write-Host ("== This host rank {0} (local launcher; no SSH) ==" -f $Rank)
Write-Host ("repo_wsl={0}" -f $RepoWsl)
Write-Host ("data_dir_wsl={0}" -f $DataDirWsl)
Write-Host ("checkpoint_dir_wsl={0}" -f $CheckpointDirWsl)

Test-Alfa45bWslPython3

Invoke-Alfa45bPreflight `
    -RepoWsl $RepoWsl `
    -DataDirWsl $DataDirWsl `
    -CheckpointDirWsl $CheckpointDirWsl `
    -TokenizerJsonWsl $TokenizerJsonWsl `
    -ReserveGb $DesktopReserveGb

if (-not $Start) {
    Write-Host '== Preflight OK. Pass -Start and -MaxSteps to launch torchrun (not started). =='
    exit 0
}

Invoke-Alfa45bTorchrun `
    -RepoWsl $RepoWsl `
    -NodeRank $Rank `
    -RdzvEndpoint $RdzvEndpoint `
    -Steps $MaxSteps `
    -ReserveGb $DesktopReserveGb `
    -DataDirWsl $DataDirWsl `
    -TokenizerJsonWsl $TokenizerJsonWsl `
    -CheckpointDirWsl $CheckpointDirWsl

Write-Host '== torchrun finished =='
