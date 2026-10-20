#Requires -Version 5.1
<#
.SYNOPSIS
    Start or stop the ALFa AI cluster from orchestrator (orchestrator).

.DESCRIPTION
    Runs autonomous steps on orchestrator (local), inference (hub), pool-opt-in, secondary, and hub (direct SSH from orchestrator).
    hub subcommands run automatically when operator sudo_commands_nopasswd is granted
    (see docs/POOL_SWITCH_OPERATOR.md A11). Live-streamed output; no manual paste blocks.

    Start order:
      0. Opt-in prompt (gaming-a/gaming-c/gaming-b/secondary/pool-opt-in for inference; same mesh for Pool72/80)
         -> inference-shards.active.env (first)
      0b. Required-host TCP :22 (inference/hub/rag always; opted-in shards) -- fail fast
      0c. Cluster-must-be-stopped port checks (before STEP 0)
      0d. Local Docker/WSL + Hyper-V firewall for orchestrator :31350 (before STEP 0)
      1. STEP 0 error capture
      2. Preflight (repo, SSH BatchMode, git sync remotes)
      2b. Ask ALFa host-actions key on hub (scp from orchestrator seed if missing)
      2c. RPC image deps (hub tarball or loaded image per opted-in host; fail-fast)
      3. Sync active shard list; pool shards on orchestrator/inference + opted-in hosts
      4. hub start-pool / start-pool72 (CPU coordinator :31360)
      5. Verify coordinator + decode self-test; RAG on rag; then start-brain
         (host-actions key re-checked after start-brain)
      6. Verify pool + RAG + inference edge + post-start HTTP + monitor bearer refresh + hub keep-warm

    Stop order:
      1. Preflight (secondary optional when already unreachable -- stop proceeds on other hosts)
      2. hub stop (brain --app-only + inference + hub RAG sidecars via operator-cluster-111.sh)
      3. inference-stop on inference, orchestrator, gpu-248 (:31355), opted-in gaming hosts, VM100 shard (:31354)
      4. RAG stop on rag CPU embed/rerank + inference/pool-opt-in legacy
      5. Post-stop verify (pool RPC + RAG ports closed). inference edge and apps DB stacks stay up.

    Gaming hosts cannot hot-join or hot-leave a green pool (llama.cpp RPC backends are
    fixed at coordinator start). Leave for gaming = full stop, then start without that host.

.PARAMETER Action
    Start or Stop.

.PARAMETER SkipPull
    Skip git pull on orchestrator and remote hosts.

.PARAMETER SkipEdge
    For start: skip bringing up the inference edge proxy.
    For stop: down of the edge is intentionally disabled (edge and DB stacks are protected infra).
    Passing this has no additional effect on stop.

.PARAMETER SkipVerify
    Skip post-start HTTP checks and post-stop TCP checks.

.PARAMETER InferenceMode
    inference (default production Qwen3.8-27B Q8), inference_38 (legacy alias, same as
    inference), Pool72 (exclusive Qwen2.5-72B Q5), or Pool80 (exclusive
    Qwen3-Coder-Next Q5). Pool72/Pool80 require full-mesh opt-in hosts.
    See docs/GREV27_27B_OPERATOR.md, docs/GREV72_72B_OPERATOR.md
    and docs/GREV80_80B_OPERATOR.md.

.EXAMPLE
    cd C:/Users/operator\alfa-ai
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaAiCluster.ps1 -Action Start

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaAiCluster.ps1 -Action Stop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Stop')]
    [string]$Action,

    [switch]$SkipPull,
    [switch]$SkipEdge,
    [switch]$SkipVerify,

    [ValidateSet('Ask', 'Flags', 'Last', 'None')]
    [string]$GamingMode = 'Ask',
    [switch]$Include59,
    [switch]$Include219,
    [switch]$Include249,
    [switch]$Include248,
    [switch]$Include100,

    [ValidateSet('inference', 'inference_38', 'Pool72', 'Pool80')]
    [string]$InferenceMode = 'inference',

    [int]$CtxSize = 0,
    [int]$ParallelSlots = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AlfaGuiCtxSize = $CtxSize
$script:AlfaGuiParallelSlots = $ParallelSlots

$MemberDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $MemberDir '..\..\..')).Path
$CommonDir = Join-Path $RepoRoot 'deploy\cluster-members\_common'
$LlcDir = Join-Path $RepoRoot 'deploy\llamacpp-rpc'

. (Join-Path $CommonDir 'logging-helpers.ps1')
. (Join-Path $CommonDir 'Invoke-AlfaWslBash.ps1')
. (Join-Path $CommonDir 'Wait-AlfaHttpPoll.ps1')
. (Join-Path $MemberDir 'inference-LogSession.ps1')
. (Join-Path $MemberDir 'Resolve-AlfainferenceActiveShards.ps1')

Reset-AlfaPhaseTimings

$edgeLogin = if ($env:ALFA_EDGE__LOGIN_URL) {
    $env:ALFA_EDGE__LOGIN_URL
} else {
    # ai-148  node (bound 2026-07-05). Was 100.79.90.77 (apps "web-sites"),
    # stale since the edge proxy moved to inference in the Jul 2026 hub migration.
    'http://100.112.43.57:8420/alfa-ai/login'
}

# Hosts unreachable during stop preflight (e.g. gpu-248 powered off). Stop skips them.
$script:AlfaUnreachableStopHosts = New-Object System.Collections.Generic.List[string]

$script:AlfaCfg = @{
    RepoRoot   = $RepoRoot
    Ssh100     = 'operator@orchestrator'
    Ssh248     = 'operator@orchestrator'
    Ssh105     = 'operator@apps'
    Ssh148     = 'operator@orchestrator'
    Ssh110     = 'operator@orchestrator'
    # Cluster hub (Jul 2026): verify inference, edge proxy - was apps.
    SshHub     = 'operator@orchestrator'
    Ssh111     = 'operator@hub'
    RepoHub    = '/home/operator/alfa-ai'
    Repo100    = '/home/operator/alfa-ai'
    Repo248    = '/home/operator/alfa-ai'
    RepoContracts105 = '/home/operator/contracts-bot'
    Repo148    = '/home/operator/alfa-ai'
    Repo110    = '/home/operator/alfa-ai'
    Repo111    = '/mnt/HDDs/Alfa-AI/repo/alfa-ai'
    Ip100      = 'orchestrator'
    Ip248      = 'orchestrator'
    Ip111      = 'hub'
    Ip105      = 'apps'
    Ip148      = 'orchestrator'
    Ip110      = 'orchestrator'
    Ip107      = 'monitor'
    Ssh107     = 'operator@monitor'
    Ip219      = 'orchestrator'
    Ip59       = 'orchestrator'
    Ip249      = 'orchestrator'
    IpHub      = 'orchestrator'
    # Data-plane NICs (RAG sidecar client URLs; mgmt IPs for SSH/RPC unchanged)
    Ip105Data  = 'orchestrator'
    Ip148Data  = 'orchestrator'
    #  admin login via edge on inference; override with ALFA_EDGE__LOGIN_URL.
    LoginUrl = $edgeLogin
    # Active list written at start (gitignored). Fallback = committed core-only inference-shards.env.
    ShardsFile = Join-Path $LlcDir 'inference-shards.active.env'
    ShardsFileFallback = Join-Path $LlcDir 'inference-shards.env'
    Ssh219     = if ($env:inference_SSH_219_TARGET) { $env:inference_SSH_219_TARGET } else { 'Corey@orchestrator' }
    Repo219Win = if ($env:inference_REPO_219_WIN) { $env:inference_REPO_219_WIN } else { 'C:\Users\Corey\alfa-ai' }
    Ssh59      = if ($env:inference_SSH_59_TARGET) { $env:inference_SSH_59_TARGET } else { 'Colin@orchestrator' }
    Repo59Win  = if ($env:inference_REPO_59_WIN) { $env:inference_REPO_59_WIN } else { 'C:\Users\Colin\alfa-ai' }
    Ssh249     = if ($env:inference_SSH_249_TARGET) { $env:inference_SSH_249_TARGET } else { 'cody@orchestrator' }
    Repo249Win = if ($env:inference_REPO_249_WIN) { $env:inference_REPO_249_WIN } else { 'C:\Users\cody\alfa-ai' }
}

$script:AlfaGamingSelection = $null

function Get-AlfainferenceShardsFileForOps {
    if (Test-Path -LiteralPath $script:AlfaCfg.ShardsFile) {
        return $script:AlfaCfg.ShardsFile
    }
    return $script:AlfaCfg.ShardsFileFallback
}

function Join-AlfaRemoteScript {
    param(
        [Parameter(Mandatory)][string]$RepoBase,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $rel = ($RelativePath -replace '\\', '/').TrimStart('/')
    return "$RepoBase/$rel"
}

$LogPath = Get-AlfaWorkerLogPath -RepoRoot $RepoRoot -MemberFolder 'operator-93' -Prefix "cluster-$($Action.ToLower())"
Start-AlfaWorkerTranscript -Path $LogPath

function Get-AlfaWsl93EnvPrefix {
    param([string]$Extra = '')
    # WSL default $HOME/alfa-ai does not exist on orchestrator; inference-stop-local needs compose paths.
    $repoWsl = ConvertTo-AlfaWslWinPath -WinPath $script:AlfaCfg.RepoRoot
    $prefix = "HOST_LABEL=93 ALFA_AI_REPO=$repoWsl"
    if ($Extra) {
        $prefix = "$prefix $Extra"
    }
    return "$prefix "
}

$script:inferenceLogSessionId = $null
$script:AlfaStepLedger = New-Object System.Collections.Generic.List[object]

function Add-AlfaStepLedgerEntry {
    param(
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$StartedAt,
        [Parameter(Mandatory)][string]$EndedAt,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Result,
        [string[]]$LastOutputLines = @()
    )
    $entry = [pscustomobject]@{
        Host            = $HostLabel
        Phase           = $Phase
        Command         = $Command
        StartedAt       = $StartedAt
        EndedAt         = $EndedAt
        ExitCode        = [int]$ExitCode
        Result          = $Result
        LastOutputLines = [string[]]@($LastOutputLines | ForEach-Object {
                if ($null -eq $_) { return '' }
                $_.ToString()
            })
    }
    $script:AlfaStepLedger.Add($entry) | Out-Null
}

function Write-AlfaStepLedger {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$SessionId
    )
    if ($script:AlfaStepLedger.Count -eq 0) {
        return
    }
    if (-not $SessionId) {
        $SessionId = Get-inferenceLogSessionId -RepoRoot $RepoRoot
    }
    if (-not $SessionId) {
        Write-AlfaLog -Level WARN -Message 'step ledger skipped (no inference session id)'
        return
    }
    $dir = Join-Path $RepoRoot ("logs\inference-sessions\$SessionId")
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $path = Join-Path $dir 'step-ledger.json'
    $stepArray = @()
    foreach ($entry in $script:AlfaStepLedger) {
        $stepArray += $entry
    }
    $payload = @{
        sessionId = $SessionId
        writtenAt = (Get-Date).ToUniversalTime().ToString('o')
        steps     = $stepArray
    }
    $json = $payload | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $path -Value $json -Encoding ASCII
    Write-AlfaLog -Level INFO -Message ("step ledger: logs\inference-sessions\$SessionId\step-ledger.json")
}

function Get-inferenceSsh110KeyPath {
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_110'
    if (-not (Test-Path -LiteralPath $key)) {
        throw "Missing rag SSH key: $key (run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).)"
    }
    return $key
}

function Get-inferenceSsh219KeyPath {
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_219'
    if (-not (Test-Path -LiteralPath $key)) {
        throw "Missing gaming-a SSH key: $key (run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).)"
    }
    return $key
}

function Get-inferenceSsh59KeyPath {
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_59'
    if (-not (Test-Path -LiteralPath $key)) {
        throw "Missing gaming-c SSH key: $key (run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).)"
    }
    return $key
}

function Get-inferenceSsh249KeyPath {
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519_93_249'
    if (-not (Test-Path -LiteralPath $key)) {
        throw "Missing gaming-b SSH key: $key (run Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).)"
    }
    return $key
}

function Test-AlfainferenceShardListed {
    param(
        [Parameter(Mandatory)][string]$HostIp,
        [Parameter(Mandatory)][int]$Port
    )
    $shardsFile = Get-AlfainferenceShardsFileForOps
    if (-not (Test-Path -LiteralPath $shardsFile)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $shardsFile) {
        $trim = ($line -replace '#.*$', '').Trim()
        if (-not $trim) { continue }
        $parts = $trim -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -eq $HostIp -and [int]$parts[1] -eq $Port) {
            return $true
        }
    }
    return $false
}

function Invoke-AlfaResolveGamingShardsForStart {
    # Runs first on Start (before host reachability / error capture / preflight).
    $shardProfile = if ($InferenceMode -eq 'Pool72') { 'Pool72' } elseif ($InferenceMode -eq 'Pool80') { 'Pool80' } else { 'inference' }
    Start-AlfaPhase ("Gaming-host opt-in ({0} membership for this start)" -f $shardProfile)
    $resolved = Resolve-AlfainferenceActiveShards -LlcDir $LlcDir -Mode $GamingMode `
        -ShardProfile $shardProfile `
        -Include59:([bool]$Include59) -Include219:([bool]$Include219) `
        -Include249:([bool]$Include249) -Include248:([bool]$Include248) `
        -Include100:([bool]$Include100)
    $script:AlfaGamingSelection = $resolved
    $script:AlfaCfg.ShardsFile = $resolved.ActivePath
    Write-AlfaLog -Level OK -Message ("Active shards ({0}): {1} -> {2}" -f $shardProfile, $resolved.Summary, $resolved.ActivePath)
    Stop-AlfaPhase
    return $resolved
}

