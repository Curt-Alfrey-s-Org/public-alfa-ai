#Requires -Version 5.1
<#
.SYNOPSIS
  Publish multi-repo completion corpus to hub datasets via gaming-c WSL NFS.

.DESCRIPTION
  Copies built corpus JSONL from orchestrator to hub hub path
  /mnt/cluster/training/alfa-train/datasets/ (NFS on gaming-c WSL).
  Hub-first policy: docs/HUB_ARTIFACTS.md, docs/CLUSTER_SHARED_STORAGE.md.
  Operator flow: docs/operations/MULTI_REPO_CORPUS_OPERATOR.md.
  WSL on gaming-c already mounts hub:/mnt/HDDs/Alfa-AI at /mnt/cluster;
  no extra WSL networking is required beyond existing SSH to gaming-c.

.PARAMETER PromoteCanonical
  Also copy multirepo train/val over alfa-corpus-train.jsonl and
  alfa-corpus-val.jsonl. Refused when deploy/llamacpp-rpc/alfa-train.lock exists.

.EXAMPLE
  cd C:/Users/operator\alfa-ai
  $corpus = Join-Path (Get-AlfaWindowsCacheRoot) 'train-corpus\multirepo'
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Publish-MultiRepoCorpus.ps1 -SourceDir $corpus -PromoteCanonical
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [string]$SshKey = (Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'),

    [string]$SshTarget = 'Colin@orchestrator',

    [string]$HubDatasets = '/mnt/cluster/training/alfa-train/datasets',

    [switch]$PromoteCanonical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$LockPath = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-train.lock'

$TrainJsonl = 'alfa-corpus-multirepo-train.jsonl'
$ValJsonl = 'alfa-corpus-multirepo-val.jsonl'
$ManifestName = 'CORPUS_MANIFEST.json'
$HubManifestName = 'CORPUS_MANIFEST-multirepo.json'
$CanonicalTrain = 'alfa-corpus-train.jsonl'
$CanonicalVal = 'alfa-corpus-val.jsonl'

function ConvertTo-PublishRemoteBase64 {
    param([Parameter(Mandatory = $true)][string]$BashBody)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BashBody)
    return [Convert]::ToBase64String($bytes)
}

function Invoke-PublishRemoteWslBash {
    param(
        [Parameter(Mandatory = $true)][string]$BashBody,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $b64 = ConvertTo-PublishRemoteBase64 -BashBody $BashBody
    $remote = "wsl -d Ubuntu -- bash -lc 'echo $b64 | base64 -d | bash'"
    Write-Host ("== SSH gaming-c WSL: {0} ==" -f $Label)
    & ssh -o BatchMode=yes -o ConnectTimeout=30 -i $SshKey $SshTarget $remote
    if ($LASTEXITCODE -ne 0) {
        throw "Remote WSL step failed ($Label, exit $LASTEXITCODE)"
    }
}

function Invoke-PublishPythonStep {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptRelPath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $scriptPath = Join-Path $RepoDir $ScriptRelPath
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Missing script: $scriptPath"
    }
    Write-Host ("== {0} ==" -f $Label)
    Push-Location $RepoDir
    try {
        & python $scriptPath $SourceDir
        if ($LASTEXITCODE -ne 0) {
            throw ("{0} failed (exit {1})" -f $Label, $LASTEXITCODE)
        }
    } finally {
        Pop-Location
    }
}

if ($SshTarget -notmatch '^([^@]+)@(.+)$') {
    throw "SshTarget must be user@host (example: Colin@orchestrator)"
}
$RemoteUser = $Matches[1]

if (-not (Test-Path -LiteralPath $SshKey)) {
    throw "Missing SSH key: $SshKey (run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).)"
}

$sourceResolved = (Resolve-Path -LiteralPath $SourceDir).Path
$required = @($ManifestName, $TrainJsonl, $ValJsonl)
foreach ($name in $required) {
    $path = Join-Path $sourceResolved $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required file in SourceDir: $path"
    }
}

if ($PromoteCanonical) {
    if (Test-Path -LiteralPath $LockPath) {
        throw ("Cannot promote canonical corpus while trainer lock exists at {0}. Stop trainer first (Stop-AlfaTrain7bQlora.ps1 or GUI Train -> Stop trainer)." -f $LockPath)
    }
}

Invoke-PublishPythonStep -ScriptRelPath 'scripts\scan_pass_jsonl.py' -Label 'Secret scan (must be clean)'
Invoke-PublishPythonStep -ScriptRelPath 'scripts\verify_multi_repo_corpus.py' -Label 'Verify multi-repo corpus'

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$winStageDir = "C:/Users/$RemoteUser/AppData/Local/Temp/alfa-corpus-publish-$stamp"
$wslStageDir = "/mnt/c/Users/$RemoteUser/AppData/Local/Temp/alfa-corpus-publish-$stamp"

Write-Host ("== Stage on gaming-c: {0} ==" -f $winStageDir)
$mkdirBash = @"
set -e
mkdir -p '$wslStageDir'
"@
Invoke-PublishRemoteWslBash -BashBody $mkdirBash -Label 'create stage dir'

Write-Host '== SCP corpus files to gaming-c =='
$scpFiles = @($TrainJsonl, $ValJsonl, $ManifestName)
foreach ($fileName in $scpFiles) {
    $localPath = Join-Path $sourceResolved $fileName
    $remotePath = "${SshTarget}:${winStageDir}/${fileName}"
    Write-Host ("  scp {0}" -f $fileName)
    & scp -o BatchMode=yes -o ConnectTimeout=60 -i $SshKey $localPath $remotePath
    if ($LASTEXITCODE -ne 0) {
        throw ("scp failed for {0} (exit {1})" -f $fileName, $LASTEXITCODE)
    }
}

$promoteFlag = '0'
if ($PromoteCanonical) {
    $promoteFlag = '1'
}

$hubCopyBash = @"
set -e
HUB='$HubDatasets'
STAGE='$wslStageDir'
PROMOTE='$promoteFlag'
if ! mountpoint -q /mnt/cluster; then
  echo 'FAIL: /mnt/cluster is not mounted on gaming-c WSL (NFS from hub hub)'
  exit 2
fi
mkdir -p "`$HUB"
cp -f "`$STAGE/$TrainJsonl" "`$HUB/$TrainJsonl"
cp -f "`$STAGE/$ValJsonl" "`$HUB/$ValJsonl"
cp -f "`$STAGE/$ManifestName" "`$HUB/$HubManifestName"
if [ "`$PROMOTE" = '1' ]; then
  cp -f "`$STAGE/$TrainJsonl" "`$HUB/$CanonicalTrain"
  cp -f "`$STAGE/$ValJsonl" "`$HUB/$CanonicalVal"
fi
echo '== Hub datasets (published files) =='
ls -lh "`$HUB/$TrainJsonl" "`$HUB/$ValJsonl" "`$HUB/$HubManifestName"
if [ "`$PROMOTE" = '1' ]; then
  ls -lh "`$HUB/$CanonicalTrain" "`$HUB/$CanonicalVal"
fi
rm -rf "`$STAGE"
"@

Invoke-PublishRemoteWslBash -BashBody $hubCopyBash -Label 'copy to hub datasets'

Write-Host 'Publish complete.' -ForegroundColor Green
if ($PromoteCanonical) {
    Write-Host 'Canonical alfa-corpus-train.jsonl / alfa-corpus-val.jsonl updated on hub.'
} else {
    Write-Host 'Multirepo files only (no canonical promote). Re-run with -PromoteCanonical after stopping trainer.'
}
