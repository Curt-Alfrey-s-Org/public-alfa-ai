#Requires -Version 5.1
<#
.SYNOPSIS
  One 7B continue-train + convert + sequential eval + live FAQ cycle.

.DESCRIPTION
  Wraps existing scripts. Does not implement a new trainer. Does not call
  Start-Stop-AlfaAi.ps1. Does not start LiteLLM or set LLAMACPP_7B_URL.
  Does not probe or restart inference shards.

  Order:
    1. Start-AlfaTrain7bQlora.ps1 (skip if lock already present or -SkipTrain)
    2. Wait hub FINISHED (Training completed / Model successfully saved /
       train_runtime) AND alfa-train-7b-59 container down. Start launcher
       exit 0 is not done.
    3. Stop-AlfaTrain7bQlora.ps1
    4. SSH hub convert-7b-qlora-to-gguf.sh (hub-first)
    5. git pull on gaming-c worker clone if that path has .git; skip SMB staged copies
    6. Start-Alfa7bServe -NoLora, Wait-AlfaHttpPoll /health, generate base
    7. Stop-Alfa7bServe
    8. Start-Alfa7bServe -LoraGguf, wait /health, generate checkpoint
    9. train_checkpoint_gate.py (informational smoke)
   10. live_7b_faq_gate.py (Yes/No polarity; failure fails the cycle)
   11. Stop-Alfa7bServe

  llama-server GET /health: HTTP 503 while loading is normal; wait until 200.
    https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
  Continue QLoRA: Axolotl lora_model_dir (Start script), not resume_from_checkpoint.
    https://docs.axolotl.ai/docs/lora.html
  Convert: convert_lora_to_gguf.py
    https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py
  Live chat: OpenAI chat/completions via Python urllib (not curl.exe JSON on PS 5.1).
    https://platform.openai.com/docs/api-reference/chat/create
    https://learn.microsoft.com/en-us/windows/curl/
  hub sudo allowlist (absolute paths):
    https://www.hub.com/docs/scale/23.10/scaleclireference/account/cliuser/
  docker ps:
    https://docs.docker.com/reference/cli/docker/container/ps/
  Wait-AlfaHttpPoll uses Invoke-WebRequest (in-repo helper, not operator paste).

.EXAMPLE
  cd C:/Users/operator\alfa-ai
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaTrain7bEvalCycle.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaTrain7bEvalCycle.ps1 -EvalOnly
#>
[CmdletBinding()]
param(
    [switch]$SkipTrain,
    [switch]$SkipConvert,
    [switch]$EvalOnly,
    [switch]$Include219,
    [switch]$SingleHost59,
    [switch]$FreshAdapter,
    [string]$AdapterId = 'pool-7b-qlora-v2',
    [string]$CheckpointDir = '/mnt/HDDs/Alfa-AI/training/alfa-train/checkpoints/pool-7b-qlora-v2',
    [int]$TrainTimeoutSec = 43200,
    [int]$PollIntervalSec = 60,
    [int]$ServeHealthTimeoutSec = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($EvalOnly) {
    $SkipTrain = $true
    $SkipConvert = $true
}

if ($Include219 -and $SingleHost59) {
    throw 'Pass only one of -Include219 or -SingleHost59.'
}

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$CommonDir = Join-Path $PSScriptRoot '..\_common'
$LockPath = Join-Path $RepoDir 'deploy\llamacpp-rpc\alfa-train.lock'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$StartTrain = Join-Path $PSScriptRoot 'Start-AlfaTrain7bQlora.ps1'
$StopTrain = Join-Path $PSScriptRoot 'Stop-AlfaTrain7bQlora.ps1'
$StartServe = Join-Path $PSScriptRoot 'Start-Alfa7bServe.ps1'
$StopServe = Join-Path $PSScriptRoot 'Stop-Alfa7bServe.ps1'
$WaitHelper = Join-Path $CommonDir 'Wait-AlfaHttpPoll.ps1'
$CacheHelper = Join-Path $CommonDir 'Get-AlfaWindowsCacheRoot.ps1'
$GenPy = Join-Path $RepoDir 'scripts\eval\generate_7b_eval_answers.py'
$GatePy = Join-Path $RepoDir 'scripts\eval\train_checkpoint_gate.py'
$FaqPy = Join-Path $RepoDir 'scripts\eval\live_7b_faq_gate.py'

. $WaitHelper
. $CacheHelper

$Ssh59 = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
$Key59 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
$Ssh111 = if ($env:inference_SSH_111_TARGET) { $env:inference_SSH_111_TARGET } else { 'operator@hub' }
$Key111 = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_111'
$Repo111 = '/mnt/HDDs/Alfa-AI/repo/alfa-ai'
$ConvertAbs = "$Repo111/deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh"
$Repo59Worker = if ($env:ALFA_REPO_59_WIN) { $env:ALFA_REPO_59_WIN } else { 'C:\alfa-ai-worker' }
$LoraGguf = ($AdapterId + '.gguf')
$HealthUrl = 'http://orchestrator/health'
$ChatBase = 'http://orchestrator/v1'

$evalRoot = Join-Path (Get-AlfaWindowsCacheRoot) 'eval'
if (-not (Test-Path -LiteralPath $evalRoot)) {
    New-Item -ItemType Directory -Force -Path $evalRoot | Out-Null
}
$OutBase = Join-Path $evalRoot '7b-v2-base-answers.jsonl'
$OutCkpt = Join-Path $evalRoot '7b-v2-ckpt-answers.jsonl'

function ConvertTo-AlfaCycleRemoteBase64 {
    param([Parameter(Mandatory)][string]$BashBody)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BashBody)
    return [Convert]::ToBase64String($bytes)
}