function Invoke-AlfaPreflightRequiredHostsEarly {
    <#
    .SYNOPSIS
        Fail-fast TCP :22 for every host required by this start (before STEP 0).
    .NOTES
        Uses Test-NetConnection (Microsoft.PowerShell.Management). Collects all
        failures so the operator sees every down host in one throw.
        https://learn.microsoft.com/en-us/powershell/module/nettcpip/test-netconnection
    #>
    Start-AlfaPhase 'Preflight (required hosts reachable)'
    $failed = New-Object System.Collections.Generic.List[string]

    function Test-AlfaRequiredHostTcp22 {
        param(
            [Parameter(Mandatory)][string]$HostName,
            [Parameter(Mandatory)][string]$Label
        )
        Write-AlfaLog -Level INFO -Message ("TCP check: {0}:22 ({1})" -f $HostName, $Label)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $r = Test-NetConnection -ComputerName $HostName -Port 22 -WarningAction SilentlyContinue
            if ($r -and $r.TcpTestSucceeded) {
                Write-AlfaLog -Level OK -Message ("TCP OK: {0} ({1}:22)" -f $Label, $HostName)
                return
            }
        } catch {
            Write-AlfaLog -Level WARN -Message ("TCP check exception: {0}: {1}" -f $Label, $_.Exception.Message)
        } finally {
            $ErrorActionPreference = $prevEap
        }
        Write-AlfaLog -Level ERROR -Message ("TCP FAIL: {0} ({1}:22)" -f $Label, $HostName)
        [void]$failed.Add(('{0} ({1}:22)' -f $Label, $HostName))
    }

    try {
        Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip148 -Label 'inference SSH (hub)'
        Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip111 -Label 'hub SSH (operator host)'
        # RAG sidecars are mandatory on every start (embed+rerank on rag).
        Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip110 -Label 'rag SSH (RAG CPU)'

        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354) {
            Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip100 -Label 'pool-opt-in SSH (opted-in shard)'
        } else {
            Write-AlfaLog -Level INFO -Message 'pool-opt-in not in active shard list -- skip early host check'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355) {
            Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip248 -Label 'secondary SSH (gpu-248 opted-in)'
        } else {
            Write-AlfaLog -Level INFO -Message 'secondary not in active shard list -- skip early host check'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip219 -Port 31352) {
            Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip219 -Label 'gaming-a SSH (opted-in gaming)'
        } else {
            Write-AlfaLog -Level INFO -Message 'gaming-a not in active shard list -- skip early host check'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip59 -Port 31351) {
            Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip59 -Label 'gaming-c SSH (opted-in gaming)'
        } else {
            Write-AlfaLog -Level INFO -Message 'gaming-c not in active shard list -- skip early host check'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip249 -Port 31358) {
            Test-AlfaRequiredHostTcp22 -HostName $script:AlfaCfg.Ip249 -Label 'gaming-b SSH (opted-in gaming)'
        } else {
            Write-AlfaLog -Level INFO -Message 'gaming-b not in active shard list -- skip early host check'
        }

        if ($failed.Count -gt 0) {
            $list = ($failed | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine
            throw @(
                'Required host(s) unreachable before start (fail-fast; STEP 0 not started):',
                $list,
                'Power on / fix network+SSH, or re-run start without that host (answer N / omit -Include*).'
            ) -join [Environment]::NewLine
        }

        Write-AlfaLog -Level OK -Message 'All required hosts reachable on TCP :22'
        Stop-AlfaPhase
    } catch {
        Stop-AlfaPhase -Result FAIL
        throw
    }
}

function Invoke-AlfaPreflightLocalEarly {
    <#
    .SYNOPSIS
        Docker/WSL + Hyper-V firewall checks on orchestrator before STEP 0.
    #>
    Start-AlfaPhase 'Preflight (local Docker + firewall)'
    try {
        Start-AlfaPhase 'Docker preflight (orchestrator WSL)'
        Invoke-AlfaWslBashScript -ScriptPath (Join-Path $CommonDir 'preflight-docker-engine.sh') -EnvPrefix (Get-AlfaWsl93EnvPrefix)
        Stop-AlfaPhase

        Test-AlfainferenceFirewallPreflight

        Write-AlfaLog -Level OK -Message 'Local Docker/WSL and Hyper-V firewall OK'
        Stop-AlfaPhase
    } catch {
        Stop-AlfaPhase -Result FAIL
        throw
    }
}

function Invoke-AlfaWaitGamingShardsOperatorReady {
    param([Parameter(Mandatory)]$GamingSelection)
    if (-not $GamingSelection) { return }
    # gaming-a / gaming-c / gaming-b / secondary SSH-deploy from orchestrator when opted in; no local Read-Host wait.
    return
}

function Invoke-AlfaPreflightRpcImageDepsOnRemoteWindows {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$RepoWin,
        [Parameter(Mandatory)][scriptblock]$InvokeSsh,
        [Parameter(Mandatory)][bool]$ForceHubLoad
    )
    $localScript = Join-Path $CommonDir 'Test-AlfaRpcImageDepsPreflight.ps1'
    if (-not (Test-Path -LiteralPath $localScript)) {
        throw "Missing RPC deps preflight script: $localScript"
    }
    # User Local\Temp -- C:\Windows\Temp is often not writable for non-Admin SSH.
    $userHome = Split-Path -Parent $RepoWin
    $remotePathWin = Join-Path $userHome 'AppData\Local\Temp\alfa-rpc-image-deps-preflight.ps1'
    $remotePathScp = ($remotePathWin -replace '\\', '/')
    Write-AlfaLog -Level CMD -Message ("scp RPC deps preflight -> {0} ({1})" -f $Label, $remotePathScp)
    & scp.exe -o BatchMode=yes -o ConnectTimeout=20 -i $KeyPath $localScript "${SshTarget}:${remotePathScp}"
    if ($LASTEXITCODE -ne 0) {
        throw ("scp RPC deps preflight to $Label failed (exit $LASTEXITCODE)")
    }
    $forceSwitch = ''
    if ($ForceHubLoad) { $forceSwitch = '-ForceHubLoad' }
    $remoteCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$remotePathWin`" -Label $Label $forceSwitch"
    & $InvokeSsh $remoteCmd $Label
}

function Invoke-AlfaPreflightStartDependencies {
    <#
    .SYNOPSIS
        Fail-fast before shard deploy: each opted-in host must have RPC image or hub tarball.
    .NOTES
        Pool80 sets FORCE_HUB_RPC_LOAD=1 (tarball required on every shard host).
        Paths match deploy-llamacpp-rpc.ps1 and preflight-rpc-image-deps.sh.
    #>
    $forceHubLoad = ($InferenceMode -eq 'Pool80')
    if ($forceHubLoad) {
        Write-AlfaLog -Level INFO -Message ("{0}: RPC deps preflight requires hub tarball on every shard (FORCE_HUB_RPC_LOAD=1)" -f $InferenceMode)
    }
    Start-AlfaPhase 'Preflight (RPC image dependencies)'
    $failures = New-Object System.Collections.Generic.List[string]
    try {
        $localPfScript = Join-Path $CommonDir 'Test-AlfaRpcImageDepsPreflight.ps1'
        $bashRel = 'deploy/cluster-members/_common/preflight-rpc-image-deps.sh'

        function Add-AlfaRpcDepsFailure {
            param(
                [Parameter(Mandatory)][string]$HostLabel,
                [Parameter(Mandatory)][string]$Message
            )
            Write-AlfaLog -Level ERROR -Message ("RPC deps FAIL: {0}" -f $HostLabel)
            [void]$failures.Add(('{0}:{1}{2}' -f $HostLabel, [Environment]::NewLine, $Message))
        }

        $pf93Args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $localPfScript,
            '-Label', 'orchestrator'
        )
        if ($forceHubLoad) { $pf93Args += '-ForceHubLoad' }
        $prevPf = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $pf93Out = & powershell.exe @pf93Args 2>&1 | Out-String
        $pf93Ec = $LASTEXITCODE
        $ErrorActionPreference = $prevPf
        if ($pf93Ec -eq 0) {
            if ($pf93Out) { Write-AlfaLog -Level INFO -Message $pf93Out.Trim() }
            Write-AlfaLog -Level OK -Message 'orchestrator RPC image/tarball OK'
        } else {
            Add-AlfaRpcDepsFailure -HostLabel 'orchestrator' -Message $pf93Out.Trim()
        }

        function Invoke-AlfaLinuxRpcDepsCheck {
            param(
                [Parameter(Mandatory)][string]$HostLabel,
                [Parameter(Mandatory)][string]$SshTarget,
                [Parameter(Mandatory)][string]$RepoPath,
                [switch]$Pascal
            )
            $argParts = @()
            if ($forceHubLoad) { $argParts += '--force-hub-load' }
            if ($Pascal) { $argParts += '--pascal' }
            $argStr = ($argParts -join ' ').Trim()
            $remote = "bash $(Join-AlfaRemoteScript $RepoPath $bashRel)"
            if ($argStr) { $remote += " $argStr" }
            try {
                Invoke-AlfaRemoteSsh -Target $SshTarget -RemoteCommand $remote -Label ("$HostLabel RPC deps preflight")
                Write-AlfaLog -Level OK -Message ("{0} RPC image/tarball OK" -f $HostLabel)
            } catch {
                Add-AlfaRpcDepsFailure -HostLabel $HostLabel -Message $_.Exception.Message
            }
        }

        Invoke-AlfaLinuxRpcDepsCheck -HostLabel 'inference' -SshTarget $script:AlfaCfg.Ssh148 -RepoPath $script:AlfaCfg.Repo148

        $arg111 = ''
        if ($forceHubLoad) { $arg111 = ' --force-hub-load' }
        $cmd111 = "bash $($script:AlfaCfg.Repo111)/deploy/cluster-members/_common/preflight-rpc-image-deps.sh$arg111"
        try {
            Invoke-AlfaRemote111Raw -InnerBashCommand $cmd111 -Label 'hub RPC deps preflight'
            Write-AlfaLog -Level OK -Message 'hub RPC image/tarball OK'
        } catch {
            Add-AlfaRpcDepsFailure -HostLabel 'hub' -Message $_.Exception.Message
        }

        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355) {
            Invoke-AlfaLinuxRpcDepsCheck -HostLabel 'secondary' -SshTarget $script:AlfaCfg.Ssh248 `
                -RepoPath $script:AlfaCfg.Repo248 -Pascal
        } else {
            Write-AlfaLog -Level INFO -Message 'secondary not in active shard list -- skip RPC deps preflight'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354) {
            Invoke-AlfaLinuxRpcDepsCheck -HostLabel 'pool-opt-in' -SshTarget $script:AlfaCfg.Ssh100 `
                -RepoPath $script:AlfaCfg.Repo100
        } else {
            Write-AlfaLog -Level INFO -Message 'pool-opt-in not in active shard list -- skip RPC deps preflight'
        }

        function Invoke-AlfaWindowsRpcDepsCheck {
            param(
                [Parameter(Mandatory)][string]$HostLabel,
                [Parameter(Mandatory)][string]$SshTarget,
                [Parameter(Mandatory)][string]$KeyPath,
                [Parameter(Mandatory)][string]$RepoWin,
                [Parameter(Mandatory)][scriptblock]$InvokeSsh
            )
            try {
                Invoke-AlfaPreflightRpcImageDepsOnRemoteWindows -Label $HostLabel -SshTarget $SshTarget `
                    -KeyPath $KeyPath -RepoWin $RepoWin -InvokeSsh $InvokeSsh -ForceHubLoad $forceHubLoad
                Write-AlfaLog -Level OK -Message ("{0} RPC image/tarball OK" -f $HostLabel)
            } catch {
                Add-AlfaRpcDepsFailure -HostLabel $HostLabel -Message $_.Exception.Message
            }
        }

        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip219 -Port 31352) {
            Invoke-AlfaWindowsRpcDepsCheck -HostLabel 'gaming-a' -SshTarget $script:AlfaCfg.Ssh219 `
                -KeyPath (Get-inferenceSsh219KeyPath) -RepoWin $script:AlfaCfg.Repo219Win -InvokeSsh {
                    param($cmd, $lbl)
                    Invoke-AlfaRemote219Ssh -RemoteCommand $cmd -Label $lbl
                }
        } else {
            Write-AlfaLog -Level INFO -Message 'gaming-a not in active shard list -- skip RPC deps preflight'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip59 -Port 31351) {
            Invoke-AlfaWindowsRpcDepsCheck -HostLabel 'gaming-c' -SshTarget $script:AlfaCfg.Ssh59 `
                -KeyPath (Get-inferenceSsh59KeyPath) -RepoWin $script:AlfaCfg.Repo59Win -InvokeSsh {
                    param($cmd, $lbl)
                    Invoke-AlfaRemote59Ssh -RemoteCommand $cmd -Label $lbl
                }
        } else {
            Write-AlfaLog -Level INFO -Message 'gaming-c not in active shard list -- skip RPC deps preflight'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip249 -Port 31358) {
            Invoke-AlfaWindowsRpcDepsCheck -HostLabel 'gaming-b' -SshTarget $script:AlfaCfg.Ssh249 `
                -KeyPath (Get-inferenceSsh249KeyPath) -RepoWin $script:AlfaCfg.Repo249Win -InvokeSsh {
                    param($cmd, $lbl)
                    Invoke-AlfaRemote249Ssh -RemoteCommand $cmd -Label $lbl
                }
        } else {
            Write-AlfaLog -Level INFO -Message 'gaming-b not in active shard list -- skip RPC deps preflight'
        }

        if ($failures.Count -gt 0) {
            $body = ($failures | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine
            throw @(
                'RPC image dependency preflight failed (fail-fast before shard deploy):',
                $body,
                'Fix every host above (hub tarball or Prep-GamingHostinferenceReady.ps1 -LoadImage), then re-run start.',
                'Pool80: alfa-llamacpp-rpc-cuda128-b10355.tar.gz on hub + each worker; secondary pascal twin if opted in.'
            ) -join [Environment]::NewLine
        }

        Write-AlfaLog -Level OK -Message 'All required RPC image dependencies present'
        Stop-AlfaPhase
    } catch {
        Stop-AlfaPhase -Result FAIL
        throw
    }
}

function Sync-AlfainferenceActiveShardsToRemotes {
    param([Parameter(Mandatory)][string]$LocalActivePath)
    if (-not (Test-Path -LiteralPath $LocalActivePath)) {
        throw "Missing active shard list: $LocalActivePath"
    }
    $rel = 'deploy/llamacpp-rpc/inference-shards.active.env'
    $remote148 = "$($script:AlfaCfg.Repo148)/$rel"
    $remote111 = "$($script:AlfaCfg.Repo111)/$rel"
    $remoteHub = "$($script:AlfaCfg.RepoHub)/$rel"

    Start-AlfaPhase 'Sync inference-shards.active.env to inference / hub'
    Write-AlfaLog -Level CMD -Message ("scp active shards -> {0}" -f $script:AlfaCfg.Ssh148)
    scp -o BatchMode=yes -o ConnectTimeout=20 $LocalActivePath "$($script:AlfaCfg.Ssh148):${remote148}"
    if ($LASTEXITCODE -ne 0) { throw "scp active shards to inference failed (exit $LASTEXITCODE)" }
    # Hub path may equal inference repo; keep explicit for clarity if paths diverge later.
    if ($remoteHub -ne $remote148) {
        scp -o BatchMode=yes -o ConnectTimeout=20 $LocalActivePath "$($script:AlfaCfg.SshHub):${remoteHub}"
        if ($LASTEXITCODE -ne 0) { throw "scp active shards to hub failed (exit $LASTEXITCODE)" }
    }
    $key111 = Get-inferenceSsh111KeyPath
    Write-AlfaLog -Level CMD -Message ("scp active shards -> {0}" -f $script:AlfaCfg.Ssh111)
    scp -o BatchMode=yes -o ConnectTimeout=20 -i $key111 $LocalActivePath "$($script:AlfaCfg.Ssh111):${remote111}"
    if ($LASTEXITCODE -ne 0) { throw "scp active shards to hub failed (exit $LASTEXITCODE)" }
    Write-AlfaLog -Level OK -Message 'Active shard list synced to inference and hub'
    Stop-AlfaPhase
}

function Invoke-AlfaRemote219Ssh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$Label,
        [string]$HostLabel = 'gaming-a'
    )
    $key = Get-inferenceSsh219KeyPath
    $target = $script:AlfaCfg.Ssh219
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AlfaLog -Level CMD -Message ("ssh -i ..gaming-a {0} :: {1}" -f $target, $RemoteCommand)
    $outputLines = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key $target $RemoteCommand 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            $text = $_.ToString()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($outputLines.Count -ge 20) { $outputLines.RemoveAt(0) }
            $outputLines.Add($text) | Out-Null
            if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $endedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    Add-AlfaStepLedgerEntry -HostLabel $HostLabel -Phase $Label -Command $RemoteCommand `
        -StartedAt $startedAt -EndedAt $endedAt -ExitCode $exitCode -Result $result `
        -LastOutputLines @($outputLines)
    if ($exitCode -ne 0) {
        $tail = ($outputLines -join "`n").Trim()
        $msg = ("Remote SSH failed (exit {0}): {1} on {2}" -f $exitCode, $Label, $HostLabel)
        if ($tail) {
            $msg += "`nLast output:`n$tail"
        }
        throw $msg
    }
}

