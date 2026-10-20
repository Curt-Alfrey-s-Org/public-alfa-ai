#Requires -Version 5.1
<#
.SYNOPSIS
    inference error-only log session helpers (orchestrator orchestrator).
    Non-fatal: recorder failures and SSH deadlines must never block cluster start/stop.
#>
Set-StrictMode -Version Latest

$script:inferenceLogScriptNames = @(
    'inference-log-helpers.sh',
    'record-inference-host-logs.sh',
    'start-inference-log-session.sh',
    'stop-inference-log-session.sh'
)

function Get-inferenceLogSessionRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return Join-Path $RepoRoot 'logs\inference-sessions'
}

function Get-inferenceLogCurrentSessionFile {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return Join-Path (Get-inferenceLogSessionRoot -RepoRoot $RepoRoot) '.current-session'
}

function Get-inferenceLogSessionId {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $marker = Get-inferenceLogCurrentSessionFile -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $marker) {
        return (Get-Content -LiteralPath $marker -Raw).Trim()
    }
    return $null
}

function New-inferenceLogSession {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Action = 'cycle'
    )

    $root = Get-inferenceLogSessionRoot -RepoRoot $RepoRoot
    $sessionId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + $Action.ToLower()
    $sessionDir = Join-Path $root $sessionId
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    Set-Content -LiteralPath (Get-inferenceLogCurrentSessionFile -RepoRoot $RepoRoot) -Value $sessionId -NoNewline
    @{
        SessionId  = $sessionId
        SessionDir = $sessionDir
    }
}

function Resolve-inferenceRemoteRepo {
    param(
        [Parameter(Mandatory)][string]$RemoteRepo,
        [Parameter(Mandatory)][string]$SshTarget
    )
    if ($RemoteRepo -notmatch '^~') {
        return $RemoteRepo
    }
    if ($SshTarget -match '@([^@]+)$') {
        $hostPart = $Matches[1]
        $user = 'operator'
        if ($SshTarget -match '^([^@]+)@') {
            $user = $Matches[1]
        }
        switch -Regex ($hostPart) {
            '192\.168\.0\inference' { return "/home/$user/alfa-ai" }
            '192\.168\.0\inference'  { return "/home/$user/alfa-ai" }
            default { return $RemoteRepo -replace '^~', "/home/$user" }
        }
    }
    return $RemoteRepo -replace '^~', '/home/operator'
}

function Test-inferenceLogScriptsLocal {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $common = Join-Path $RepoRoot 'deploy\cluster-members\_common'
    foreach ($name in $script:inferenceLogScriptNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $common $name))) {
            return $false
        }
    }
    return $true
}

function Get-inferenceSsh111KeyPath {
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_111'
    if (-not (Test-Path -LiteralPath $key)) {
        throw "Missing hub SSH key: $key"
    }
    return $key
}

function Get-AlfaSsh107KeyPath {
    # Optional: incident-metrics bearer refresh after cluster start. Missing = skip/WARN.
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_107'
    if (-not (Test-Path -LiteralPath $key)) {
        return $null
    }
    return $key
}

function Format-inferenceProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '\s|"') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Test-inferenceHostInActiveEnv {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$HostIp
    )
    $activePath = Join-Path $RepoRoot 'deploy\llamacpp-rpc\inference-shards.active.env'
    if (-not (Test-Path -LiteralPath $activePath)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $activePath) {
        $trim = ($line -replace '#.*$', '').Trim()
        if (-not $trim) { continue }
        $parts = $trim -split '\s+'
        if ($parts.Count -ge 1 -and $parts[0] -eq $HostIp) {
            return $true
        }
    }
    return $false
}

function Get-inferenceLogRemoteHostPairs {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ssh100,
        [Parameter(Mandatory)][string]$Ssh248,
        [Parameter(Mandatory)][string]$Ssh148,
        [Parameter(Mandatory)][string]$Repo100,
        [Parameter(Mandatory)][string]$Repo248,
        [Parameter(Mandatory)][string]$Repo148
    )
    $pairs = @(
        @{ Label = '100'; Ssh = $Ssh100; Repo = $Repo100 }
    )
    if (Test-inferenceHostInActiveEnv -RepoRoot $RepoRoot -HostIp 'orchestrator') {
        $pairs += @{ Label = '248'; Ssh = $Ssh248; Repo = $Repo248 }
    }
    $pairs += @{ Label = '148'; Ssh = $Ssh148; Repo = $Repo148 }
    return $pairs
}