function ConvertTo-AlfaCycleSshText {
    param($Output)
    if ($null -eq $Output) {
        return ''
    }
    if ($Output -is [string]) {
        return [string]$Output
    }
    $parts = @()
    foreach ($item in @($Output)) {
        if ($null -ne $item) {
            $parts += $item.ToString()
        }
    }
    return ($parts -join "`n")
}

function Invoke-AlfaCycleSsh {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [int]$ConnectTimeoutSec = 30,
        [bool]$UseServerAlive = $false
    )
    $exitCode = 1
    $sshOut = $null
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($UseServerAlive) {
            $sshOut = & ssh -o BatchMode=yes -o ConnectTimeout=$ConnectTimeoutSec -o ServerAliveInterval=15 -o ServerAliveCountMax=40 -i $KeyPath $Target $RemoteCommand 2>&1
        } else {
            $sshOut = & ssh -o BatchMode=yes -o ConnectTimeout=$ConnectTimeoutSec -i $KeyPath $Target $RemoteCommand 2>&1
        }
        if ($null -ne $LASTEXITCODE) {
            $exitCode = [int]$LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $text = ConvertTo-AlfaCycleSshText -Output $sshOut
    return @{
        Text = $text
        ExitCode = $exitCode
    }
}

function Get-AlfaCycleTrainLogDir {
    if (-not (Test-Path -LiteralPath $LockPath)) {
        return $null
    }
    foreach ($line in @(Get-Content -LiteralPath $LockPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^LOGDIR=(.+)$') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Get-AlfaCycleHubLogPhaseFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'starting'
    }
    if ($Text -match 'LOG_MISSING' -and $Text -notmatch 'LOG=OK|LOG249=OK') {
        return 'starting'
    }
    if ($Text -match 'DistNetworkError|DistStoreError|timed out after|ChildFailedError|RendezvousTimeoutError|RendezvousConnectionError|CUDA out of memory|device not ready|CUDA driver error|PermissionError|bus error|insufficient shared memory|Traceback \(most recent call last\)') {
        return 'failed'
    }
    if ($Text -match 'Training completed|Model successfully saved|train_runtime') {
        return 'finished'
    }
    if ($Text -match '(?i)\bloss\b|Total train batch') {
        return 'training'
    }
    return 'starting'
}

function Invoke-AlfaCycleSsh59WslBash {
    param([Parameter(Mandatory)][string]$BashBody)
    $b64 = ConvertTo-AlfaCycleRemoteBase64 -BashBody $BashBody
    $remote = ('wsl -d Ubuntu -- bash -lc ''echo {0} | base64 -d | bash''' -f $b64)
    $result = Invoke-AlfaCycleSsh -KeyPath $Key59 -Target $Ssh59 -RemoteCommand $remote
    return $result.Text
}

function Get-AlfaCycleTrainProbe {
    $logDir = Get-AlfaCycleTrainLogDir
    $bashLines = @(
        'set +e',
        'out=$(timeout -k 2 8 docker ps -q -f name=alfa-train-7b-59)',
        'st=$?',
        'if [ $st -eq 0 ]; then',
        '  if [ -n "$out" ]; then echo CONTAINER=UP; else echo CONTAINER=DOWN; fi',
        'else',
        '  echo CONTAINER=PROBE_TIMEOUT',
        'fi'
    )
    if (-not [string]::IsNullOrWhiteSpace($logDir)) {
        $bashLines += ('f="{0}/alfa-train-7b-59.log"' -f $logDir)
        $bashLines += 'if [ -f "$f" ]; then echo LOG=OK; timeout -k 2 8 tail -c 65536 "$f"; else echo LOG_MISSING; fi'
        $bashLines += ('f249="{0}/alfa-train-7b-249.log"' -f $logDir)
        $bashLines += 'if [ -f "$f249" ]; then echo LOG249=OK; timeout -k 2 8 tail -c 65536 "$f249"; fi'
    } else {
        $bashLines += 'echo LOGDIR_MISSING'
    }
    $text = Invoke-AlfaCycleSsh59WslBash -BashBody ($bashLines -join "`n")
    $container = 'UNKNOWN'
    if ($text -match 'CONTAINER=([A-Z_]+)') {
        $container = $Matches[1]
    }
    $phase = Get-AlfaCycleHubLogPhaseFromText -Text $text
    return @{
        Container = $container
        Phase     = $phase
        Text      = $text
    }
}

function Wait-AlfaCycleTrainFinished {
    Write-Host ("== Wait hub FINISHED (timeout {0}s, poll {1}s). Launcher OK is not done. ==" -f $TrainTimeoutSec, $PollIntervalSec) -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TrainTimeoutSec)
    $probeFails = 0
    $downNotFinished = 0
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $LockPath)) {
            throw 'Train lock gone before FINISHED. Stop trainer ran early?'
        }
        try {
            $probe = Get-AlfaCycleTrainProbe
        } catch {
            $probeFails++
            Write-Host ("  (probe error {0}: {1})" -f $probeFails, $_.Exception.Message) -ForegroundColor DarkGray
            if ($probeFails -ge 5) {
                throw 'Train hub probe failed 5 times in a row.'
            }
            Start-Sleep -Seconds $PollIntervalSec
            continue
        }
        if ($probe.Container -eq 'UNKNOWN' -or $probe.Container -eq 'PROBE_TIMEOUT') {
            $probeFails++
            Write-Host ("  (probe incomplete {0}: container={1})" -f $probeFails, $probe.Container) -ForegroundColor DarkGray
            if ($probeFails -ge 5) {
                throw 'Train hub probe returned UNKNOWN or PROBE_TIMEOUT 5 times in a row.'
            }
            Start-Sleep -Seconds $PollIntervalSec
            continue
        }
        $probeFails = 0
        Write-Host ("== train wait phase={0} container={1} ==" -f $probe.Phase, $probe.Container)
        if ($probe.Phase -eq 'failed') {
            throw 'Hub log shows FAILED (traceback / dist / CUDA). Stop trainer will run. Do not convert.'
        }
        if ($probe.Phase -eq 'finished' -and $probe.Container -eq 'DOWN') {
            Write-Host '== Hub FINISHED and alfa-train-7b-59 is down ==' -ForegroundColor Green
            return
        }
        if ($probe.Container -eq 'DOWN' -and $probe.Phase -ne 'finished') {
            $downNotFinished++
            if ($downNotFinished -ge 2) {
                throw 'Train container down before FINISHED (crash). Stop trainer will run. Do not convert.'
            }
        } else {
            $downNotFinished = 0
        }
        Start-Sleep -Seconds $PollIntervalSec
    }
    throw ("Train wait timed out after {0}s without FINISHED + container down." -f $TrainTimeoutSec)
}