function Invoke-AlfaRemote59Ssh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$Label,
        [string]$HostLabel = 'gaming-c'
    )
    $key = Get-inferenceSsh59KeyPath
    $target = $script:AlfaCfg.Ssh59
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AlfaLog -Level CMD -Message ("ssh -i ..gaming-c {0} :: {1}" -f $target, $RemoteCommand)
    $outputLines = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key $target $RemoteCommand 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            $text = $_.ToString()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($outputLines.Count -ge 20) { $outputLines.RemoveAt(0) }
            $outputLines.Add($text) | Out-Null
            if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $endedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    Add-AlfaStepLedgerEntry -HostLabel $HostLabel -Phase $Label -Command $RemoteCommand `
        -StartedAt $startedAt -EndedAt $endedAt -ExitCode $exitCode -Result $result `
        -LastOutputLines @($outputLines)
    if ($exitCode -ne 0) {
        $tail = ($outputLines -join "`n").Trim()
        $msg = ("Remote SSH failed (exit {0}): {1} on {2}" -f $exitCode, $Label, $HostLabel)
        if ($tail) {
            $msg += "`nLast output:`n$tail"
        }
        throw $msg
    }
}

function Invoke-AlfaRemote110Ssh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$Label,
        [string]$HostLabel = 'rag'
    )
    $key = Get-inferenceSsh110KeyPath
    $target = $script:AlfaCfg.Ssh110
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AlfaLog -Level CMD -Message ("ssh -i ..rag {0} :: {1}" -f $target, $RemoteCommand)
    $outputLines = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key $target $RemoteCommand 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            $text = $_.ToString()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($outputLines.Count -ge 20) { $outputLines.RemoveAt(0) }
            $outputLines.Add($text) | Out-Null
            if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $endedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    Add-AlfaStepLedgerEntry -HostLabel $HostLabel -Phase $Label -Command $RemoteCommand `
        -StartedAt $startedAt -EndedAt $endedAt -ExitCode $exitCode -Result $result `
        -LastOutputLines @($outputLines)
    if ($exitCode -ne 0) {
        $tail = ($outputLines -join "`n").Trim()
        $msg = ("Remote SSH failed (exit {0}): {1} on {2}" -f $exitCode, $Label, $HostLabel)
        if ($tail) {
            $msg += "`nLast output:`n$tail"
        }
        if ($tail -match 'Permission denied \(publickey') {
            $msg += "`nConfigure direct orchestrator-rag SSH: id_ed25519_93_110 on orchestrator, pubkey in operator@rag authorized_keys."
        }
        throw $msg
    }
}

function Invoke-AlfaRemoteSsh {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$Label,
        [string]$HostLabel = ''
    )
    $hostTag = if ($HostLabel) { $HostLabel } else { $Target }
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AlfaLog -Level CMD -Message ("ssh {0} :: {1}" -f $Target, $RemoteCommand)
    $outputLines = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        ssh -o BatchMode=yes -o ConnectTimeout=20 $Target $RemoteCommand 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            $text = $_.ToString()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($outputLines.Count -ge 20) { $outputLines.RemoveAt(0) }
            $outputLines.Add($text) | Out-Null
            if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $endedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    Add-AlfaStepLedgerEntry -HostLabel $hostTag -Phase $Label -Command $RemoteCommand `
        -StartedAt $startedAt -EndedAt $endedAt -ExitCode $exitCode -Result $result `
        -LastOutputLines @($outputLines)
    if ($exitCode -ne 0) {
        $tail = ($outputLines -join "`n").Trim()
        $msg = ("Remote SSH failed (exit {0}): {1} on {2}" -f $exitCode, $Label, $hostTag)
        if ($tail) {
            $msg += "`nLast output:`n$tail"
        }
        if ($tail -match 'sudo: a password is required') {
            $msg += "`nGrant operator sudo_commands_nopasswd on hub per docs/POOL_SWITCH_OPERATOR.md (A11)."
        }
        throw $msg
    }
}

function Invoke-AlfaRemote111Ssh {
    param(
        [Parameter(Mandatory)][string]$InnerBashCommand,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowFailure
    )
    $key = Get-inferenceSsh111KeyPath
    $target = $script:AlfaCfg.Ssh111
    $hostTag = 'hub'
    $escaped = $InnerBashCommand -replace "'", "'\''"
    $remoteCommand = "bash -lc '$escaped'"
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AlfaLog -Level CMD -Message ("ssh $target :: $remoteCommand")
    $outputLines = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        & ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 `
            -i $key $target $remoteCommand 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            $text = $_.ToString()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($outputLines.Count -ge 20) { $outputLines.RemoveAt(0) }
            $outputLines.Add($text) | Out-Null
            if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $endedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    Add-AlfaStepLedgerEntry -HostLabel $hostTag -Phase $Label -Command $remoteCommand `
        -StartedAt $startedAt -EndedAt $endedAt -ExitCode $exitCode -Result $result `
        -LastOutputLines @($outputLines)
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $tail = ($outputLines -join "`n").Trim()
        $msg = ("Remote SSH failed (exit {0}): {1} on {2}" -f $exitCode, $Label, $hostTag)
        if ($tail) {
            $msg += "`nLast output:`n$tail"
        }
        if ($tail -match 'sudo: a password is required') {
            $msg += "`nGrant operator sudo_commands_nopasswd on hub per docs/POOL_SWITCH_OPERATOR.md (A11)."
        }
        if ($tail -match 'Permission denied \(publickey') {
            $msg += "`nConfigure direct orchestrator-hub SSH: id_ed25519_93_111 on orchestrator, pubkey in operator@hub authorized_keys."
        }
        throw $msg
    }
}

function Invoke-AlfaRemote111 {
    param(
        [Parameter(Mandatory)][string]$Subcommand,
        [Parameter(Mandatory)][string]$Label
    )
    $repo = $script:AlfaCfg.Repo111
    $scriptPath = "$repo/deploy/cluster-members/hub/operator-cluster-111.sh"
    $envPrefix = ''
    if ($SkipPull) {
        $envPrefix = 'SKIP_PULL=1 '
    }
    if ($script:inferenceLogSessionId) {
        if ($Subcommand -match 'error-logs|start-pool') {
            $envPrefix += "inference_LOG_SESSION_ID=$($script:inferenceLogSessionId) "
        }
    }
    if ($Subcommand -match 'start-pool') {
        $activeRemote = "$repo/deploy/llamacpp-rpc/inference-shards.active.env"
        $envPrefix += "inference_SHARDS_FILE=$activeRemote "
        if ($script:AlfaGuiCtxSize -gt 0) {
            $envPrefix += "CTX_SIZE=$($script:AlfaGuiCtxSize) "
        }
        if ($script:AlfaGuiParallelSlots -gt 0) {
            $envPrefix += "PARALLEL=$($script:AlfaGuiParallelSlots) "
        }
    }
    $inner = "${envPrefix}bash ${scriptPath} ${Subcommand}"
    Invoke-AlfaRemote111Ssh -InnerBashCommand $inner -Label $Label
}

function Invoke-AlfaRemote111Raw {
    param(
        [Parameter(Mandatory)][string]$InnerBashCommand,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowFailure
    )
    Invoke-AlfaRemote111Ssh -InnerBashCommand $InnerBashCommand -Label $Label -AllowFailure:$AllowFailure
}

function Invoke-AlfaEnsureHostActionsSecretsOn111 {
    # Seed is gitignored on orchestrator. Copy to hub only when remote files are missing or empty.
    # Official: scp https://man.openbsd.org/scp.1 ; chmod https://pubs.opengroup.org/onlinepubs/9699919799/utilities/chmod.html
    #           test -s https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
    $localDir = Join-Path $script:AlfaCfg.RepoRoot 'deploy\secrets\host-actions'
    $localKey = Join-Path $localDir 'id_ed25519'
    $localKnown = Join-Path $localDir 'known_hosts'
    $missing = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $localKey)) {
        $missing.Add('id_ed25519') | Out-Null
    } elseif ((Get-Item -LiteralPath $localKey).Length -lt 1) {
        $missing.Add('id_ed25519 (empty)') | Out-Null
    }
    if (-not (Test-Path -LiteralPath $localKnown)) {
        $missing.Add('known_hosts') | Out-Null
    } elseif ((Get-Item -LiteralPath $localKnown).Length -lt 1) {
        $missing.Add('known_hosts (empty)') | Out-Null
    }
    if ($missing.Count -gt 0) {
        $missText = ($missing -join ', ')
        $warn = 'Ask ALFa host-actions seed missing on orchestrator ({0}): {1}. Cluster start continues; inspect/SSH catalog stays blocked until those files exist.' -f $localDir, $missText
        Write-AlfaLog -Level WARN -Message $warn
        return
    }
    $repo111 = $script:AlfaCfg.Repo111
    $remoteDir = "$repo111/deploy/secrets/host-actions"
    $probe = "if test -s $remoteDir/id_ed25519 && test -s $remoteDir/known_hosts; then echo PRESENT; else echo MISSING; fi"
    $key111 = Get-inferenceSsh111KeyPath
    $target = $script:AlfaCfg.Ssh111
    $escaped = $probe -replace "'", "'\''"
    $remoteCommand = "bash -lc '$escaped'"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $probeOut = ''
    $probeExit = 1
    try {
        $probeOut = (& ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key111 $target $remoteCommand 2>&1 | Out-String)
        $probeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($probeExit -ne 0) {
        throw ("Host-actions secrets probe on hub failed (exit {0}): {1}" -f $probeExit, $probeOut.Trim())
    }
    if ($probeOut -match 'PRESENT') {
        Write-AlfaLog -Level OK -Message 'Ask ALFa host-actions key already present on hub'
        return
    }
    Write-AlfaLog -Level INFO -Message 'Ask ALFa host-actions key missing on hub -- copying gitignored seed from orchestrator'
    $dest = ('{0}:{1}/' -f $script:AlfaCfg.Ssh111, $remoteDir)
    Write-AlfaLog -Level CMD -Message ('scp host-actions id_ed25519 known_hosts -> {0}' -f $script:AlfaCfg.Ssh111)
    scp -o BatchMode=yes -o ConnectTimeout=20 -i $key111 $localKey $localKnown $dest
    if ($LASTEXITCODE -ne 0) {
        throw 'scp host-actions secrets to hub failed'
    }
    Invoke-AlfaRemote111Raw -InnerBashCommand "chmod 600 $remoteDir/id_ed25519" -Label 'hub chmod host-actions key'
    Write-AlfaLog -Level OK -Message 'Ask ALFa host-actions key restored on hub'
}

function Invoke-AlfaSshEchoPreflight {
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$KeyPath = '',
        [int]$ConnectTimeoutSec = 10
    )
    # Local wall ~25s: ConnectTimeout is TCP/KEX only; Kill orphan ssh.exe if hung.
    # WaitForExit(Int32): https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexit
    # Kill: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill
    $cmdSlackSec = 5
    $wallMs = ($ConnectTimeoutSec + $cmdSlackSec + 10) * 1000
    $proc = $null
    $ok = $false
    try {
        $argParts = @(
            '-o', 'BatchMode=yes',
            '-o', "ConnectTimeout=$ConnectTimeoutSec",
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3'
        )
        if ($KeyPath) {
            $argParts += @('-i', $KeyPath)
        }
        $argParts += @($Target, 'echo SSH_OK')
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
            $ok = $false
        } else {
            $ok = ($proc.ExitCode -eq 0)
        }
    } catch {
        $ok = $false
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
    }
    return $ok
}

function Test-AlfaSshBatch {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label,
        [string]$KeyPath = ''
    )
    $ok = Invoke-AlfaSshEchoPreflight -Target $Target -KeyPath $KeyPath
    if (-not $ok) {
        throw ("SSH preflight failed for {0} ({1}). Configure key auth first." -f $Label, $Target)
    }
    Write-AlfaLog -Level OK -Message ("SSH OK: $Label ($Target)")
}

function Test-AlfaTcpPortOpen {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )
    $r = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
    return $r.TcpTestSucceeded
}

function Test-AlfaSsh111Batch {
    $key = Get-inferenceSsh111KeyPath
    $target = $script:AlfaCfg.Ssh111
    $ok = Invoke-AlfaSshEchoPreflight -Target $target -KeyPath $key
    if (-not $ok) {
        throw ("SSH preflight failed for hub ($target). Key: $key")
    }
    Write-AlfaLog -Level OK -Message ("SSH OK: hub operator ($target)")
}

