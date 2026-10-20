<#
.SYNOPSIS
    Shared build-start entry for Windows gaming workers (gaming-a/gaming-c/gaming-b).

.DESCRIPTION
    1. PowerShell transcript -> deploy\cluster-members\<member>\logs\build-start-*.log
    2. Optional Windows Firewall (31330 DHT, 31331 monitor).
    3. Deploy via local git checkout (run.ps1) or SMB deploy.ps1.
    4. Post-deploy smoke checks.
    5. SCP transcript + docker logs to operator@orchestrator hub (unless -SkipLogUpload).

.EXAMPLE
    . "$PSScriptRoot\invoke-build-start-worker.ps1"
    Invoke-AlfaBuildStartWorker -MemberDir $MemberDir -MemberFolder 'gaming-worker-a-219' `
        -MachineName 'gaming-worker-a' -MachineIP 'orchestrator' -FirewallPrefix 'ALFa gaming-worker-a-219'
#>

function Invoke-AlfaBuildStartWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MemberDir,
        [Parameter(Mandatory)] [string]$MemberFolder,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$MachineIP,
        [Parameter(Mandatory)] [string]$FirewallPrefix,
        [int[]]$FirewallTcpPorts = @(31350, 31351, 31360),
        [int]$MonitorPort = 31360,
        [switch]$SkipNatPortProxy,
        [switch]$SkipPull,
        [switch]$SkipMirror,
        [switch]$SkipFirewall,
        [switch]$SkipAutoBootstrap,
        [switch]$SkipSmoke,
        [switch]$SkipLogUpload,
        [switch]$SkipPrep,
        [switch]$ForceBuild,
        [string]$hubSmbUser = $env:USERNAME
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $commonDir = Join-Path (Split-Path -Parent $MemberDir) '_common'
    $repoRoot = (Resolve-Path (Join-Path $MemberDir '..\..\..')).Path
    $transcriptPath = $null
    $overallOk = $true
    $deployError = $null

    $loggingHelpers = Join-Path $commonDir 'logging-helpers.ps1'
    if (Test-Path $loggingHelpers) {
        . $loggingHelpers
        $transcriptPath = Get-AlfaWorkerLogPath -RepoRoot $repoRoot -MemberFolder $MemberFolder -Prefix 'build-start'
        Start-AlfaWorkerTranscript -Path $transcriptPath
    } else {
        $logDir = Join-Path $MemberDir 'logs'
        if (-not (Test-Path $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force
        }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z'
        $transcriptPath = Join-Path $logDir "build-start-$stamp.log"
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
        Start-Transcript -Path $transcriptPath -Force | Out-Null
        Write-Host "Transcript ON -> $transcriptPath" -ForegroundColor Green
    }

    try {
        Write-Host ''
        Write-Host "== ALFa build-start: $MemberFolder ($MachineIP) ==" -ForegroundColor Cyan
        Write-Host "  Transcript: $transcriptPath" -ForegroundColor DarkGray
        Write-Host ''

        $initScript = Join-Path $commonDir 'initialize-windows-deploy.ps1'
        if (Test-Path $initScript) {
            . $initScript
            if (-not (Test-AlfaWindowsDockerEngine)) {
                throw 'Docker engine not reachable (WSL: wsl -d Ubuntu docker ps)'
            }
        }

        $natScript = Join-Path $commonDir 'install-wsl-nat-portproxy.ps1'
        if (-not $SkipNatPortProxy -and (Test-Path $natScript)) {
            . $natScript
            if (Test-AlfaWslNatPortProxyRequired) {
                Write-Host '== Pre-deploy portproxy sync ==' -ForegroundColor Cyan
                Sync-AlfaWslNatPortProxy -TcpPorts $FirewallTcpPorts -DisplayNamePrefix $FirewallPrefix `
                    -RepoRoot $repoRoot -SkipFirewall | Out-Null
                Write-Host ''
            }
        }

        $fwScript = Join-Path $commonDir 'open-worker-lan-firewall.ps1'
        if (-not $SkipFirewall -and (Test-Path $fwScript)) {
            . $fwScript
            Open-AlfaWorkerLanFirewall -DisplayNamePrefix $FirewallPrefix -TcpPorts $FirewallTcpPorts -Profile Any
        }

        $prepScript = Join-Path $commonDir 'prep-windows-blackwell-worker.ps1'
        if (-not $SkipPrep -and (Test-Path $prepScript)) {
            $yWheel = Get-ChildItem -Path 'Y:\cuda-blackwell' -Filter 'bitsandbytes-0.45*.whl' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($yWheel) {
                Write-Host "  Prep: Y: wheel hub already mapped ($($yWheel.Name)) - skip prep" -ForegroundColor DarkGray
            } else {
                Write-Host '  Prep: mapping SMB + validating env (hub SMB user required)' -ForegroundColor Cyan
                & $prepScript -MemberFolder $MemberFolder -SmbUser $hubSmbUser -RepoRoot $repoRoot
            }
        }

        $runScript = Join-Path $MemberDir 'run.ps1'
        $deployScript = Join-Path $MemberDir 'deploy.ps1'

        if ((Test-Path (Join-Path $repoRoot '.git')) -and (Test-Path $runScript)) {
            Write-Host '  Deploy path: local git checkout -> run.ps1' -ForegroundColor Cyan
            Write-Host "  RepoRoot:    $repoRoot" -ForegroundColor DarkGray
            & $runScript `
                -SkipPull:$SkipPull `
                -SkipMirror:$SkipMirror `
                -SkipAutoBootstrap:$SkipAutoBootstrap `
                -ForceBuild:$ForceBuild `
                -NoTranscript
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "run.ps1 failed (exit $LASTEXITCODE)"
            }
        } elseif (Test-Path $deployScript) {
            Write-Host '  Deploy path: SMB / no git -> deploy.ps1' -ForegroundColor Cyan
            Write-Host "  Script:      $deployScript" -ForegroundColor DarkGray
            & $deployScript
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "deploy.ps1 failed (exit $LASTEXITCODE)"
            }
        } else {
            throw "Neither run.ps1 nor deploy.ps1 found under $MemberDir"
        }

        if (-not $SkipSmoke) {
            Write-Host ''
            Write-Host '== Smoke checks ==' -ForegroundColor Cyan
            try {
                & docker ps --format 'table {{.Names}}\t{{.Status}}'
            } catch {
                Write-Host "  docker ps failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } catch {
        $overallOk = $false
        $deployError = $_
        Write-Host ''
        Write-Host "BUILD-START FAILED: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if (Test-Path (Join-Path $commonDir 'logging-helpers.ps1')) {
            Stop-AlfaWorkerTranscript
        } else {
            try { Stop-Transcript | Out-Null } catch { }
        }

        if (-not $SkipLogUpload) {
            $sendScript = Join-Path $commonDir 'send-build-logs-to-148.ps1'
            $sshScript  = Join-Path $commonDir 'ensure-ssh-to-148.ps1'
            $canScp = $true
            if (Test-Path $sshScript) {
                . $sshScript
                if (-not (Test-AlfaSshTo148)) {
                    Write-Host '  SkipLogUpload: SSH key not authorized on inference yet (run ensure-ssh-to-148.ps1)' -ForegroundColor Yellow
                    $canScp = $false
                }
            }
            if ($canScp -and (Test-Path $sendScript)) {
                . $sendScript
                Send-AlfaBuildLogsTo148 `
                    -MemberFolder        $MemberFolder `
                    -RepoRoot            $repoRoot `
                    -BuildTranscriptPath $transcriptPath
            } elseif (-not $canScp) {
                Write-Host "    Transcript local: $transcriptPath" -ForegroundColor DarkGray
            } else {
                Write-Host '  WARN: send-build-logs-to-148.ps1 missing - skip upload' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  SkipLogUpload: logs stay local only' -ForegroundColor Yellow
            Write-Host "    Transcript: $transcriptPath" -ForegroundColor DarkGray
        }

        Write-Host ''
        if ($overallOk) {
            Write-Host "BUILD-START OK ($MemberFolder) - logs on inference under logs/cluster-docker/" -ForegroundColor Green
        } else {
            Write-Host "BUILD-START FAIL ($MemberFolder) - inspect logs on inference; transcript: $transcriptPath" -ForegroundColor Red
        }
    }

    if (-not $overallOk) {
        if ($deployError) { throw $deployError }
        throw "build-start failed for $MemberFolder"
    }
}