function Invoke-AlfaCycleChildScript {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$ChildArgs
    )
    if ($null -eq $ChildArgs) {
        $ChildArgs = @()
    }
    Write-Host ("== {0} {1} ==" -f (Split-Path -Leaf $File), ($ChildArgs -join ' ')) -ForegroundColor Cyan
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $File @ChildArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed (exit {1})" -f (Split-Path -Leaf $File), $LASTEXITCODE)
    }
}

function Invoke-AlfaCyclePython {
    param(
        [Parameter(Mandatory)][string[]]$PyArgs,
        [switch]$AllowFailure
    )
    Write-Host ("== python {0} ==" -f ($PyArgs -join ' ')) -ForegroundColor Cyan
    & python @PyArgs
    if ($LASTEXITCODE -ne 0) {
        $msg = ("python failed (exit {0}): {1}" -f $LASTEXITCODE, ($PyArgs -join ' '))
        if ($AllowFailure) {
            Write-Host ("WARN: {0} (smoke is informational)" -f $msg) -ForegroundColor Yellow
            return
        }
        throw $msg
    }
}

function Get-AlfaCycleConvertPaste {
    return @(
        'From hub (operator):'
        'cd /mnt/HDDs/Alfa-AI/repo/alfa-ai'
        ('sudo env CHECKPOINT_DIR={0} ADAPTER_ID={1} FORCE_LORA_CONVERT=1 bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh' -f $CheckpointDir, $AdapterId)
        'Then from orchestrator: re-run Invoke-AlfaTrain7bEvalCycle.ps1 -EvalOnly'
        '(or -SkipTrain -SkipConvert if you still need convert skipped but want other cycle flags).'
        'To make SSH convert work next time, add convert-7b-qlora-to-gguf.sh to operator sudo_commands_nopasswd (docs/POOL_SWITCH_OPERATOR.md).'
    ) -join "`n"
}