function Test-Alfa111NoStopInProgress {
    # Guards against a previous "hub stop" still running when a new start begins.
    # Uses path-based pgrep on hub (check-111-cluster-op-busy.sh) -- not a nested SSH probe.
    $busyScript = Join-AlfaRemoteScript $script:AlfaCfg.Repo111 'deploy/cluster-members/_common/check-111-cluster-op-busy.sh'
    $key = Get-inferenceSsh111KeyPath
    $target = $script:AlfaCfg.Ssh111
    $remoteCommand = "bash -lc 'bash $busyScript'"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $outputLines = New-Object System.Collections.Generic.List[string]
    try {
        & ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key $target $remoteCommand 2>&1 | ForEach-Object {
            if ($null -ne $_) {
                $text = $_.ToString()
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $outputLines.Add($text) | Out-Null
                }
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($exitCode -eq 0) {
        return
    }
    $text = ($outputLines -join "`n").Trim()
    throw @(
        'Start blocked: a previous hub stop (or start) command is still running there:'
        $text
        'Wait for that hub terminal to return to a shell prompt (script exits cleanly) before'
        'starting a new cycle. Overlapping stop+start on hub can silently kill the coordinator'
        'or shard the new start just created (see inference_START_FIX_PLAN.md Section 7).'
    ) -join "`n"
}

function Test-AlfaTrainLockBlocksStart {
    $trainLock = Join-Path $LlcDir 'alfa-train.lock'
    if (-not (Test-Path -LiteralPath $trainLock)) {
        return
    }

    if ($null -eq $script:AlfaGamingSelection) {
        throw ("Start blocked: 7B QLoRA trainer lock present ($trainLock). Run Stop-AlfaTrain7bQlora.ps1 from orchestrator (train GUI Stop trainer or CLI).")
    }

    # -match regex per about_Comparison_Operators:
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_comparison_operators
    $lockLines = Get-Content -LiteralPath $trainLock -ErrorAction Stop
    $lockIncludes219 = $false
    foreach ($line in $lockLines) {
        if ($line -match '^INCLUDE_219=1$') {
            $lockIncludes219 = $true
            break
        }
    }

    $sel = $script:AlfaGamingSelection
    $blockReasons = New-Object System.Collections.Generic.List[string]

    if ($InferenceMode -eq 'Pool72' -or $InferenceMode -eq 'Pool80') {
        [void]$blockReasons.Add('Pool72/Pool80 use gaming-c/gaming-b')
    }
    if ($sel.Include59) {
        [void]$blockReasons.Add('opt-in gaming-c overlaps the train island')
    }
    if ($sel.Include249) {
        [void]$blockReasons.Add('opt-in gaming-b overlaps the train island')
    }
    if ($sel.Include219 -and $lockIncludes219) {
        [void]$blockReasons.Add('opt-in gaming-a overlaps the train island')
    }

    if ($blockReasons.Count -gt 0) {
        $reasonText = ($blockReasons -join '; ')
        throw ("Start blocked: 7B QLoRA trainer lock present ($trainLock) - {0}. Run Stop-AlfaTrain7bQlora.ps1 from orchestrator (train GUI Stop trainer)." -f $reasonText)
    }

    $trainHosts = 'gaming-c/gaming-b'
    if ($lockIncludes219) {
        $trainHosts = 'gaming-c/gaming-b/gaming-a'
    }
    Write-AlfaLog -Level WARN -Message ("Train lock present ($trainLock); 7B QLoRA running on {0}. inference core start continues (gaming-c/gaming-b opt-in blocked when checked). Leftover gaming-stop skips gaming-c/gaming-b while the lock is set." -f $trainHosts)
}

function Test-AlfaTrainLockPresent {
    $trainLock = Join-Path $LlcDir 'alfa-train.lock'
    return (Test-Path -LiteralPath $trainLock)
}

function Test-AlfaTrainLockIncludes219 {
    $trainLock = Join-Path $LlcDir 'alfa-train.lock'
    if (-not (Test-Path -LiteralPath $trainLock)) {
        return $false
    }
    foreach ($line in Get-Content -LiteralPath $trainLock -ErrorAction Stop) {
        if ($line -match '^INCLUDE_219=1$') {
            return $true
        }
    }
    return $false
}

function Test-Alfa7bServeLockPresent {
    $serveLock = Join-Path $LlcDir 'alfa-7b-serve.lock'
    return (Test-Path -LiteralPath $serveLock)
}

function Test-Alfa7bServeLockBlocksStart {
    $serveLock = Join-Path $LlcDir 'alfa-7b-serve.lock'
    if (-not (Test-Path -LiteralPath $serveLock)) {
        return
    }

    if ($null -eq $script:AlfaGamingSelection) {
        throw ("Start blocked: 7B serve lock present ($serveLock). Run Stop-Alfa7bServe.ps1 from orchestrator.")
    }

    $sel = $script:AlfaGamingSelection
    if ($sel.Include59) {
        throw ("Start blocked: 7B standalone server lock present ($serveLock) - opt-in gaming-c overlaps 7B serve on gaming-worker-c. Run Stop-Alfa7bServe.ps1 or uncheck gaming-c.")
    }

    Write-AlfaLog -Level WARN -Message ("7B serve lock present ($serveLock); inference opt-in gaming-c blocked when checked. Core start continues.")
}

function Invoke-AlfaPreflightStartNotRunning {
    Test-AlfaTrainLockBlocksStart
    Test-Alfa7bServeLockBlocksStart
    if ($SkipVerify) {
        return
    }
    Start-AlfaPhase 'Preflight (cluster must be stopped)'
    if (-not $SkipPull) {
        $repo111 = $script:AlfaCfg.Repo111
        Invoke-AlfaRemote111Raw -InnerBashCommand "cd $repo111 && git fetch origin main && git reset --hard origin/main" `
            -Label 'hub git sync (start preflight)'
        Invoke-AlfaEnsureHostActionsSecretsOn111
    }
    Test-Alfa111NoStopInProgress
    $ip = $script:AlfaCfg.Ip111
    $busy = @()
    if (Test-AlfaTcpPortOpen -HostName $ip -Port 8420) { $busy += 'brain :8420' }
    if (Test-AlfaTcpPortOpen -HostName $ip -Port 8413) { $busy += 'LiteLLM :8413' }
    if (Test-AlfaTcpPortOpen -HostName $ip -Port 31360) { $busy += '27B coordinator :31360' }
    $ip110 = $script:AlfaCfg.Ip110
    if (Test-AlfaTcpPortOpen -HostName $ip110 -Port 11435) { $busy += 'embed :11435 on rag' }
    if (Test-AlfaTcpPortOpen -HostName $ip110 -Port 8360) { $busy += 'rerank :8360 on rag' }
    if ($busy.Count -gt 0) {
        $list = $busy -join ', '
        throw ("Start blocked: $list still up. Run stop first: powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop")
    }
    Invoke-AlfainferenceLeftoverGamingStop
    $busy = @()
    # Active shard list (incl. gaming): refuse start if any RPC port still listening.
    $activeLocal = Join-Path $LlcDir 'inference-shards.active.env'
    if (-not (Test-Path -LiteralPath $activeLocal)) {
        $activeLocal = Join-Path $LlcDir 'inference-shards.env'
    }
    if (Test-Path -LiteralPath $activeLocal) {
        Get-Content -LiteralPath $activeLocal | ForEach-Object {
            $line = ($_ -replace '#.*$', '').Trim()
            if (-not $line) { return }
            $parts = $line -split '\s+'
            if ($parts.Count -lt 2) { return }
            $h = $parts[0]
            $p = 0
            if (-not [int]::TryParse($parts[1], [ref]$p)) { return }
            # gaming-a Win10 portproxy: LAN TCP stays open after WSL stop -- probe WSL.
            if ($h -eq $script:AlfaCfg.Ip219 -and $p -eq 31352) {
                try {
                    Test-Alfa219RpcShardClosedInWsl -Label 'gaming-a start-preflight WSL :31352'
                } catch {
                    $busy += 'shard orchestrator (WSL still up)'
                }
                return
            }
            if (Test-AlfaTcpPortOpen -HostName $h -Port $p) {
                $busy += ("shard {0}:{1}" -f $h, $p)
            }
        }
    }
    if ($busy.Count -gt 0) {
        $list = $busy -join ', '
        throw ("Start blocked: $list still up. Run stop first: powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop")
    }
    Write-AlfaLog -Level OK -Message 'Start preflight: brain, coordinator, RAG, and active shard ports closed'
    Stop-AlfaPhase
}

function Test-AlfaTcpPortClosed {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Label
    )
    Write-AlfaLog -Level INFO -Message ("TCP closed check: {0}:{1} ({2})" -f $HostName, $Port, $Label)
    $r = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
    if ($r.TcpTestSucceeded) {
        throw ("Stop verify failed: {0} still listening ({1}:{2})" -f $Label, $HostName, $Port)
    }
    Write-AlfaLog -Level OK -Message ("TCP closed OK: $Label (${HostName}:$Port)")
}

function Test-Alfa219RpcShardClosedInWsl {
    <#
    Win10 NAT: netsh portproxy keeps orchestrator accepting TCP after the
    WSL rpc-server is gone (learn.microsoft.com/windows/wsl/networking). Probe
    inside WSL instead of LAN Test-NetConnection.
    #>
    param([string]$Label = 'gaming-a rpc shard :31352 (WSL)')
    Write-AlfaLog -Level INFO -Message ("WSL closed check: {0}" -f $Label)
    # Single-line remote: PS 5.1 on gaming-a; avoid || in the outer shell.
    $remote = @'
$ErrorActionPreference = "Continue"
$null = wsl.exe -d Ubuntu bash -lc "nc -z -w 2 127.0.0.1 31352" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Error "WSL 127.0.0.1:31352 still listening"; exit 1 }
$names = @(wsl.exe -d Ubuntu docker ps -a --format "{{.Names}}" 2>$null)
foreach ($n in $names) { if ($n -match "^llamacpp-rpc") { Write-Error "container still present: $n"; exit 2 } }
Write-Output "OK WSL :31352 closed, no llamacpp-rpc container"
exit 0
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
    $cmd = "powershell -NoProfile -EncodedCommand $b64"
    Invoke-AlfaRemote219Ssh -RemoteCommand $cmd -Label $Label
    Write-AlfaLog -Level OK -Message ("WSL closed OK: {0}" -f $Label)
}

function Test-Alfa59RpcShardClosedInWsl {
    param([string]$Label = 'gaming-c rpc shard :31351 (WSL)')
    Write-AlfaLog -Level INFO -Message ("WSL closed check: {0}" -f $Label)
    $remote = @'
$ErrorActionPreference = "Continue"
$null = wsl.exe -d Ubuntu bash -lc "nc -z -w 2 127.0.0.1 31351" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Error "WSL 127.0.0.1:31351 still listening"; exit 1 }
$names = @(wsl.exe -d Ubuntu docker ps -a --format "{{.Names}}" 2>$null)
foreach ($n in $names) { if ($n -match "^llamacpp-rpc") { Write-Error "container still present: $n"; exit 2 } }
Write-Output "OK WSL :31351 closed, no llamacpp-rpc container"
exit 0
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
    $cmd = "powershell -NoProfile -EncodedCommand $b64"
    Invoke-AlfaRemote59Ssh -RemoteCommand $cmd -Label $Label
    Write-AlfaLog -Level OK -Message ("WSL closed OK: {0}" -f $Label)
}

function Invoke-AlfaRemote249Ssh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$Label,
        [string]$HostLabel = 'gaming-b'
    )
    $key = Get-inferenceSsh249KeyPath
    $target = $script:AlfaCfg.Ssh249
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AlfaLog -Level CMD -Message ("ssh -i ..gaming-b {0} :: {1}" -f $target, $RemoteCommand)
    $outputLines = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key $target $RemoteCommand 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            $text = $_.ToString()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($outputLines.Count -ge 20) { $outputLines.RemoveAt(0) }
            $outputLines.Add($text) | Out-Null
            if ($text -match '^(warning:|error:|fatal:)' -or $text -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $endedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    Add-AlfaStepLedgerEntry -HostLabel $HostLabel -Phase $Label -Command $RemoteCommand `
        -StartedAt $startedAt -EndedAt $endedAt -ExitCode $exitCode -Result $result `
        -LastOutputLines @($outputLines)
    if ($exitCode -ne 0) {
        $tail = ($outputLines -join "`n").Trim()
        $msg = ("Remote SSH failed (exit {0}): {1} on {2}" -f $exitCode, $Label, $HostLabel)
        if ($tail) {
            $msg += "`nLast output:`n$tail"
        }
        throw $msg
    }
}

function Test-Alfa249RpcShardClosedInWsl {
    param([string]$Label = 'gaming-b rpc shard :31358 (WSL)')
    Write-AlfaLog -Level INFO -Message ("WSL closed check: {0}" -f $Label)
    $remote = @'
$ErrorActionPreference = "Continue"
$null = wsl.exe -d Ubuntu bash -lc "nc -z -w 2 127.0.0.1 31358" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Error "WSL 127.0.0.1:31358 still listening"; exit 1 }
$names = @(wsl.exe -d Ubuntu docker ps -a --format "{{.Names}}" 2>$null)
foreach ($n in $names) { if ($n -match "^llamacpp-rpc") { Write-Error "container still present: $n"; exit 2 } }
Write-Output "OK WSL :31358 closed, no llamacpp-rpc container"
exit 0
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
    $cmd = "powershell -NoProfile -EncodedCommand $b64"
    Invoke-AlfaRemote249Ssh -RemoteCommand $cmd -Label $Label
    Write-AlfaLog -Level OK -Message ("WSL closed OK: {0}" -f $Label)
}

function Test-AlfaTcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Optional
    )
    Write-AlfaLog -Level INFO -Message ("TCP check: {0}:{1} ({2})" -f $HostName, $Port, $Label)
    $r = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
    if (-not $r.TcpTestSucceeded) {
        if ($Optional) {
            Write-AlfaLog -Level WARN -Message ("TCP unreachable (optional for stop): {0} ({1}:{2})" -f $Label, $HostName, $Port)
            return $false
        }
        throw ("TCP preflight failed: {0} ({1}:{2})" -f $Label, $HostName, $Port)
    }
    Write-AlfaLog -Level OK -Message ("TCP OK: $Label (${HostName}:$Port)")
    return $true
}

function Test-AlfaHostSshReachable {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$SshTarget,
        [Parameter(Mandatory)][string]$Label,
        [switch]$OptionalForStop,
        [string]$KeyPath = ''
    )
    if ($KeyPath -and -not (Test-Path -LiteralPath $KeyPath)) {
        if ($OptionalForStop) {
            Write-AlfaLog -Level WARN -Message ("SSH key missing (optional for stop): {0} ({1})" -f $Label, $KeyPath)
            if (-not $script:AlfaUnreachableStopHosts.Contains($Ip)) {
                [void]$script:AlfaUnreachableStopHosts.Add($Ip)
            }
            return $false
        }
        throw ("Missing SSH key: {0} ({1})" -f $KeyPath, $Label)
    }
    $tcpOk = Test-AlfaTcpPort -HostName $Ip -Port 22 -Label $Label -Optional:$OptionalForStop
    if (-not $tcpOk) {
        if ($OptionalForStop) {
            if (-not $script:AlfaUnreachableStopHosts.Contains($Ip)) {
                [void]$script:AlfaUnreachableStopHosts.Add($Ip)
            }
        }
        return $false
    }
    try {
        Test-AlfaSshBatch -Target $SshTarget -Label $Label -KeyPath $KeyPath
    } catch {
        if ($OptionalForStop) {
            Write-AlfaLog -Level WARN -Message ("SSH unreachable (optional for stop): {0} ({1})" -f $Label, $SshTarget)
            if (-not $script:AlfaUnreachableStopHosts.Contains($Ip)) {
                [void]$script:AlfaUnreachableStopHosts.Add($Ip)
            }
            return $false
        }
        throw
    }
    return $true
}