function Invoke-inferenceLogSsh {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [int]$ConnectTimeoutSec = 15,
        [int]$CommandTimeoutSec = 20,
        [string]$IdentityFile = ''
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    $lines = @()
    $cmd = $RemoteCommand
    if ($CommandTimeoutSec -gt 0) {
        $cmd = "timeout $CommandTimeoutSec bash -lc " + [char]39 + ($RemoteCommand -replace "'", "'\\''") + [char]39
    }
    # Local wall clock: ConnectTimeout covers TCP/KEX only (ssh_config.5); Kill if ssh still running.
    # WaitForExit(Int32): https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexit
    # Kill: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill
    $wallMs = ($ConnectTimeoutSec + $CommandTimeoutSec + 10) * 1000
    $proc = $null
    try {
        $argParts = @(
            '-o', 'BatchMode=yes',
            '-o', "ConnectTimeout=$ConnectTimeoutSec",
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3'
        )
        if ($IdentityFile) {
            $argParts += @('-i', $IdentityFile)
        }
        $argParts += @($SshTarget, $cmd)
        $argString = ($argParts | ForEach-Object { Format-inferenceProcessArgument -Value $_ }) -join ' '

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()
        $finished = $proc.WaitForExit($wallMs)
        if (-not $finished) {
            try {
                $proc.Kill()
            } catch {
                # Process may have exited between WaitForExit and Kill.
            }
            $null = $proc.WaitForExit(5000)
            Write-Host "  WARN: ssh local deadline (${wallMs}ms) exceeded for $SshTarget" -ForegroundColor Yellow
            $exitCode = 1
        } else {
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $exitCode = $proc.ExitCode
            $lines = @()
            if ($stdout) {
                $lines += ($stdout -split "`r?`n")
            }
            if ($stderr) {
                $lines += ($stderr -split "`r?`n")
            }
            if ($CommandTimeoutSec -gt 0 -and $exitCode -eq 124) {
                Write-Host "  WARN: remote command timed out after ${CommandTimeoutSec}s on $SshTarget" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "  WARN: ssh launch failed for $SshTarget ($($_.Exception.Message))" -ForegroundColor Yellow
        $exitCode = 1
    } finally {
        if ($null -ne $proc) {
            if (-not $proc.HasExited) {
                try {
                    $proc.Kill()
                } catch {
                    # Best-effort cleanup.
                }
                $null = $proc.WaitForExit(5000)
            }
            $proc.Dispose()
        }
        $ErrorActionPreference = $prev
    }
    foreach ($line in @($lines)) {
        if ($null -eq $line) { continue }
        $text = $line.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match 'US Government Contractor information system') { continue }
        if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL|No such file|WARN') {
            Write-Host "  $text" -ForegroundColor Yellow
        }
    }
    return $exitCode
}