function Invoke-AlfaCycleConvert111 {
    if (-not (Test-Path -LiteralPath $Key111)) {
        throw ("Missing {0}. Convert from hub, then re-run with -SkipTrain.`n{1}" -f $Key111, (Get-AlfaCycleConvertPaste))
    }
    Write-Host '== SSH hub: git pull --ff-only then convert LoRA GGUF ==' -ForegroundColor Cyan
    $bash = @"
set -e
cd '$Repo111'
git pull --ff-only origin main
sudo env CHECKPOINT_DIR='$CheckpointDir' ADAPTER_ID='$AdapterId' FORCE_LORA_CONVERT=1 bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh
"@
    $b64 = ConvertTo-AlfaCycleRemoteBase64 -BashBody $bash
    $remote = ('bash -lc ''echo {0} | base64 -d | bash''' -f $b64)
    $sshResult = Invoke-AlfaCycleSsh -KeyPath $Key111 -Target $Ssh111 -RemoteCommand $remote -ConnectTimeoutSec 20 -UseServerAlive $true
    $text = $sshResult.Text
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-Host $text
    }
    if ($sshResult.ExitCode -ne 0) {
        $msg = ("Convert on hub failed (exit {0})." -f $sshResult.ExitCode)
        if ($text -match 'sudo: a password is required') {
            $msg += ' Grant operator sudo_commands_nopasswd for convert-7b-qlora-to-gguf.sh (docs/POOL_SWITCH_OPERATOR.md).'
        }
        $msg += "`n" + (Get-AlfaCycleConvertPaste)
        throw $msg
    }
}