function Invoke-AlfainferenceErrorCaptureFirst {
    param(
        [Parameter(Mandatory)][string]$Action
    )
    Start-AlfaPhase 'STEP 0: inference error capture (all hosts)'

    $poolSession = New-inferenceLogSession -RepoRoot $RepoRoot -Action $Action
    $script:inferenceLogSessionId = $poolSession.SessionId
    Write-AlfaLog -Level INFO -Message ("inference session: $($poolSession.SessionId)")
    Write-AlfaLog -Level INFO -Message ("analysis dir: logs\inference-sessions\$($poolSession.SessionId)")

    Start-inferenceLogSessionAutonomous -RepoRoot $RepoRoot -SessionId $poolSession.SessionId `
        -Ssh100 $script:AlfaCfg.Ssh100 -Ssh248 $script:AlfaCfg.Ssh248 -Ssh111 $script:AlfaCfg.Ssh111 -Ssh148 $script:AlfaCfg.Ssh148 `
        -Repo100 $script:AlfaCfg.Repo100 -Repo248 $script:AlfaCfg.Repo248 -Repo148 $script:AlfaCfg.Repo148

    try {
        Invoke-AlfaRemote111 -Subcommand 'start-error-logs' -Label 'hub start-error-logs (STEP 0)'
    } catch {
        Write-AlfaLog -Level WARN -Message ("hub error recorder skipped (non-fatal): $($_.Exception.Message)")
    }

    Stop-AlfaPhase
}

function Invoke-AlfaRemoteGitSync {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Label,
        [switch]$NonFatal
    )
    $syncRel = 'deploy/cluster-members/_common/sync-git-origin-hub-lan.sh'
    $cmd = "cd $RepoPath && bash $syncRel '$RepoPath'"
    try {
        Invoke-AlfaRemoteSsh -Target $Target -RemoteCommand $cmd -Label $Label
    } catch {
        if ($NonFatal) {
            Write-AlfaLog -Level WARN -Message ("Git sync skipped (non-fatal on stop): $Label -- $($_.Exception.Message)")
            return
        }
        throw
    }
}

function Invoke-AlfaVerifyBrainStopped {
    Start-AlfaPhase 'Verify brain stopped (hub)'
    $ip = $script:AlfaCfg.Ip111
    Test-AlfaTcpPortClosed -HostName $ip -Port 8420 -Label 'brain operator :8420'
    Test-AlfaTcpPortClosed -HostName $ip -Port 8413 -Label 'LiteLLM :8413'
    Test-AlfaTcpPortClosed -HostName $ip -Port 8090 -Label 'nginx :8090'
    Stop-AlfaPhase
}

function Invoke-AlfaVerify111PoolStopped {
    Start-AlfaPhase 'Verify hub pool shard stopped'
    $ip = $script:AlfaCfg.Ip111
    Test-AlfaTcpPortClosed -HostName $ip -Port 31353 -Label 'hub rpc shard :31353'
    Stop-AlfaPhase
}

function Invoke-AlfaVerify111CoordinatorStopped {
    Start-AlfaPhase 'Verify hub coordinator stopped'
    $ip = $script:AlfaCfg.Ip111
    Test-AlfaTcpPortClosed -HostName $ip -Port 31360 -Label 'hub coordinator :31360'
    Stop-AlfaPhase
}

function Invoke-AlfaVerify148CoordinatorStopped {
    Start-AlfaPhase 'Verify stale inference coordinator stopped'
    $ip = $script:AlfaCfg.Ip148
    Test-AlfaTcpPortClosed -HostName $ip -Port 31360 -Label 'inference coordinator :31360 (legacy)'
    Stop-AlfaPhase
}

function Invoke-AlfaVerifyinferenceStoppedFromHub {
    Start-AlfaPhase 'Verify inference stopped (from inference hub; active shard list)'
    # Prefer active.env (core + gaming). Core-only verify left gaming-a/:31352 up as "OK".
    $activeRemote = "$(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/llamacpp-rpc/inference-shards.active.env')"
    $coreRemote = "$(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/llamacpp-rpc/inference-shards.env')"
    $verifyScript = "$(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/cluster-members/_common/verify-inference-stopped.sh')"
    $remoteCmd = "if [ -f '$activeRemote' ]; then bash '$verifyScript' '$activeRemote'; else bash '$verifyScript' '$coreRemote'; fi"
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.SshHub `
        -RemoteCommand $remoteCmd `
        -Label 'verify-inference-stopped (active list)'
    Stop-AlfaPhase
}

function Invoke-AlfaVerifyEdgeStopped {
    # Edge on inference is protected infra. apps DB/bots are separate (not cluster-managed).
    # so we do not assert closed. Optionally a positive health check could be added here
    # (but post-stop the brain is down so the proxy may 502 to backend - that's expected).
    Write-AlfaLog -Level OK -Message 'Edge proxy is protected infra; not stopped by cluster stop (no closed-port assertion).'
    if ($SkipEdge) {
        Write-AlfaLog -Level WARN -Message 'SkipEdge noted (edge start control only).'
    }
}

function Get-AlfaRagRemoteEnv {
    # Embed + rerank mandatory on rag CPU (:11435 + :8360). SSoT: rag-sidecars.env
    return 'RAG_REQUIRE_RERANK=1'
}

function Invoke-AlfaVerifyRagStoppedFromHub {
    Start-AlfaPhase 'Verify RAG sidecars stopped (from inference hub)'
    $ragEnv = Get-AlfaRagRemoteEnv
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.SshHub `
        -RemoteCommand "${ragEnv} bash $(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/cluster-members/_common/verify-rag-sidecars-stopped.sh')" `
        -Label 'verify-rag-sidecars-stopped'
    Stop-AlfaPhase
}

function Invoke-AlfaVerifyRagFromHub {
    Start-AlfaPhase 'Verify RAG sidecars (from inference hub)'
    $ragEnv = Get-AlfaRagRemoteEnv
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.SshHub `
        -RemoteCommand "${ragEnv} RAG_VERIFY_RETRIES=36 bash $(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/cluster-members/_common/verify-rag-sidecars.sh')" `
        -Label 'verify-rag-sidecars'
    Stop-AlfaPhase
}

function Invoke-AlfaStopRagSidecars {
    Start-AlfaPhase 'Stop RAG sidecars (rag CPU embed/rerank + inference/pool-opt-in legacy)'
    $stopRag = 'deploy/cluster-members/_common/stop-rag-sidecars.sh'
    $repo110 = $script:AlfaCfg.Repo110
    $repo148 = $script:AlfaCfg.Repo148
    $repo100 = $script:AlfaCfg.Repo100
    Invoke-AlfaRemote110Ssh `
        -RemoteCommand "HOST_LABEL=110 bash $(Join-AlfaRemoteScript $repo110 $stopRag)" `
        -Label 'rag stop-rag-sidecars'
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh148 `
        -RemoteCommand "HOST_LABEL=148 bash $(Join-AlfaRemoteScript $repo148 $stopRag)" `
        -Label 'inference stop-rag-sidecars (legacy)'
    if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip100)) {
        Write-AlfaLog -Level WARN -Message 'pool-opt-in legacy RAG stop skipped (unreachable)'
    } elseif (-not (Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip100 -Port 22 -Label 'pool-opt-in SSH (legacy RAG)' -Optional)) {
        Write-AlfaLog -Level WARN -Message 'pool-opt-in legacy RAG stop skipped (SSH not reachable)'
    } else {
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh100 `
            -RemoteCommand "HOST_LABEL=100 bash $(Join-AlfaRemoteScript $repo100 $stopRag)" `
            -Label 'pool-opt-in stop-rag-sidecars (legacy)'
    }
    Stop-AlfaPhase
}

function Invoke-AlfaVerifyClusterStopped {
    if ($SkipVerify) {
        Write-AlfaLog -Level WARN -Message 'Skipping post-stop verify (--SkipVerify)'
        return
    }
    Invoke-AlfaVerify111CoordinatorStopped
    Invoke-AlfaVerify148CoordinatorStopped
    Invoke-AlfaVerifyinferenceStoppedFromHub
    Invoke-AlfaVerifyRagStoppedFromHub
    Invoke-AlfaVerifyEdgeStopped
}

# B42: post-coordinator shard-port wedge-repair functions were REMOVED. The llama.cpp
# rpc-server is single-client (accept -> serve one client until disconnect -> accept);
# while the coordinator is connected the shard is not in accept(), so probing shard RPC
# ports post-coordinator is racy and redeploying a shard kills the coordinator's backend
# (SIGABRT). Shard ports are verified only BEFORE the coordinator starts; afterward the
# coordinator real-decode self-test (Invoke-AlfaAssertCoordinatorComputeReady) is the sole
# pool-health gate, with one ordered recovery on failure. See GREV27_27B_OPERATOR.md guard 4.

function Write-Alfa111CoordinatorDiagnostic {
    $inner = 'sudo docker inspect -f "{{.State.Status}}" llamacpp-server-111-grev27-pool 2>/dev/null || echo missing; sudo docker logs --tail 3 llamacpp-server-111-grev27-pool 2>&1 | tail -3'
    Invoke-AlfaRemote111Ssh -InnerBashCommand $inner.Trim() -Label 'hub coordinator diagnostic' -AllowFailure
}

function Invoke-AlfaVerifyCoordinator111 {
    param(
        [int]$TimeoutSec = 900
    )
    Start-AlfaPhase 'Verify 27B coordinator (hub :31360)'
    $url = "http://$($script:AlfaCfg.Ip111):31360/health"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $intervalSec = 10
    $diagIntervalSec = 120
    $nextDiagAt = (Get-Date)
    Write-AlfaLog -Level INFO -Message "Polling $url (timeout ${TimeoutSec}s, interval ${intervalSec}s)..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        while ((Get-Date) -lt $deadline) {
            if ((Get-Date) -ge $nextDiagAt) {
                Write-Alfa111CoordinatorDiagnostic
                $nextDiagAt = (Get-Date).AddSeconds($diagIntervalSec)
            }
            try {
                $null = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
                Write-AlfaLog -Level OK -Message '27B coordinator health OK'
                Stop-AlfaPhase
                return
            } catch {
                $msg = $_.Exception.Message.Split("`n")[0]
                Write-AlfaLog -Level INFO -Message "  (not ready yet: $msg)"
            }
            Start-Sleep -Seconds $intervalSec
        }
        Stop-AlfaPhase -Result FAIL
        throw "27B coordinator not healthy at $url"
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Invoke-AlfaPreflightCommon {
    Start-AlfaPhase 'Preflight'
    try {
        if (-not (Test-Path -LiteralPath $script:AlfaCfg.RepoRoot)) {
            throw "Repo missing: $($script:AlfaCfg.RepoRoot)"
        }
        Write-AlfaLog -Level OK -Message ("Repo OK: $($script:AlfaCfg.RepoRoot)")

        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354) {
            Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip100 -Port 22 -Label 'pool-opt-in SSH' | Out-Null
        } else {
            Write-AlfaLog -Level INFO -Message 'pool-opt-in not in active shard list -- skip SSH preflight'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355) {
            Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip248 -Port 22 -Label 'secondary SSH (gpu-248)' | Out-Null
        } else {
            Write-AlfaLog -Level INFO -Message 'secondary not in active shard list -- skip SSH preflight'
        }
        Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip148 -Port 22 -Label 'inference SSH (hub)' | Out-Null
        Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip111 -Port 22 -Label 'hub SSH (operator host)' | Out-Null

        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354) {
            Test-AlfaSshBatch -Target $script:AlfaCfg.Ssh100 -Label 'pool-opt-in operator'
        }
        if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355) {
            Test-AlfaSshBatch -Target $script:AlfaCfg.Ssh248 -Label 'secondary operator (gpu-248)'
        }
        Test-AlfaSshBatch -Target $script:AlfaCfg.Ssh148 -Label 'inference operator (hub)'
        Test-AlfaSsh111Batch

        Stop-AlfaPhase
    } catch {
        Stop-AlfaPhase -Result FAIL
        throw
    }
}

function Invoke-AlfaPreflightStop {
    Start-AlfaPhase 'Preflight'
    try {
        if (-not (Test-Path -LiteralPath $script:AlfaCfg.RepoRoot)) {
            throw "Repo missing: $($script:AlfaCfg.RepoRoot)"
        }
        Write-AlfaLog -Level OK -Message ("Repo OK: $($script:AlfaCfg.RepoRoot)")

        Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip148 -Port 22 -Label 'inference SSH (hub)' | Out-Null
        Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip111 -Port 22 -Label 'hub SSH (operator host)' | Out-Null

        Test-AlfaSshBatch -Target $script:AlfaCfg.Ssh148 -Label 'inference operator (hub)'
        Test-AlfaSsh111Batch

        $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip100 -SshTarget $script:AlfaCfg.Ssh100 `
            -Label 'pool-opt-in SSH (VM100)' -OptionalForStop
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip100)) {
            Write-AlfaLog -Level WARN -Message 'pool-opt-in unreachable: stop will skip VM100 shard stop and git sync when needed'
        }

        $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip248 -SshTarget $script:AlfaCfg.Ssh248 `
            -Label 'secondary SSH (gpu-248)' -OptionalForStop
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip248)) {
            Write-AlfaLog -Level WARN -Message 'secondary unreachable: stop will skip gpu-248 shard stop and git sync (opt in + power on before next start if needed)'
        }

        $key219 = $null
        try {
            $key219 = Get-inferenceSsh219KeyPath
        } catch {
            Write-AlfaLog -Level WARN -Message $_.Exception.Message
            if (-not $script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip219)) {
                [void]$script:AlfaUnreachableStopHosts.Add($script:AlfaCfg.Ip219)
            }
        }
        if ($key219) {
            $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip219 -SshTarget $script:AlfaCfg.Ssh219 `
                -Label 'gaming-a SSH (gaming-worker-a)' -OptionalForStop -KeyPath $key219
        }
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip219)) {
            Write-AlfaLog -Level WARN -Message 'gaming-a unreachable: stop will skip gaming-worker-a gaming-stop'
        }

        $key59 = $null
        try {
            $key59 = Get-inferenceSsh59KeyPath
        } catch {
            Write-AlfaLog -Level WARN -Message $_.Exception.Message
            if (-not $script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip59)) {
                [void]$script:AlfaUnreachableStopHosts.Add($script:AlfaCfg.Ip59)
            }
        }
        if ($key59) {
            $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip59 -SshTarget $script:AlfaCfg.Ssh59 `
                -Label 'gaming-c SSH (gaming-worker-c)' -OptionalForStop -KeyPath $key59
        }
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip59)) {
            Write-AlfaLog -Level WARN -Message 'gaming-c unreachable: stop will skip gaming-worker-c gaming-stop'
        }

        $key249 = $null
        try {
            $key249 = Get-inferenceSsh249KeyPath
        } catch {
            Write-AlfaLog -Level WARN -Message $_.Exception.Message
            if (-not $script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip249)) {
                [void]$script:AlfaUnreachableStopHosts.Add($script:AlfaCfg.Ip249)
            }
        }
        if ($key249) {
            $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip249 -SshTarget $script:AlfaCfg.Ssh249 `
                -Label 'gaming-b SSH (gaming-worker-b)' -OptionalForStop -KeyPath $key249
        }
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip249)) {
            Write-AlfaLog -Level WARN -Message 'gaming-b unreachable: stop will skip gaming-worker-b gaming-stop'
        }

        Stop-AlfaPhase
    } catch {
        Stop-AlfaPhase -Result FAIL
        throw
    }
}

function Invoke-AlfaGitPull {
    param(
        [Parameter(Mandatory)][string]$Label
    )
    Write-AlfaLog -Level CMD -Message "git fetch + reset origin/main ($Label)"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = git fetch origin main 2>&1
        foreach ($line in @($lines)) {
            if ($null -eq $line) { continue }
            $text = $line.ToString()
            if ($text -match '^(error:|fatal:)') {
                Write-AlfaLog -Level ERROR -Message $text
            } else {
                Write-AlfaLog -Level INFO -Message $text
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw ("git fetch failed on {0} (exit {1})" -f $Label, $LASTEXITCODE)
        }
        $lines = git reset --hard origin/main 2>&1
        foreach ($line in @($lines)) {
            if ($null -eq $line) { continue }
            Write-AlfaLog -Level INFO -Message ($line.ToString())
        }
        if ($LASTEXITCODE -ne 0) {
            throw ("git reset --hard origin/main failed on {0} (exit {1})" -f $Label, $LASTEXITCODE)
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Invoke-AlfaPreflightGitSyncAll {
    param(
        [switch]$NonFatal
    )
    if ($SkipPull) {
        Write-AlfaLog -Level WARN -Message 'Skipping git sync (--SkipPull)'
        return
    }
    Start-AlfaPhase 'git sync (cluster repos)'
    Invoke-AlfaRemoteGitSync -Target $script:AlfaCfg.Ssh148 `
        -RepoPath $script:AlfaCfg.Repo148 `
        -Label 'inference alfa-ai git sync (hub)' `
        -NonFatal:$NonFatal
    if (-not (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354)) {
        Write-AlfaLog -Level INFO -Message 'pool-opt-in git sync skipped (not in active shard list)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip100)) {
        Write-AlfaLog -Level WARN -Message 'pool-opt-in git sync skipped (unreachable during stop preflight)'
    } else {
        Invoke-AlfaRemoteGitSync -Target $script:AlfaCfg.Ssh100 `
            -RepoPath $script:AlfaCfg.Repo100 `
            -Label 'pool-opt-in alfa-ai git sync' `
            -NonFatal:$NonFatal
    }
    if (-not (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355)) {
        Write-AlfaLog -Level INFO -Message 'secondary git sync skipped (not in active shard list)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip248)) {
        Write-AlfaLog -Level WARN -Message 'secondary git sync skipped (unreachable during stop preflight)'
    } else {
        Invoke-AlfaRemoteGitSync -Target $script:AlfaCfg.Ssh248 `
            -RepoPath $script:AlfaCfg.Repo248 `
            -Label 'secondary alfa-ai git sync (gpu-248)' `
            -NonFatal:$NonFatal
    }
    $repo110 = $script:AlfaCfg.Repo110
    $syncRel = 'deploy/cluster-members/_common/sync-git-origin-hub-lan.sh'
    $cmd110 = "cd $repo110 && bash $syncRel '$repo110'"
    try {
        Invoke-AlfaRemote110Ssh -RemoteCommand $cmd110 -Label 'rag alfa-ai git sync'
    } catch {
        if ($NonFatal) {
            Write-AlfaLog -Level WARN -Message ("rag git sync skipped (non-fatal on stop): $($_.Exception.Message)")
        } else {
            throw
        }
    }
    Stop-AlfaPhase
}