function Install-inferenceLogScriptsViaScp {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$RemoteRepo,
        [Parameter(Mandatory)][string]$LocalRepoRoot,
        [Parameter(Mandatory)][string]$HostLabel
    )
    if (-not (Test-inferenceLogScriptsLocal -RepoRoot $LocalRepoRoot)) {
        Write-Host "  WARN: inference scripts missing locally on orchestrator ($LocalRepoRoot)" -ForegroundColor Yellow
        return $false
    }
    $repo = Resolve-inferenceRemoteRepo -RemoteRepo $RemoteRepo -SshTarget $SshTarget
    $localCommon = Join-Path $LocalRepoRoot 'deploy\cluster-members\_common'
    $remoteDir = "$repo/deploy/cluster-members/_common"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = ssh -o BatchMode=yes -o ConnectTimeout=15 $SshTarget "mkdir -p '$remoteDir'" 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        foreach ($name in $script:inferenceLogScriptNames) {
            $localFile = Join-Path $localCommon $name
            $dest = "${SshTarget}:${remoteDir}/"
            $null = scp -o BatchMode=yes -o ConnectTimeout=20 $localFile $dest 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  WARN: scp $name to .$HostLabel failed" -ForegroundColor Yellow
                return $false
            }
        }
        Write-Host "  OK inference scripts pushed to .$HostLabel via scp" -ForegroundColor DarkGreen
        return $true
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Sync-inferenceLogScriptsRemote {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$RemoteRepo,
        [Parameter(Mandatory)][string]$LocalRepoRoot,
        [Parameter(Mandatory)][string]$HostLabel
    )
    $repo = Resolve-inferenceRemoteRepo -RemoteRepo $RemoteRepo -SshTarget $SshTarget
    $check = "test -f $repo/deploy/cluster-members/_common/record-inference-host-logs.sh"
    if ((Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $check) -eq 0) {
        return $true
    }

    Write-Host "  inference-log: syncing scripts on .$HostLabel ..." -ForegroundColor DarkGray
    $gitSync = "cd $repo && git fetch origin main 2>/dev/null && git reset --hard origin/main 2>/dev/null"
    $null = Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $gitSync -ConnectTimeoutSec 45 -CommandTimeoutSec 90
    if ((Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $check) -eq 0) {
        Write-Host "  OK inference scripts on .$HostLabel (git)" -ForegroundColor DarkGreen
        return $true
    }

    return (Install-inferenceLogScriptsViaScp -SshTarget $SshTarget -RemoteRepo $RemoteRepo `
        -LocalRepoRoot $LocalRepoRoot -HostLabel $HostLabel)
}

function Join-inferenceRemoteScript {
    param(
        [Parameter(Mandatory)][string]$RepoBase,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $rel = ($RelativePath -replace '\\', '/').TrimStart('/')
    return "$RepoBase/$rel"
}

function Get-inferenceLiveRecordRemoteCommand {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$RepoBase
    )
    $scriptAbs = Join-inferenceRemoteScript -RepoBase $RepoBase -RelativePath 'deploy/cluster-members/_common/record-inference-host-logs.sh'
    return "inference_LOG_SESSION_ID='$SessionId' HOST_LABEL='$HostLabel' TEE_LOG=1 SCP_TO_93=0 bash $scriptAbs"
}

function Invoke-inferenceLogRemoteStart {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$RemoteRepo,
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$LocalRepoRoot
    )
    if (-not (Sync-inferenceLogScriptsRemote -SshTarget $SshTarget -RemoteRepo $RemoteRepo `
            -LocalRepoRoot $LocalRepoRoot -HostLabel $HostLabel)) {
        return 1
    }
    $repo = Resolve-inferenceRemoteRepo -RemoteRepo $RemoteRepo -SshTarget $SshTarget
    $startScript = Join-inferenceRemoteScript -RepoBase $repo -RelativePath 'deploy/cluster-members/_common/start-inference-log-session.sh'
    # Vars after sudo (env_reset). No single quotes - Windows ssh + bash -lc timeout wrapper escapes them.
    $envPrefix = "ALFA_AI_REPO=$repo inference_LOG_SESSION_ID=$SessionId HOST_LABEL=$HostLabel PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    $remoteSudo = "sudo -n $envPrefix bash $startScript"
    $code = Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $remoteSudo.Trim() -CommandTimeoutSec 45
    if ($code -ne 0) {
        $remoteUser = "$envPrefix bash $startScript"
        $code = Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $remoteUser.Trim() -CommandTimeoutSec 45
    }
    return $code
}