function Invoke-AlfaCycleGitPull59Worker {
    $gitDir = ($Repo59Worker.TrimEnd('\') + '\.git')
    Write-Host ("== SSH gaming-c: git pull --ff-only in {0} ==" -f $Repo59Worker) -ForegroundColor Cyan
    $probeResult = Invoke-AlfaCycleSsh -KeyPath $Key59 -Target $Ssh59 -RemoteCommand ("Test-Path -LiteralPath '{0}'" -f $gitDir)
    $probeText = $probeResult.Text
    if ($probeText -notmatch 'True') {
        Write-Host ("SKIP: {0} has no .git (SMB staged copy is OK; eval is driven from orchestrator)." -f $Repo59Worker) -ForegroundColor Yellow
        return
    }
    $remote = ('git -C "{0}" pull --ff-only origin main' -f $Repo59Worker)
    $pullResult = Invoke-AlfaCycleSsh -KeyPath $Key59 -Target $Ssh59 -RemoteCommand $remote
    if ($pullResult.ExitCode -ne 0) {
        throw ("git pull --ff-only failed on gaming-c clone {0} (exit {1})" -f $Repo59Worker, $pullResult.ExitCode)
    }
}

function Wait-AlfaCycleServeHealth {
    Write-Host ("== Wait {0} (llama-server 503 while loading is normal) ==" -f $HealthUrl) -ForegroundColor Cyan
    $ok = Wait-AlfaHttpPoll -Url $HealthUrl -TimeoutSec $ServeHealthTimeoutSec -IntervalSec 10 -RequestTimeoutSec 10
    if (-not $ok) {
        throw ("7B serve /health not HTTP 200 within {0}s ({1})" -f $ServeHealthTimeoutSec, $HealthUrl)
    }
}

foreach ($need in @($StartTrain, $StopTrain, $StartServe, $StopServe, $WaitHelper, $CacheHelper, $GenPy, $GatePy, $FaqPy)) {
    if (-not (Test-Path -LiteralPath $need)) {
        throw ("Missing {0}" -f $need)
    }
}

Write-Host '== 7B train/eval cycle (no LiteLLM, no inference Start-Stop) ==' -ForegroundColor Cyan
Write-Host ("adapter={0} checkpoint={1} lora_gguf={2}" -f $AdapterId, $CheckpointDir, $LoraGguf)

$serveStarted = $false
$trainStopNeeded = $false
try {
    if (-not $SkipTrain) {
        if (Test-Path -LiteralPath $LockPath) {
            Write-Host '== Train lock present; skipping Start; waiting for FINISHED ==' -ForegroundColor Yellow
        } else {
            $startArgs = @()
            if ($Include219) { $startArgs += '-Include219' }
            if ($SingleHost59) { $startArgs += '-SingleHost59' }
            if ($FreshAdapter) { $startArgs += '-FreshAdapter' }
            Invoke-AlfaCycleChildScript -File $StartTrain -ChildArgs $startArgs
        }
        $trainStopNeeded = $true
        Wait-AlfaCycleTrainFinished
        Invoke-AlfaCycleChildScript -File $StopTrain
        $trainStopNeeded = $false
    } else {
        if (Test-Path -LiteralPath $LockPath) {
            Write-Host '== -SkipTrain with lock present; waiting for FINISHED then Stop trainer ==' -ForegroundColor Yellow
            $trainStopNeeded = $true
            Wait-AlfaCycleTrainFinished
            Invoke-AlfaCycleChildScript -File $StopTrain
            $trainStopNeeded = $false
        } else {
            Write-Host '== -SkipTrain and no train lock; convert/eval only =='
        }
    }

    if (-not $SkipConvert) {
        Invoke-AlfaCycleConvert111
    } else {
        Write-Host '== -SkipConvert; using existing LoRA GGUF on hub =='
    }

    Invoke-AlfaCycleGitPull59Worker

    Invoke-AlfaCycleChildScript -File $StartServe -ChildArgs @('-NoLora')
    $serveStarted = $true
    Wait-AlfaCycleServeHealth
    Invoke-AlfaCyclePython -PyArgs @(
        $GenPy,
        '--only', 'base',
        '--base-url', $ChatBase,
        '--out-base', $OutBase
    )
    Invoke-AlfaCycleChildScript -File $StopServe
    $serveStarted = $false

    Invoke-AlfaCycleChildScript -File $StartServe -ChildArgs @('-LoraGguf', $LoraGguf)
    $serveStarted = $true
    Wait-AlfaCycleServeHealth
    Invoke-AlfaCyclePython -PyArgs @(
        $GenPy,
        '--only', 'checkpoint',
        '--checkpoint-url', $ChatBase,
        '--out-checkpoint', $OutCkpt
    )
    Invoke-AlfaCyclePython -PyArgs @(
        $GatePy,
        '--answers-base', $OutBase,
        '--answers-checkpoint', $OutCkpt
    ) -AllowFailure
    Invoke-AlfaCyclePython -PyArgs @(
        $FaqPy,
        '--base-url', $ChatBase
    )
    Invoke-AlfaCycleChildScript -File $StopServe
    $serveStarted = $false

    Write-Host 'CYCLE OK: live FAQ polarity passed. Do not set LLAMACPP_7B_URL unless the operator asks.' -ForegroundColor Green
} catch {
    Write-Host ("CYCLE FAIL: {0}" -f $_.Exception.Message) -ForegroundColor Red
    throw
} finally {
    if ($serveStarted) {
        Write-Host '== Cycle cleanup: Stop-Alfa7bServe.ps1 ==' -ForegroundColor Yellow
        try {
            & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $StopServe
        } catch {
            Write-Host ("WARN: Stop serve cleanup: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($trainStopNeeded) {
        Write-Host '== Cycle cleanup: Stop-AlfaTrain7bQlora.ps1 ==' -ForegroundColor Yellow
        try {
            & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $StopTrain
        } catch {
            Write-Host ("WARN: Stop trainer cleanup: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