function Invoke-AlfaPreflightStart {
    Invoke-AlfaPreflightCommon

    Start-AlfaPhase 'Preflight (start-only)'
    try {
        $coreShards = Join-Path $LlcDir 'inference-shards.core.env'
        $fallbackShards = $script:AlfaCfg.ShardsFileFallback
        if (-not (Test-Path -LiteralPath $coreShards) -and -not (Test-Path -LiteralPath $fallbackShards)) {
            throw "Shard registry missing: $coreShards (and fallback $fallbackShards)"
        }
        Write-AlfaLog -Level OK -Message ("Shard catalog OK (active list written after gaming opt-in): {0}" -f $(if (Test-Path $coreShards) { $coreShards } else { $fallbackShards }))

        if (-not $SkipPull) {
            Start-AlfaPhase 'git pull (orchestrator)'
            Push-Location $script:AlfaCfg.RepoRoot
            try {
                Invoke-AlfaGitPull -Label 'orchestrator'
            } finally {
                Pop-Location
            }
            Stop-AlfaPhase
        }

        Invoke-AlfaPreflightGitSyncAll

        # Docker/WSL + Hyper-V firewall already ran in Invoke-AlfaPreflightLocalEarly (before STEP 0).

        Stop-AlfaPhase
    } catch {
        Stop-AlfaPhase -Result FAIL
        throw
    }

    # Cluster-must-be-stopped already ran in Invoke-AlfaPreflightStartNotRunning (before STEP 0).
}

function Test-AlfainferenceFirewallPreflight {
    $port = 31350
    $fwInstall = Join-Path $CommonDir 'install-wsl-lan-firewall.ps1'
    if (-not (Test-Path -LiteralPath $fwInstall)) {
        throw "Missing firewall install script: $fwInstall"
    }
    . $fwInstall
    if (Test-AlfaWslLanFirewallProfileReady -Profile 'operator-93' -RequiredPorts @($port)) {
        Write-AlfaLog -Level OK -Message "Hyper-V firewall rule present for orchestrator :$port"
        return
    }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if ($isAdmin) {
        Write-AlfaLog -Level INFO -Message "Admin session: opening orchestrator WSL LAN firewall (profile operator-93, port :$port)"
        Install-AlfaWslLanFirewall -Profile 'operator-93' -RepoRoot $RepoRoot
        if (-not (Test-AlfaWslLanFirewallProfileReady -Profile 'operator-93' -RequiredPorts @($port))) {
            throw "FAIL: Hyper-V firewall rule for orchestrator :$port still missing after Install-AlfaWslLanFirewall"
        }
        Write-AlfaLog -Level OK -Message "Hyper-V firewall rule installed for orchestrator :$port"
        return
    }
    $fix = Get-AlfaWslLanFirewallInstallCommand -Profile 'operator-93' -RepoRoot $RepoRoot
    throw @(
        "FAIL: Hyper-V firewall rule for orchestrator inference shard :$port not found (non-Admin session).",
        'One-time fix per docs/WINDOWS_WSL_DOCKER_ENGINE.md - Administrator PowerShell as operator:',
        "  $fix"
    ) -join "`n"
}

function Invoke-AlfainferenceLeftoverGamingStop {
    if ($InferenceMode -eq 'Pool72' -or $InferenceMode -eq 'Pool80') {
        return
    }

    Write-AlfaLog -Level INFO -Message 'inference: leftover stop gaming-a/gaming-c/gaming-b (Pool72/80 exclusive; may still be running from prior session)'

    $skip219Train = Test-AlfaTrainLockIncludes219
    if ($skip219Train) {
        Write-AlfaLog -Level INFO -Message 'gaming-a leftover gaming-stop skipped (train lock INCLUDE_219=1)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip219)) {
        Write-AlfaLog -Level WARN -Message 'gaming-a unreachable: leftover gaming-stop skipped'
    } else {
        $key219 = $null
        try {
            $key219 = Get-inferenceSsh219KeyPath
        } catch {
            Write-AlfaLog -Level WARN -Message $_.Exception.Message
            if (-not $script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip219)) {
                [void]$script:AlfaUnreachableStopHosts.Add($script:AlfaCfg.Ip219)
            }
        }
        if ($key219) {
            $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip219 -SshTarget $script:AlfaCfg.Ssh219 `
                -Label 'gaming-a SSH (gaming-worker-a leftover)' -OptionalForStop -KeyPath $key219
        }
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip219)) {
            Write-AlfaLog -Level WARN -Message 'gaming-a unreachable: leftover gaming-stop skipped'
        } else {
            try {
                Start-AlfaPhase 'gaming-a leftover gaming-stop (:31352)'
                $stop219 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo219Win)\deploy\cluster-members\gaming-worker-a\gaming-stop-for-session.ps1`" -NoPause"
                Invoke-AlfaRemote219Ssh -RemoteCommand $stop219 -Label 'gaming-a leftover gaming-stop-for-session'
                if (-not $SkipVerify) {
                    Test-Alfa219RpcShardClosedInWsl -Label 'gaming-a rpc shard :31352 (leftover)'
                }
                Stop-AlfaPhase
            } catch {
                Write-AlfaLog -Level WARN -Message ("Leftover gaming-a gaming-stop failed (non-fatal): $($_.Exception.Message)")
                Stop-AlfaPhase
            }
        }
    }

    if ((Test-AlfaTrainLockPresent) -or (Test-Alfa7bServeLockPresent)) {
        $skipReason = 'alfa-train.lock; do not docker on train GPUs'
        if (Test-Alfa7bServeLockPresent) {
            $skipReason = 'alfa-7b-serve.lock; 7B llama-server owns gaming-c GPU'
        }
        Write-AlfaLog -Level INFO -Message ("gaming-c leftover gaming-stop skipped ($skipReason)")
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip59)) {
        Write-AlfaLog -Level WARN -Message 'gaming-c unreachable: leftover gaming-stop skipped'
    } else {
        $key59 = $null
        try {
            $key59 = Get-inferenceSsh59KeyPath
        } catch {
            Write-AlfaLog -Level WARN -Message $_.Exception.Message
            if (-not $script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip59)) {
                [void]$script:AlfaUnreachableStopHosts.Add($script:AlfaCfg.Ip59)
            }
        }
        if ($key59) {
            $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip59 -SshTarget $script:AlfaCfg.Ssh59 `
                -Label 'gaming-c SSH (gaming-worker-c leftover)' -OptionalForStop -KeyPath $key59
        }
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip59)) {
            Write-AlfaLog -Level WARN -Message 'gaming-c unreachable: leftover gaming-stop skipped'
        } else {
            try {
                Start-AlfaPhase 'gaming-c leftover gaming-stop (:31351)'
                $stop59 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo59Win)\deploy\cluster-members\gaming-worker-c\gaming-stop-for-session.ps1`" -NoPause"
                Invoke-AlfaRemote59Ssh -RemoteCommand $stop59 -Label 'gaming-c leftover gaming-stop-for-session'
                if (-not $SkipVerify) {
                    Test-Alfa59RpcShardClosedInWsl -Label 'gaming-c rpc shard :31351 (leftover)'
                }
                Stop-AlfaPhase
            } catch {
                Write-AlfaLog -Level WARN -Message ("Leftover gaming-c gaming-stop failed (non-fatal): $($_.Exception.Message)")
                Stop-AlfaPhase
            }
        }
    }

    if (Test-AlfaTrainLockPresent) {
        Write-AlfaLog -Level INFO -Message 'gaming-b leftover gaming-stop skipped (alfa-train.lock; do not docker on train GPUs)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip249)) {
        Write-AlfaLog -Level WARN -Message 'gaming-b unreachable: leftover gaming-stop skipped'
    } else {
        $key249 = $null
        try {
            $key249 = Get-inferenceSsh249KeyPath
        } catch {
            Write-AlfaLog -Level WARN -Message $_.Exception.Message
            if (-not $script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip249)) {
                [void]$script:AlfaUnreachableStopHosts.Add($script:AlfaCfg.Ip249)
            }
        }
        if ($key249) {
            $null = Test-AlfaHostSshReachable -Ip $script:AlfaCfg.Ip249 -SshTarget $script:AlfaCfg.Ssh249 `
                -Label 'gaming-b SSH (gaming-worker-b leftover)' -OptionalForStop -KeyPath $key249
        }
        if ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip249)) {
            Write-AlfaLog -Level WARN -Message 'gaming-b unreachable: leftover gaming-stop skipped'
        } else {
            try {
                Start-AlfaPhase 'gaming-b leftover gaming-stop (:31358)'
                $stop249 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo249Win)\deploy\cluster-members\gaming-worker-b\gaming-stop-for-session.ps1`" -NoPause"
                Invoke-AlfaRemote249Ssh -RemoteCommand $stop249 -Label 'gaming-b leftover gaming-stop-for-session'
                if (-not $SkipVerify) {
                    Test-Alfa249RpcShardClosedInWsl -Label 'gaming-b rpc shard :31358 (leftover)'
                }
                Stop-AlfaPhase
            } catch {
                Write-AlfaLog -Level WARN -Message ("Leftover gaming-b gaming-stop failed (non-fatal): $($_.Exception.Message)")
                Stop-AlfaPhase
            }
        }
    }
}

function Invoke-AlfaStartShardsAutonomous {
    Start-AlfaPhase '27B shards (autonomous hosts)'

    $forceHubLoad = ($InferenceMode -eq 'Pool80')
    if ($forceHubLoad) {
        $env:FORCE_HUB_RPC_LOAD = '1'
        Write-AlfaLog -Level INFO -Message ("{0}: FORCE_HUB_RPC_LOAD=1 (reload alfa-llamacpp-rpc from hub tarball b10355)" -f $InferenceMode)
    }
    $forceEnvPrefix = ''
    if ($forceHubLoad) { $forceEnvPrefix = 'FORCE_HUB_RPC_LOAD=1 ' }
    $forcePsPrefix = ''
    if ($forceHubLoad) { $forcePsPrefix = "`$env:FORCE_HUB_RPC_LOAD='1'; " }

    $shard93 = Join-Path $MemberDir 'deploy-grev27-pool-shard.ps1'
    if (-not (Test-Path -LiteralPath $shard93)) {
        throw "Missing orchestrator shard script: $shard93"
    }

    Start-AlfaPhase 'orchestrator shard :31350'
    & $shard93
    if ($LASTEXITCODE -ne 0) { throw "orchestrator shard deploy failed (exit $LASTEXITCODE)" }
    Stop-AlfaPhase

    $staggerSec = 30
    if ($env:inference_SHARD_STAGGER_SEC -match '^\d+$') {
        $staggerSec = [int]$env:inference_SHARD_STAGGER_SEC
    }
    Write-AlfaLog -Level INFO -Message ("Stagger ${staggerSec}s before inference shards (mitigate RPC accept-queue wedge)")
    Start-Sleep -Seconds $staggerSec

    Start-AlfaPhase 'inference shard :31356 (3060)'
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh148 `
        -RemoteCommand ($forceEnvPrefix + "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo148 'deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh')") `
        -Label 'inference deploy-grev27-pool-shard'
    Stop-AlfaPhase

    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355) {
        Start-AlfaPhase 'gpu-248 shard :31355 (GTX 1070)'
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh248 `
            -RemoteCommand ($forceEnvPrefix + "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo248 'deploy/cluster-members/pool-shard-secondary/deploy-grev27-pool-shard.sh')") `
            -Label 'secondary deploy-grev27-pool-shard'
        Stop-AlfaPhase
    } else {
        Write-AlfaLog -Level INFO -Message 'secondary :31355 not in active shard list -- skip shard deploy'
    }

    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354) {
        Start-AlfaPhase 'VM100 shard :31354 (1660 Super)'
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh100 `
            -RemoteCommand ($forceEnvPrefix + "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo100 'deploy/cluster-members/pool-shard-opt-in/deploy-grev27-pool-shard.sh')") `
            -Label 'pool-opt-in deploy-grev27-pool-shard'
        Stop-AlfaPhase
    } else {
        Write-AlfaLog -Level INFO -Message 'pool-opt-in :31354 not in active shard list -- skip shard deploy'
    }

    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip219 -Port 31352) {
        Start-AlfaPhase 'gaming-a shard :31352 (RTX 5060)'
        $remote219 = $forcePsPrefix + "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo219Win)\deploy\cluster-members\gaming-worker-a\deploy-grev27-pool-shard.ps1`""
        Invoke-AlfaRemote219Ssh -RemoteCommand $remote219 -Label 'gaming-a deploy-grev27-pool-shard'
        Stop-AlfaPhase
    } else {
        Write-AlfaLog -Level INFO -Message 'gaming-a :31352 not in active shard list -- skip shard deploy'
    }

    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip59 -Port 31351) {
        Start-AlfaPhase 'gaming-c shard :31351 (RTX 5070)'
        $remote59 = $forcePsPrefix + "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo59Win)\deploy\cluster-members\gaming-worker-c\deploy-grev27-pool-shard.ps1`""
        Invoke-AlfaRemote59Ssh -RemoteCommand $remote59 -Label 'gaming-c deploy-grev27-pool-shard'
        Stop-AlfaPhase
    } else {
        Write-AlfaLog -Level INFO -Message 'gaming-c :31351 not in active shard list -- skip shard deploy'
    }
    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip249 -Port 31358) {
        Start-AlfaPhase 'gaming-b shard :31358 (RTX 5070)'
        $remote249 = $forcePsPrefix + "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo249Win)\deploy\cluster-members\gaming-worker-b\deploy-grev27-pool-shard.ps1`""
        Invoke-AlfaRemote249Ssh -RemoteCommand $remote249 -Label 'gaming-b deploy-grev27-pool-shard'
        Stop-AlfaPhase
    } else {
        Write-AlfaLog -Level INFO -Message 'gaming-b :31358 not in active shard list -- skip shard deploy'
    }

    $activeRemote = "$(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/llamacpp-rpc/inference-shards.active.env')"
    Start-AlfaPhase 'Verify remote shard TCP (from inference hub; active list)'
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.SshHub `
        -RemoteCommand "bash $(Join-AlfaRemoteScript $script:AlfaCfg.RepoHub 'deploy/cluster-members/_common/verify-inference-shards.sh') --remote-only $activeRemote" `
        -Label 'verify-inference-shards remote-only (active)'
    Stop-AlfaPhase

    Stop-AlfaPhase
}