function Invoke-inferenceLogRemoteStop {
    param(
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$RemoteRepo,
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$LocalRepoRoot
    )
    $repo = Resolve-inferenceRemoteRepo -RemoteRepo $RemoteRepo -SshTarget $SshTarget
    $stopScript = Join-inferenceRemoteScript -RepoBase $repo -RelativePath 'deploy/cluster-members/_common/stop-inference-log-session.sh'
    $check = "test -f $stopScript"
    if ((Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $check) -ne 0) {
        $null = Sync-inferenceLogScriptsRemote -SshTarget $SshTarget -RemoteRepo $RemoteRepo `
            -LocalRepoRoot $LocalRepoRoot -HostLabel $HostLabel
    }
    $envPrefix = "ALFA_AI_REPO=$repo inference_LOG_SESSION_ID=$SessionId HOST_LABEL=$HostLabel PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    $remoteSudo = "test -f $stopScript && sudo -n $envPrefix bash $stopScript || true"
    $code = Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $remoteSudo.Trim() -ConnectTimeoutSec 20
    if ($code -ne 0) {
        $remoteUser = "test -f $stopScript && $envPrefix bash $stopScript || true"
        $code = Invoke-inferenceLogSsh -SshTarget $SshTarget -RemoteCommand $remoteUser.Trim() -ConnectTimeoutSec 20
    }
    return $code
}

function Invoke-inferenceLogWsl {
    param([Parameter(Mandatory)][string]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = wsl.exe -d Ubuntu bash -lc $Command 2>&1
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Start-inferenceLogSessionAutonomous {
    <#
    .SYNOPSIS
        Start background error recorders on orchestrator (WSL), pool-opt-in, and inference.
        hub is started via operator-cluster-111.sh start-error-logs (manual step).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Ssh100 = 'operator@orchestrator',
        [string]$Ssh248 = 'operator@orchestrator',
        [string]$Ssh111 = 'operator@hub',
        [string]$Ssh148 = 'operator@orchestrator',
        [string]$Repo100 = '/home/operator/alfa-ai',
        [string]$Repo248 = '/home/operator/alfa-ai',
        [string]$Repo148 = '/home/operator/alfa-ai'
    )

    $drive = $RepoRoot.Substring(0, 1).ToLower()
    $wslRepo = "/mnt/$drive/" + ($RepoRoot.Substring(3) -replace '\\', '/')
    $wslStart = "$wslRepo/deploy/cluster-members/_common/start-inference-log-session.sh"

    $remotePairs = Get-inferenceLogRemoteHostPairs -RepoRoot $RepoRoot -Ssh100 $Ssh100 -Ssh248 $Ssh248 `
        -Ssh148 $Ssh148 -Repo100 $Repo100 -Repo248 $Repo248 -Repo148 $Repo148
    $hostList = 'orchestrator/' + (($remotePairs | ForEach-Object { '.' + $_.Label }) -join '/')
    Write-Host "inference-log: starting autonomous error recorders ($hostList) session=$SessionId" -ForegroundColor Cyan

    if ((Invoke-inferenceLogWsl -Command "test -f '$wslStart' && inference_LOG_SESSION_ID='$SessionId' HOST_LABEL=93 bash '$wslStart'") -ne 0) {
        Write-Host '  WARN: orchestrator WSL error recorder did not start' -ForegroundColor Yellow
    } else {
        Write-Host '  OK orchestrator WSL error recorder started' -ForegroundColor Green
    }

    foreach ($pair in $remotePairs) {
        if ((Invoke-inferenceLogRemoteStart -SshTarget $pair.Ssh -RemoteRepo $pair.Repo `
                -HostLabel $pair.Label -SessionId $SessionId -LocalRepoRoot $RepoRoot) -ne 0) {
            Write-Host "  WARN: .$($pair.Label) error recorder did not start" -ForegroundColor Yellow
        } else {
            Write-Host "  OK .$($pair.Label) error recorder started" -ForegroundColor Green
        }
    }
}

function Invoke-inferenceLogFetchFromHosts {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Ssh100 = 'operator@orchestrator',
        [string]$Ssh248 = 'operator@orchestrator',
        [string]$Ssh111 = 'operator@hub',
        [string]$Ssh148 = 'operator@orchestrator',
        [string]$Repo100 = '/home/operator/alfa-ai',
        [string]$Repo248 = '/home/operator/alfa-ai',
        [string]$Repo148 = '/home/operator/alfa-ai',
        [string]$Repo111 = '/mnt/HDDs/Alfa-AI/repo/alfa-ai',
        [string]$Ip111 = 'hub'
    )

    $dest = Join-Path (Get-inferenceLogSessionRoot -RepoRoot $RepoRoot) $SessionId
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Write-Host "inference-log: fetching remote error logs -> $dest" -ForegroundColor Cyan

    $remotePairs = Get-inferenceLogRemoteHostPairs -RepoRoot $RepoRoot -Ssh100 $Ssh100 -Ssh248 $Ssh248 `
        -Ssh148 $Ssh148 -Repo100 $Repo100 -Repo248 $Repo248 -Repo148 $Repo148

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($pair in $remotePairs) {
            $remote = "$($pair.Repo)/logs/inference-sessions/$SessionId/inference-$($pair.Label)-errors.log"
            $local = Join-Path $dest "inference-$($pair.Label)-errors.log"
            $null = scp -o BatchMode=yes -o ConnectTimeout=15 "$($pair.Ssh):${remote}" $local 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $local)) {
                Write-Host "  OK inference-$($pair.Label)-errors.log" -ForegroundColor Green
            } else {
                if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue }
                Write-Host "  WARN missing inference-$($pair.Label)-errors.log on $($pair.Label)" -ForegroundColor Yellow
            }
        }

        $remote111 = "$Repo111/logs/inference-sessions/$SessionId/inference-111-errors.log"
        $local111 = Join-Path $dest 'inference-111-errors.log'
        $key111 = Get-inferenceSsh111KeyPath
        $remoteCmd = "cat ${remote111} 2>/dev/null || sudo -n cat ${remote111} 2>/dev/null"
        $content = ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key111 $Ssh111 $remoteCmd 2>&1
        if ($LASTEXITCODE -eq 0 -and $content -and ($content -join "`n").Trim().Length -gt 0) {
            ($content | ForEach-Object { $_.ToString() }) | Set-Content -LiteralPath $local111 -Encoding UTF8
            Write-Host '  OK inference-111-errors.log (direct from orchestrator)' -ForegroundColor Green
        } else {
            $metaLocal = Join-Path $dest 'inference-111-recorder.meta'
            $metaCmd = "cat ${Repo111}/logs/inference-sessions/${SessionId}/recorder-111.meta 2>/dev/null || true"
            $meta = ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key111 $Ssh111 $metaCmd 2>&1
            if ($meta) {
                ($meta | ForEach-Object { $_.ToString() }) | Set-Content -LiteralPath $metaLocal -Encoding UTF8
                Write-Host '  WARN inference-111-errors.log missing; saved recorder-111.meta' -ForegroundColor Yellow
            } else {
                Write-Host '  WARN missing inference-111-errors.log on 111' -ForegroundColor Yellow
            }
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Export-inferenceOrchestratorErrors {
    param(
        [Parameter(Mandatory)][string]$SessionDir,
        [string]$OrchestratorLogPath
    )
    $dest = Join-Path $SessionDir 'inference-93-orchestrator-errors.log'
    if (-not $OrchestratorLogPath -or -not (Test-Path -LiteralPath $OrchestratorLogPath)) {
        Set-Content -LiteralPath $dest -Value '(no orchestrator transcript)' -Encoding UTF8
        return
    }
    $pattern = 'ERROR|FAIL|WARN|Exception|failed|TerminatingError|throw|crash|RPC|wedge|OOM|503|502|504|unreachable|timeout'
    $hits = Select-String -Path $OrchestratorLogPath -Pattern $pattern -CaseSensitive:$false
    if ($hits) {
        $hits | ForEach-Object { $_.Line } | Set-Content -LiteralPath $dest -Encoding UTF8
    } else {
        Set-Content -LiteralPath $dest -Value '(no error lines in orchestrator transcript)' -Encoding UTF8
    }
}

function Import-inferenceLogSession {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [string]$OrchestratorLogPath,
        [string]$Ssh100 = 'operator@orchestrator',
        [string]$Ssh248 = 'operator@orchestrator',
        [string]$Ssh111 = 'operator@hub',
        [string]$Ssh148 = 'operator@orchestrator',
        [string]$Repo100 = '/home/operator/alfa-ai',
        [string]$Repo248 = '/home/operator/alfa-ai',
        [string]$Repo148 = '/home/operator/alfa-ai',
        [string]$Repo111 = '/mnt/HDDs/Alfa-AI/repo/alfa-ai',
        [string]$Ip111 = 'hub'
    )
    $sessionDir = Join-Path (Get-inferenceLogSessionRoot -RepoRoot $RepoRoot) $SessionId
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

    Export-inferenceOrchestratorErrors -SessionDir $sessionDir -OrchestratorLogPath $OrchestratorLogPath

    Invoke-inferenceLogFetchFromHosts -RepoRoot $RepoRoot -SessionId $SessionId `
        -Ssh100 $Ssh100 -Ssh248 $Ssh248 -Ssh111 $Ssh111 -Ssh148 $Ssh148 `
        -Repo100 $Repo100 -Repo248 $Repo248 -Repo148 $Repo148 `
        -Repo111 $Repo111 -Ip111 $Ip111
}

$script:inferenceReactorSignatures = @(
    [ordered]@{
        Name      = 'rpc-wedge'
        Pattern   = 'rpc wedge \(container|wedge \(containers Up|WARN wedge detected'
        Diagnosis = 'RPC accept-queue wedge (shard container Up but refusing TCP after the coordinator cold-load connects to it).'
        Reaction  = '[AUTO] Wedge auto-repair is already wired for orchestrator/hub/inference (Invoke-AlfaRepair93ShardIfWedged / Invoke-AlfaRepair111ShardIfWedged / inference equivalent). If this fires again after auto-repair ran, escalate per inference_START_FIX_PLAN.md (RPC wedge section).'
    }
    [ordered]@{
        Name      = 'stop-start-race'
        Pattern   = '(?i)\[docker-event\].*(grev27-pool|gpu3050|gpu3060|gpu5060).*\b(kill|die)\b'
        Diagnosis = 'A inference coordinator/shard container was explicitly killed (docker kill/die events) mid-session - not just slow/unresponsive. Most likely a previous "hub stop" (scripts/stop.sh --app-only, multi-stack, can take minutes) was still running when a new start-pool created containers with the same names, and its delayed inference-stop-local.sh loop killed them.'
        Reaction  = '[AUTO] Test-Alfa111NoStopInProgress now blocks a new start while operator-cluster-111.sh/inference-stop-local.sh/scripts/stop.sh is still running on hub (pgrep check in the "cluster must be stopped" preflight). [MANUAL] Operator: always wait for the hub stop terminal to return to a shell prompt before starting a new cycle - see inference_START_FIX_PLAN.md Section 7.'
    }
    [ordered]@{
        Name      = 'hub-enosys'
        Pattern   = 'Function not implemented'
        Diagnosis = 'hub SCALE sudo-rs returned ENOSYS on a coreutils call (mkdir/dirname/etc.) not yet guarded.'
        Reaction  = '[MANUAL] Find the failing command in the surrounding log line and add a inference_ensure_dir-style guard (B17/B20 pattern) in deploy/cluster-members/_common/inference-log-helpers.sh.'
    }
    [ordered]@{
        Name      = 'start-pool-race'
        Pattern   = 'start-pool has not finished locally yet'
        Diagnosis = 'Operator pressed Enter on orchestrator before hub start-pool finished its local coordinator health wait (timing race).'
        Reaction  = '[AUTO] B19 sentinel check already caught this and failed fast (~1s) instead of a blind 900s wait. [MANUAL] Operator: wait for hub to print "G-rev27 pool coordinator OK" and return to a shell prompt before pressing Enter on orchestrator (inference_START_FIX_PLAN.md A8).'
    }
    [ordered]@{
        Name      = 'coordinator-unhealthy'
        Pattern   = '(coordinator.*(not healthy|Unable to connect))|(Unable to connect.*31360)'
        Diagnosis = 'Coordinator on hub:31360 never answered /health within the poll window.'
        Reaction  = '[MANUAL] Check "[coord diag]" lines in the orchestrator orchestrator transcript (B21, every ~120s) for container status/last log lines to tell a slow cold-load apart from a crash loop. Cross-check docs/GREV27_27B_OPERATOR.md troubleshooting table.'
    }
    [ordered]@{
        Name      = 'recorder-killed-early'
        Pattern   = '(?m)^(at|host):\s*$'
        Diagnosis = 'hub recorder produced a blank date/hostname and stopped after ~1 probe cycle - consistent with systemd-logind KillUserProcesses=yes killing the nohup''d background recorder when its sudo/SSH session scope ended. nohup does not protect against this (official: https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html).'
        Reaction  = '[AUTO after B22] start-inference-log-session.sh now launches the recorder via systemd-run as a root system-scope unit, independent of the login session. If this signature reappears, confirm systemd-run exists on hub (command -v systemd-run) and that recorder-111.mode reads "systemd-run".'
    }
    [ordered]@{
        Name      = 'coordinator-killed-by-wedge-repair'
        Pattern   = 'No such container: llamacpp-server-\d+-grev27-pool'
        Diagnosis = 'The hub RTX 3050 wedge-repair redeploy ran inference-stop-local.sh in "full" mode instead of "shard" mode and killed the coordinator too. Root cause: VAR=value set before `sudo` on hub is stripped by sudo env_reset (official sudo(8) default) unless the VAR=value pairs are passed as arguments to sudo itself (after `sudo`, before the command).'
        Reaction  = '[AUTO after B34] deploy-grev27-pool-shard.sh / operator-cluster-111.sh / stop-rag-sidecars.sh call sites now use `sudo VAR=value bash script.sh` (vars after sudo) so inference_STOP_MODE=shard and HOST_LABEL survive; inference-stop-local.sh in shard mode never touches llamacpp-server-*-grev27-pool. If this signature reappears, grep the touched script for `=\S+ sudo ` (VAR before sudo) and move it after sudo.'
    }
    [ordered]@{
        Name      = 'operator-abort'
        Pattern   = 'pipeline has been stopped'
        Diagnosis = 'Operator aborted the PowerShell prompt (Ctrl+C) mid-step.'
        Reaction  = '[INFO] Not a bug - no code action needed.'
    }
    [ordered]@{
        Name      = 'sudo-password-required-111'
        Pattern   = 'sudo: a (terminal is required|password is required)'
        Diagnosis = 'operator on hub does not have passwordless sudo (hub SCALE "Sudo Commands" without the "no password" flag), so a non-interactive double-hop SSH sudo call always fails.'
        Reaction  = '[AUTO] Legacy hub RAG stop and hub wedge auto-repair already catch this and WARN instead of crashing the cluster start/stop (A11). [MANUAL] Operator: grant operator sudo_commands_nopasswd for the specific alfa-ai scripts on hub (hub UI: Credentials > operator > edit > Sudo Commands with no password) to enable full automation, or run the named script interactively on hub when this warning appears.'
    }
)

function Invoke-inferenceErrorReactor {
    <#
    .SYNOPSIS
        Scan a collected inference session's error logs for known recurring failure
        signatures and print/save an automatic diagnosis + reaction for each hit.
        This is the "auto-reactor": it turns a manual, from-scratch audit of
        repeated problem areas into an automatic classification step that runs
        after every collected session (pass or fail).
    #>
    param(
        [Parameter(Mandatory)][string]$SessionDir
    )
    if (-not (Test-Path -LiteralPath $SessionDir)) { return }

    $logFiles = Get-ChildItem -LiteralPath $SessionDir -Filter '*.log' -File -ErrorAction SilentlyContinue
    if (-not $logFiles) { return }

    $combined = ($logFiles | ForEach-Object {
            "----- $($_.Name) -----`n" + (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue)
        }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($combined)) { return }

    $hits = @()
    foreach ($sig in $script:inferenceReactorSignatures) {
        if ($combined -match $sig.Pattern) {
            $hits += $sig
        }
    }

    $summaryPath = Join-Path $SessionDir 'inference-reactor-summary.txt'
    if (-not $hits) {
        Set-Content -LiteralPath $summaryPath -Value '(no known recurring failure signatures matched this session)' -Encoding UTF8
        return
    }

    Write-Host ''
    Write-Host '================== inference auto-reactor ==================' -ForegroundColor Magenta
    $lines = @()
    foreach ($hit in $hits) {
        $block = @(
            "[$($hit.Name)]"
            "  Diagnosis: $($hit.Diagnosis)"
            "  Reaction:  $($hit.Reaction)"
        )
        $lines += $block
        $block | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    }
    Write-Host '===========================================================' -ForegroundColor Magenta
    Set-Content -LiteralPath $summaryPath -Value $lines -Encoding UTF8
    Write-Host "inference-log: reactor summary -> $summaryPath" -ForegroundColor Cyan
}

function Stop-inferenceLogSession {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$SessionId,
        [string]$OrchestratorLogPath,
        [string]$Ssh100 = 'operator@orchestrator',
        [string]$Ssh248 = 'operator@orchestrator',
        [string]$Ssh111 = 'operator@hub',
        [string]$Ssh148 = 'operator@orchestrator',
        [string]$Repo100 = '/home/operator/alfa-ai',
        [string]$Repo248 = '/home/operator/alfa-ai',
        [string]$Repo148 = '/home/operator/alfa-ai',
        [string]$Repo111 = '/mnt/HDDs/Alfa-AI/repo/alfa-ai',
        [string]$Ip111 = 'hub'
    )
    if (-not $SessionId) {
        $SessionId = Get-inferenceLogSessionId -RepoRoot $RepoRoot
    }
    if (-not $SessionId) {
        Write-Host 'inference-log: no active session to collect' -ForegroundColor DarkGray
        return
    }

    Write-Host "inference-log: stopping error recorders session=$SessionId" -ForegroundColor Cyan

    $remotePairs = Get-inferenceLogRemoteHostPairs -RepoRoot $RepoRoot -Ssh100 $Ssh100 -Ssh248 $Ssh248 `
        -Ssh148 $Ssh148 -Repo100 $Repo100 -Repo248 $Repo248 -Repo148 $Repo148
    foreach ($pair in $remotePairs) {
        $null = Invoke-inferenceLogRemoteStop -SshTarget $pair.Ssh -RemoteRepo $pair.Repo `
            -HostLabel $pair.Label -SessionId $SessionId -LocalRepoRoot $RepoRoot
    }

    $stop111 = Join-inferenceRemoteScript -RepoBase $Repo111 -RelativePath 'deploy/cluster-members/_common/stop-inference-log-session.sh'
    $remote111 = "test -f ${stop111} && inference_LOG_SESSION_ID=${SessionId} HOST_LABEL=111 bash ${stop111} || true"
    $null = Invoke-inferenceLogSsh -SshTarget $Ssh111 -RemoteCommand $remote111.Trim() `
        -ConnectTimeoutSec 25 -IdentityFile (Get-inferenceSsh111KeyPath)

    $drive = $RepoRoot.Substring(0, 1).ToLower()
    $wslRepo = "/mnt/$drive/" + ($RepoRoot.Substring(3) -replace '\\', '/')
    $wslStop = "$wslRepo/deploy/cluster-members/_common/stop-inference-log-session.sh"
    $null = Invoke-inferenceLogWsl -Command "test -f '$wslStop' && inference_LOG_SESSION_ID='$SessionId' HOST_LABEL=93 bash '$wslStop'"

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Import-inferenceLogSession -RepoRoot $RepoRoot -SessionId $SessionId -OrchestratorLogPath $OrchestratorLogPath `
            -Ssh100 $Ssh100 -Ssh248 $Ssh248 -Ssh111 $Ssh111 -Ssh148 $Ssh148 `
            -Repo100 $Repo100 -Repo248 $Repo248 -Repo148 $Repo148 `
            -Repo111 $Repo111 -Ip111 $Ip111
    } finally {
        $ErrorActionPreference = $prev
    }

    $sessionDir = Join-Path (Get-inferenceLogSessionRoot -RepoRoot $RepoRoot) $SessionId
    Write-Host "inference-log: error analysis dir -> $sessionDir" -ForegroundColor Green

    try {
        Invoke-inferenceErrorReactor -SessionDir $sessionDir
    } catch {
        Write-Host "inference-log: reactor classification skipped ($($_.Exception.Message))" -ForegroundColor DarkGray
    }
}