function Invoke-AlfaOperatorStart111 {
    Start-AlfaPhase 'Automated hub start (start-pool + start-brain)'

    $poolSub = if ($InferenceMode -eq 'Pool72') { 'start-pool72' } elseif ($InferenceMode -eq 'Pool80') { 'start-pool80' } else { 'start-pool' }
    if ($InferenceMode -eq 'Pool72') {
        Write-Host "InferenceMode=Pool72 - exclusive Qwen2.5-72B Q5 (docs/GREV72_72B_OPERATOR.md); include all opt-in hosts"
    } elseif ($InferenceMode -eq 'Pool80') {
        Write-Host "InferenceMode=Pool80 - exclusive Coder-Next Q5 (docs/GREV80_80B_OPERATOR.md); include all opt-in hosts"
    } elseif ($InferenceMode -eq 'inference_38') {
        Write-Host "InferenceMode=inference_38 - legacy alias; same as inference (Qwen3.8-27B Q8 production)"
    }
    Invoke-AlfaRemote111 -Subcommand $poolSub -Label "hub $poolSub"

    if (-not $SkipVerify) {
        # B42: coordinator is up; rpc-server is single-client and busy serving it.
        # Do NOT probe shard RPC ports here (racy per official ggml-rpc server loop).
        # Gate real decode HERE -- before start-brain/LiteLLM. A concurrent completion
        # during brain start can stall a PARALLEL slot and hang a late self-test
        # (HTTP 000). Official /health is load-only, not decode-proven
        # (llama.cpp tools/server/README.md).
        Invoke-AlfaVerifyCoordinator111
        Invoke-AlfaAssertCoordinatorComputeReady
        Invoke-AlfaStartRagSidecars
        Invoke-AlfaVerifyRagFromHub
    }

    Invoke-AlfaRemote111 -Subcommand 'start-brain' -Label 'hub start-brain'
    Invoke-AlfaEnsureHostActionsSecretsOn111

    if (-not $SkipVerify) {
        Invoke-AlfaVerifyCoordinator111
        Invoke-AlfaVerifyRagFromHub
    }

    Stop-AlfaPhase
}

function Invoke-AlfaStartRagSidecars {
    Start-AlfaPhase 'RAG sidecars (rag CPU embed + rerank)'

    $stopRag = 'deploy/cluster-members/_common/stop-rag-sidecars.sh'
    $startRag = 'deploy/cluster-members/_common/start-rag-sidecars.sh'
    $repo110 = $script:AlfaCfg.Repo110
    $repo148 = $script:AlfaCfg.Repo148
    $repo100 = $script:AlfaCfg.Repo100
    if (-not (Test-AlfaTcpPort -HostName $script:AlfaCfg.Ip100 -Port 22 -Label 'pool-opt-in SSH (legacy RAG cleanup)' -Optional)) {
        Write-AlfaLog -Level WARN -Message 'pool-opt-in unreachable -- skip legacy RAG stop before rag CPU RAG'
    } else {
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh100 `
            -RemoteCommand "HOST_LABEL=100 bash $(Join-AlfaRemoteScript $repo100 $stopRag)" `
            -Label 'pool-opt-in stop legacy RAG before rag CPU RAG start'
    }
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh148 `
        -RemoteCommand "HOST_LABEL=148 bash $(Join-AlfaRemoteScript $repo148 $stopRag)" `
        -Label 'inference stop legacy RAG before rag CPU RAG start'

    $ragEnv = Get-AlfaRagRemoteEnv
    Invoke-AlfaRemote110Ssh `
        -RemoteCommand "${ragEnv} HOST_LABEL=110 bash $(Join-AlfaRemoteScript $repo110 $startRag)" `
        -Label 'rag start-rag-sidecars (CPU embed + rerank)'

    Stop-AlfaPhase
}

function Invoke-AlfaStartEdgeHub {
    if ($SkipEdge) {
        Write-AlfaLog -Level WARN -Message 'Skipping inference edge proxy (--SkipEdge)'
        return
    }
    Start-AlfaPhase 'inference edge proxy :8420 ( admin login)'
    $repoHub = $script:AlfaCfg.RepoHub
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.SshHub `
        -RemoteCommand "ALFA_AI_REPO=$repoHub bash $repoHub/deploy/cluster-members/_common/start-edge-api.sh" `
        -Label 'inference start-edge-api.sh'
    Stop-AlfaPhase
}

function Test-Alfa111CoordinatorComputeReady {
    # Returns $true if a REAL decode succeeds against the hub coordinator (:31360).
    # nc -z / /health only prove the port/metadata; this proves shard compute works.
    $repo111 = $script:AlfaCfg.Repo111
    $key = Get-inferenceSsh111KeyPath
    $target = $script:AlfaCfg.Ssh111
    $selftest = "$repo111/deploy/cluster-members/_common/selftest-grev27-coordinator.sh"
    $inner = "bash $selftest http://127.0.0.1:31360 change-me qwen3.6-27b 180"
    $escaped = $inner -replace "'", "'\''"
    $remoteCommand = "bash -lc '$escaped'"
    Write-AlfaLog -Level CMD -Message ("ssh $target :: $remoteCommand")
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 `
            -i $key $target $remoteCommand 2>&1 | ForEach-Object {
            if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.ToString())) {
                Write-AlfaLog -Level INFO -Message $_.ToString()
            }
        }
        $ok = ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
    return $ok
}

function Invoke-AlfaForcePoolOrderedRecovery {
    # Ordered recovery so a fresh coordinator never reconnects to a wedged shard:
    #   1) redeploy ALL shards in the active list (core + opted-in gaming),
    #   2) redeploy hub shard + coordinator via start-pool (re-runs self-test).
    # Skipping gaming hosts that remain in RPC_BACKENDS leaves a stale backend
    # (session 20260716-030921-start: gaming-a not redeployed -> recovery self-test FAIL).
    Write-AlfaLog -Level WARN -Message 'Coordinator compute self-test FAILED - ordered pool recovery (all shards, then coordinator)'
    Start-AlfaPhase 'Ordered pool recovery: redeploy all shards'
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh148 `
        -RemoteCommand "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo148 'deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh')" `
        -Label 'inference redeploy shards (ordered recovery)'
    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355) {
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh248 `
            -RemoteCommand "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo248 'deploy/cluster-members/pool-shard-secondary/deploy-grev27-pool-shard.sh')" `
            -Label 'secondary redeploy shard (ordered recovery)'
    }
    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354) {
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh100 `
            -RemoteCommand "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo100 'deploy/cluster-members/pool-shard-opt-in/deploy-grev27-pool-shard.sh')" `
            -Label 'pool-opt-in redeploy shard (ordered recovery)'
    }
    $shard93 = Join-Path $PSScriptRoot 'deploy-grev27-pool-shard.ps1'
    & $shard93
    if ($LASTEXITCODE -ne 0) { throw 'orchestrator shard redeploy failed during ordered recovery' }
    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip219 -Port 31352) {
        $remote219 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo219Win)\deploy\cluster-members\gaming-worker-a\deploy-grev27-pool-shard.ps1`""
        Invoke-AlfaRemote219Ssh -RemoteCommand $remote219 -Label 'gaming-a redeploy shard (ordered recovery)'
    }
    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip59 -Port 31351) {
        $remote59 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo59Win)\deploy\cluster-members\gaming-worker-c\deploy-grev27-pool-shard.ps1`""
        Invoke-AlfaRemote59Ssh -RemoteCommand $remote59 -Label 'gaming-c redeploy shard (ordered recovery)'
    }
    if (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip249 -Port 31358) {
        $remote249 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo249Win)\deploy\cluster-members\gaming-worker-b\deploy-grev27-pool-shard.ps1`""
        Invoke-AlfaRemote249Ssh -RemoteCommand $remote249 -Label 'gaming-b redeploy shard (ordered recovery)'
    }
    Stop-AlfaPhase
    Invoke-AlfaRemote111 -Subcommand $(if ($InferenceMode -eq 'Pool72') { 'start-pool72' } elseif ($InferenceMode -eq 'Pool80') { 'start-pool80' } else { 'start-pool' }) -Label 'hub start-pool (ordered recovery: hub shard + coordinator)'
}

function Invoke-AlfaAssertCoordinatorComputeReady {
    # Gate: nothing (LiteLLM keep-warm, contracts-bot, real users) hits the coordinator
    # until a real decode proves the whole shard pool computes. One ordered recovery on fail.
    if ($SkipVerify) {
        Write-AlfaLog -Level WARN -Message 'Skipping coordinator compute self-test (--SkipVerify)'
        return
    }
    Start-AlfaPhase 'Coordinator compute self-test (real decode before live traffic)'
    if (Test-Alfa111CoordinatorComputeReady) {
        Write-AlfaLog -Level OK -Message 'Coordinator compute self-test OK (pool proven before keep-warm/live traffic)'
        Stop-AlfaPhase
        return
    }
    Invoke-AlfaForcePoolOrderedRecovery
    if (Test-Alfa111CoordinatorComputeReady) {
        Write-AlfaLog -Level OK -Message 'Coordinator compute self-test OK after ordered recovery'
        Stop-AlfaPhase
        return
    }
    Stop-AlfaPhase -Result FAIL
    throw 'Coordinator compute self-test still failing after ordered recovery. Run a full stop then start; inspect shard rpc-server logs for the wedged backend.'
}

function Invoke-AlfainferenceKeepWarm111 {
    Start-AlfaPhase 'hub inference keep-warm (post-start, localhost LiteLLM)'
    # B42: pool health is already proven by the coordinator self-test gate. Do NOT probe
    # shard RPC ports (inference_SKIP_VERIFY=1) - the warm decode itself is the health signal.
    # contracts-bot is a separate app stack (not on hub) - warming it is not the cluster
    # start's job. Disable it here so an absent apps:8002 cannot stall keep-warm (was 133s).
    $repo111 = $script:AlfaCfg.Repo111
    $warmEnv = 'inference_SKIP_VERIFY=1 inference_WARM_CONTRACTS_BOT=0 inference_WARM_LITELLM_BASE=http://127.0.0.1:8413'
    $warmScript = Join-AlfaRemoteScript $repo111 'scripts/keep-inference-warm.sh'
    $inner = "${warmEnv} ALFA_BRAIN_ENV=${repo111}/deploy/.env bash $warmScript"
    Invoke-AlfaRemote111Raw -InnerBashCommand $inner -Label 'keep-inference-warm on hub' -AllowFailure
    Stop-AlfaPhase
}

function Invoke-AlfaVerifyCluster {
    if ($SkipVerify) {
        Write-AlfaLog -Level WARN -Message 'Skipping post-start verify (--SkipVerify)'
        return
    }
    Start-AlfaPhase 'Post-start verify (from orchestrator)'

    $ip111 = $script:AlfaCfg.Ip111
    $ipHub = $script:AlfaCfg.IpHub
    $loginTs = $script:AlfaCfg.LoginUrl

    $checks = @(
        @{ Url = "http://${ip111}:31360/health"; Name = '27B coordinator'; TimeoutSec = 900; RequestTimeoutSec = 15 }
        @{ Url = "http://$($script:AlfaCfg.Ip110):11435/api/tags"; Name = 'embed sidecar (rag CPU)'; TimeoutSec = 120 }
        @{ Url = "http://$($script:AlfaCfg.Ip110):8360/health"; Name = 'rerank sidecar (rag CPU)'; TimeoutSec = 120 }
        @{ Url = "http://${ip111}:8420/health"; Name = 'brain API'; TimeoutSec = 120 }
        @{ Url = "http://${ip111}:8413/health/liveliness"; Name = 'LiteLLM'; TimeoutSec = 120 }
        @{ Url = "http://${ipHub}:8420/alfa-ai/login"; Name = 'alfa-ai website (console/login, inference edge)'; TimeoutSec = 120 }
        @{ Url = $loginTs; Name = 'alfa-ai website ( console/login)'; TimeoutSec = 120; Optional = $true }
    )

    foreach ($c in $checks) {
        $timeoutSec = 120
        if ($c.ContainsKey('TimeoutSec') -and $null -ne $c['TimeoutSec']) {
            $timeoutSec = $c['TimeoutSec']
        }
        $reqTimeout = 5
        if ($c.ContainsKey('RequestTimeoutSec') -and $null -ne $c['RequestTimeoutSec']) {
            $reqTimeout = $c['RequestTimeoutSec']
        }
        $intervalSec = 5
        if ($c.ContainsKey('IntervalSec') -and $null -ne $c['IntervalSec']) {
            $intervalSec = $c['IntervalSec']
        }
        $checkUrl = $c['Url']
        $checkName = $c['Name']
        $ok = Wait-AlfaHttpPoll -Url $checkUrl -TimeoutSec $timeoutSec -IntervalSec $intervalSec -RequestTimeoutSec $reqTimeout
        if (-not $ok) {
            $optional = $c.ContainsKey('Optional') -and $c['Optional']
            if ($optional) {
                Write-AlfaLog -Level WARN -Message ("Optional verify skipped (unreachable from orchestrator): {0} ({1})" -f $checkName, $checkUrl)
                continue
            }
            throw ("Post-start verify failed: {0} ({1})" -f $checkName, $checkUrl)
        }
        Write-AlfaLog -Level OK -Message ("Verify OK: {0}" -f $checkName)
    }

    Stop-AlfaPhase
}

function Invoke-AlfaRefreshIncidentMetricsBearer107 {
    # After brain :8420 is up. Same script as the 2h cron on monitor. Never restart Prometheus.
    # credentials_file is read per HTTP request (FileSecret.Fetch in RoundTrip):
    #   https://prometheus.io/docs/prometheus/latest/configuration/configuration/#http_config
    #   https://github.com/prometheus/common/blob/main/config/http_config.go
    # OpenSSH BatchMode / ConnectTimeout: https://man.openbsd.org/ssh_config.5
    Start-AlfaPhase 'monitor incident-metrics bearer refresh'
    $brainUrl = ('http://{0}:8420/health' -f $script:AlfaCfg.Ip111)
    $brainOk = Wait-AlfaHttpPoll -Url $brainUrl -TimeoutSec 60 -IntervalSec 5 -RequestTimeoutSec 5
    if (-not $brainOk) {
        Write-AlfaLog -Level WARN -Message ('Brain {0} not ready -- skip bearer refresh (refresh script would skip anyway). 2h cron on monitor still applies.' -f $brainUrl)
        Stop-AlfaPhase -Result SKIP
        return
    }
    $key = Get-AlfaSsh107KeyPath
    if (-not $key) {
        Write-AlfaLog -Level WARN -Message 'Missing orchestrator SSH key id_ed25519_93_107 -- skip bearer refresh (2h cron on monitor still applies). See docs/ALFA_AI_OPERATIONAL_ALERTS.md'
        Stop-AlfaPhase -Result SKIP
        return
    }
    $target = $script:AlfaCfg.Ssh107
    $remote = 'bash /home/operator/monitoring/scripts/refresh-alfa-ai-prometheus-bearer.sh'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sshOut = ''
    $exitCode = 1
    try {
        Write-AlfaLog -Level CMD -Message ("ssh {0} :: {1}" -f $target, $remote)
        $sshOut = (& ssh -o BatchMode=yes -o ConnectTimeout=20 -i $key $target $remote 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $joined = $sshOut.Trim()
    if (-not [string]::IsNullOrWhiteSpace($joined)) {
        foreach ($line in ($joined -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match 'ERROR|FAIL') {
                Write-AlfaLog -Level WARN -Message $line
            } else {
                Write-AlfaLog -Level INFO -Message $line
            }
        }
    }
    if ($exitCode -ne 0) {
        Write-AlfaLog -Level WARN -Message (
            'Incident-metrics bearer refresh on monitor failed (exit {0}). Pool start continues. If refresh token is dead, Path A/B in docs/ALFA_AI_OPERATIONAL_ALERTS.md. Output: {1}' -f $exitCode, $joined
        )
        Stop-AlfaPhase -Result SKIP
        return
    }
    Write-AlfaLog -Level OK -Message 'Incident-metrics bearer refreshed on monitor (no Prometheus restart)'
    Stop-AlfaPhase
}

function Invoke-AlfaStopAutonomous {
    Start-AlfaPhase 'Stop autonomous hosts'

    # Edge on inference is protected. apps postgres/redis/bots are separate (not cluster stop).
    if ($SkipEdge) {
        Write-AlfaLog -Level WARN -Message 'SkipEdge provided (edge start is controlled at start time; down is intentionally skipped for protection)'
    }

    if (-not (Test-Path -LiteralPath $script:AlfaCfg.ShardsFile)) {
        Write-AlfaLog -Level INFO -Message 'No active shard list; rebuilding from last gaming selection for stop targeting'
        $stopProfile = if ($InferenceMode -eq 'Pool72') { 'Pool72' } elseif ($InferenceMode -eq 'Pool80') { 'Pool80' } else { 'inference' }
        $resolved = Resolve-AlfainferenceActiveShards -LlcDir $LlcDir -Mode Last -ShardProfile $stopProfile
        $script:AlfaCfg.ShardsFile = $resolved.ActivePath
    }

    Start-AlfaPhase 'inference inference-stop-local'
    Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh148 `
        -RemoteCommand "HOST_LABEL=148 bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo148 'deploy/cluster-members/_common/inference-stop-local.sh')" `
        -Label 'inference inference-stop-local'
    Stop-AlfaPhase

    Start-AlfaPhase 'orchestrator inference-stop-local'
    Invoke-AlfaWslBashScript -ScriptPath (Join-Path $CommonDir 'inference-stop-local.sh') -EnvPrefix (Get-AlfaWsl93EnvPrefix)
    Stop-AlfaPhase

    if (-not (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip248 -Port 31355)) {
        Write-AlfaLog -Level INFO -Message 'secondary stop-shard skipped (not in active shard list)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip248)) {
        Write-AlfaLog -Level WARN -Message 'secondary stop-shard skipped (unreachable; :31355 likely already down)'
    } else {
        Start-AlfaPhase 'gpu-248 shard stop (:31355)'
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh248 `
            -RemoteCommand "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo248 'deploy/cluster-members/pool-shard-secondary/operator-cluster-248.sh') stop-shard" `
            -Label 'secondary stop-shard'
        Stop-AlfaPhase
    }

    if (-not (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip100 -Port 31354)) {
        Write-AlfaLog -Level INFO -Message 'pool-opt-in stop-shard skipped (not in active shard list)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip100)) {
        Write-AlfaLog -Level WARN -Message 'pool-opt-in stop-shard skipped (unreachable; :31354 likely already down)'
    } else {
        Start-AlfaPhase 'VM100 shard stop (:31354)'
        Invoke-AlfaRemoteSsh -Target $script:AlfaCfg.Ssh100 `
            -RemoteCommand "bash $(Join-AlfaRemoteScript $script:AlfaCfg.Repo100 'deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh') stop-shard" `
            -Label 'pool-opt-in stop-shard'
        Stop-AlfaPhase
    }

    if (Test-AlfaTrainLockIncludes219) {
        Write-AlfaLog -Level INFO -Message 'gaming-a stop skipped (train lock INCLUDE_219=1)'
    } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip219)) {
        Write-AlfaLog -Level WARN -Message 'gaming-a stop skipped (unreachable; shard likely already down)'
    } else {
        $inActive219 = Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip219 -Port 31352
        if ($inActive219) {
            Start-AlfaPhase 'gaming-a stop inference shard + TCP closed'
        } else {
            Start-AlfaPhase 'gaming-a leftover stop inference shard + WSL closed'
            Write-AlfaLog -Level INFO -Message 'gaming-a stop (not in active shard list; cleaning leftover llamacpp-rpc*)'
        }
        # Use the Windows gaming-stop script (WSL path + markers). Bare remote
        # wsl -lc previously returned 0s with no stdout (silent no-op).
        $stop219 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo219Win)\deploy\cluster-members\gaming-worker-a\gaming-stop-for-session.ps1`" -NoPause"
        Invoke-AlfaRemote219Ssh -RemoteCommand $stop219 -Label 'gaming-a gaming-stop-for-session'
        if (-not $SkipVerify) {
            # LAN :31352 stays open via Win10 portproxy; verify inside WSL.
            Test-Alfa219RpcShardClosedInWsl -Label 'gaming-a rpc shard :31352'
        }
        Stop-AlfaPhase
    }
    if ($InferenceMode -eq 'Pool72' -or $InferenceMode -eq 'Pool80') {
        if (Test-AlfaTrainLockPresent) {
            Write-AlfaLog -Level INFO -Message 'gaming-c/gaming-b Pool72/80 stop skipped (alfa-train.lock; do not docker on train GPUs)'
        } else {
        if (-not (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip59 -Port 31351)) {
            Write-AlfaLog -Level INFO -Message 'gaming-c stop skipped (not in active shard list)'
        } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip59)) {
            Write-AlfaLog -Level WARN -Message 'gaming-c stop skipped (unreachable; shard likely already down)'
        } else {
            Start-AlfaPhase 'gaming-c stop inference shard + WSL closed'
            $stop59 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo59Win)\deploy\cluster-members\gaming-worker-c\gaming-stop-for-session.ps1`" -NoPause"
            Invoke-AlfaRemote59Ssh -RemoteCommand $stop59 -Label 'gaming-c gaming-stop-for-session'
            if (-not $SkipVerify) {
                Test-Alfa59RpcShardClosedInWsl -Label 'gaming-c rpc shard :31351'
            }
            Stop-AlfaPhase
        }
        if (-not (Test-AlfainferenceShardListed -HostIp $script:AlfaCfg.Ip249 -Port 31358)) {
            Write-AlfaLog -Level INFO -Message 'gaming-b stop skipped (not in active shard list)'
        } elseif ($script:AlfaUnreachableStopHosts.Contains($script:AlfaCfg.Ip249)) {
            Write-AlfaLog -Level WARN -Message 'gaming-b stop skipped (unreachable; shard likely already down)'
        } else {
            Start-AlfaPhase 'gaming-b stop inference shard + WSL closed'
            $stop249 = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:AlfaCfg.Repo249Win)\deploy\cluster-members\gaming-worker-b\gaming-stop-for-session.ps1`" -NoPause"
            Invoke-AlfaRemote249Ssh -RemoteCommand $stop249 -Label 'gaming-b gaming-stop-for-session'
            if (-not $SkipVerify) {
                Test-Alfa249RpcShardClosedInWsl -Label 'gaming-b rpc shard :31358'
            }
            Stop-AlfaPhase
        }
        }
    } else {
        Invoke-AlfainferenceLeftoverGamingStop
    }

    Stop-AlfaPhase
}

function Invoke-AlfaOperatorStop111 {
    Start-AlfaPhase 'Automated hub stop'

    Invoke-AlfaRemote111 -Subcommand 'stop' -Label 'hub stop (brain + inference + RAG sidecars)'

    if (-not $SkipVerify) {
        Invoke-AlfaVerifyBrainStopped
        Invoke-AlfaVerify111PoolStopped
    }

    Stop-AlfaPhase
}

$overall = 'OK'
try {
    Write-AlfaLog -Level STEP -Message ("ALFa AI cluster {0} from orchestrator" -f $Action)
    Write-AlfaLog -Level INFO -Message ("Log file: $LogPath")

    if ($Action -eq 'Start') {
        $gaming = Invoke-AlfaResolveGamingShardsForStart
        Invoke-AlfaPreflightRequiredHostsEarly
        Invoke-AlfaPreflightStartNotRunning
        Invoke-AlfaPreflightLocalEarly
        Invoke-AlfainferenceErrorCaptureFirst -Action $Action
        Invoke-AlfaPreflightStart
        Invoke-AlfaPreflightStartDependencies
        Invoke-AlfaWaitGamingShardsOperatorReady -GamingSelection $gaming
        Sync-AlfainferenceActiveShardsToRemotes -LocalActivePath $gaming.ActivePath
        Invoke-AlfaStartShardsAutonomous
        # AssertCoordinatorComputeReady runs inside OperatorStart111 after start-pool,
        # before start-brain (see that function). Do not re-run after LiteLLM is up.
        Invoke-AlfaOperatorStart111
        Invoke-AlfaStartEdgeHub
        Invoke-AlfaVerifyCluster
        Invoke-AlfaRefreshIncidentMetricsBearer107
        Invoke-AlfainferenceKeepWarm111
    } else {
        Invoke-AlfainferenceErrorCaptureFirst -Action $Action
        Invoke-AlfaPreflightStop
        if (-not $SkipPull) {
            Invoke-AlfaPreflightGitSyncAll -NonFatal
        }
        # Rebuild + sync active list so stop targets gaming hosts and verify checks them.
        $stopProfile = if ($InferenceMode -eq 'Pool72') { 'Pool72' } elseif ($InferenceMode -eq 'Pool80') { 'Pool80' } else { 'inference' }
        $stopShards = Resolve-AlfainferenceActiveShards -LlcDir $LlcDir -Mode Last -ShardProfile $stopProfile
        $script:AlfaCfg.ShardsFile = $stopShards.ActivePath
        Sync-AlfainferenceActiveShardsToRemotes -LocalActivePath $stopShards.ActivePath
        Invoke-AlfaOperatorStop111
        Invoke-AlfaStopAutonomous
        Invoke-AlfaStopRagSidecars
        Invoke-AlfaVerifyClusterStopped
    }

    Write-AlfaPhaseSummary -OverallResult 'OK' -Header "CLUSTER $Action COMPLETE"
    Write-AlfaLog -Level OK -Message ("Cluster $Action finished successfully.")
} catch {
    $overall = 'FAIL'
    Write-AlfaLog -Level ERROR -Message $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-AlfaLog -Level ERROR -Message $_.ScriptStackTrace
    }
    Write-AlfaPhaseSummary -OverallResult 'FAIL' -Header "CLUSTER $Action FAILED"
    Write-AlfaLog -Level ERROR -Message ("Cluster $Action failed. See log: $LogPath")
    exit 1
} finally {
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $poolSession = if ($script:inferenceLogSessionId) { $script:inferenceLogSessionId } else { Get-inferenceLogSessionId -RepoRoot $RepoRoot }
    if ($poolSession) {
        try {
            Write-AlfaStepLedger -RepoRoot $RepoRoot -SessionId $poolSession
        } catch {
            Write-AlfaLog -Level WARN -Message ("step ledger skipped: $($_.Exception.Message)")
        }
        try {
            Stop-inferenceLogSession -RepoRoot $RepoRoot -SessionId $poolSession -OrchestratorLogPath $LogPath `
                -Ssh100 $script:AlfaCfg.Ssh100 -Ssh248 $script:AlfaCfg.Ssh248 -Ssh111 $script:AlfaCfg.Ssh111 -Ssh148 $script:AlfaCfg.Ssh148 `
                -Repo100 $script:AlfaCfg.Repo100 -Repo248 $script:AlfaCfg.Repo248 -Repo148 $script:AlfaCfg.Repo148 `
                -Repo111 $script:AlfaCfg.Repo111 -Ip111 $script:AlfaCfg.Ip111
            Write-AlfaLog -Level INFO -Message ("inference errors collected: logs\inference-sessions\$poolSession")
        } catch {
            Write-AlfaLog -Level WARN -Message ("inference log collect failed: $($_.Exception.Message)")
        }
    }
    $ErrorActionPreference = $prevErr
    Stop-AlfaWorkerTranscript
    Write-AlfaLog -Level INFO -Message ("Transcript: $LogPath")
}

exit 0

