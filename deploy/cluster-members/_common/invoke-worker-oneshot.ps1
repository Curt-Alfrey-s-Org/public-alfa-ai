<#
.SYNOPSIS
    One-command entry for a Windows worker run from a local git checkout.
    Self-pulls, maps SMB shares, then delegates to deploy-worker-lan.ps1 using
    the local repo as WorkerDir (no SMB robocopy staging needed).

.DESCRIPTION
    Use this when each worker has its own git clone of alfa-ai (the standard
    rollout pattern). The flow is:

        0. Env readiness: git, Docker Desktop up, hub reachable.
        1. Nvidia preflight so $env:ALFA_NODE_GPU_CLASS is set.
        2. (optional) Configure Docker Hub mirror to hub.
        3. git pull --ff-only origin main inside the checkout.
        4. Ensure SMB drives (Y: petals-wheels, Z: huggingface) are mapped.
        5. Optional member .env.worker for Dockge port overrides.
        6. Invoke-AlfaWorkerDeploy with WorkerDir = repo root.

    Every run writes a UTF-8 transcript to:
        $RepoRoot\deploy\cluster-members\<member>\logs\run-<UTC>.log
    so the operator can paste the full log on failure. Each phase prints a
    timestamped banner and the total elapsed time; silent native commands
    (docker load / docker build / docker compose) get a heartbeat every 15s.

.EXAMPLE
    . "$PSScriptRoot\..\_common\invoke-worker-oneshot.ps1"
    Invoke-AlfaWorkerOneshot -MachineName 'gaming-worker-b' -MachineIP 'orchestrator' `
        -MemberFolder 'gaming-worker-b-249' -DockgePortDefault '5001'
#>

function Invoke-AlfaWorkerOneshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$MachineIP,
        [Parameter(Mandatory)] [string]$MemberFolder,
        [string]$DockgePortDefault = '5001',
        [switch]$SkipPull,
        [switch]$SkipMirror,
        [switch]$NoTranscript,
        [switch]$SkipAutoBootstrap,
        [switch]$ForceBuild
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Resolve repo root: this helper lives at <repo>/deploy/cluster-members/_common/
    $CommonDir = $PSScriptRoot
    $RepoRoot  = (Resolve-Path (Join-Path $CommonDir '..\..\..')).Path

    if ($RepoRoot.StartsWith('\\')) {
        throw "[oneshot] This script must be run from a LOCAL git checkout, not from SMB ($RepoRoot). Clone the repo on this host first."
    }

    # If $RepoRoot is NOT a real git repo (fresh box, or an old robocopy /
    # stage-cluster-members.ps1 SMB mirror), auto-delegate to bootstrap-worker.ps1.
    # Rationale: a first-time machine cannot know it needs to run bootstrap
    # separately -- discovering that via a thrown error is a bad UX. bootstrap
    # installs git (idempotent), clones the repo, then re-invokes run.ps1 from
    # the clean checkout. We return immediately afterwards so the inner call
    # owns transcript/phase state and we do not nest those.
    $gitDir = Join-Path $RepoRoot '.git'
    if (-not (Test-Path $gitDir)) {
        $bootstrapCandidates = @(
            (Join-Path $RepoRoot 'scripts\bootstrap-worker.ps1'),
            "\\hub\temp\cluster_members\_common\repo\scripts\bootstrap-worker.ps1"
        )
        $bootstrap = $bootstrapCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($bootstrap -and -not $SkipAutoBootstrap) {
            Write-Host ''
            Write-Host "[oneshot] $RepoRoot is not a git clone yet (bootstrap not run on this machine)." -ForegroundColor Yellow
            Write-Host "[oneshot] Auto-bootstrap: delegating to $bootstrap" -ForegroundColor Cyan
            Write-Host "[oneshot]   -Member   $MemberFolder" -ForegroundColor Cyan
            Write-Host "[oneshot]   -RepoRoot $RepoRoot" -ForegroundColor Cyan
            Write-Host "[oneshot] (pass -SkipAutoBootstrap on the run.ps1 command line to opt out)" -ForegroundColor DarkGray
            Write-Host ''
            & $bootstrap -Member $MemberFolder -RepoRoot $RepoRoot
            $bsExit = $LASTEXITCODE
            if ($bsExit -and $bsExit -ne 0) {
                throw "[oneshot] bootstrap-worker.ps1 exited with code $bsExit. See its output above."
            }
            return
        }

        Write-Host ''
        Write-Host "[oneshot] $RepoRoot is NOT a git clone (.git directory missing)." -ForegroundColor Red
        Write-Host '  Running from an SMB-mirrored worker dir cannot pick up pushed fixes,' -ForegroundColor Yellow
        Write-Host '  and auto-bootstrap is unavailable (bootstrap-worker.ps1 not found or opted out).' -ForegroundColor Yellow
        Write-Host '  Fix (one time, per machine):' -ForegroundColor Yellow
        Write-Host '    winget install --id Git.Git -e   # if git is missing' -ForegroundColor Yellow
        Write-Host "    git clone https://github.com/example/alfa-ai.git $RepoRoot" -ForegroundColor Yellow
        Write-Host "    cd $RepoRoot" -ForegroundColor Yellow
        Write-Host "    .\deploy\cluster-members\$MemberFolder\run.ps1" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Or use the bootstrap one-liner (clones + deploys in one shot):' -ForegroundColor Yellow
        Write-Host '    powershell -ExecutionPolicy Bypass -File ' -NoNewline -ForegroundColor Yellow
        Write-Host "\\hub\temp\cluster_members\_common\repo\scripts\bootstrap-worker.ps1 -Member $MemberFolder -RepoRoot $RepoRoot" -ForegroundColor Yellow
        Write-Host ''
        throw "[oneshot] $RepoRoot is not a git repo -- see remediation above."
    }

    # --- Bring up shared verbose/logging helpers BEFORE anything else.
    $loggingHelpers = Join-Path $CommonDir 'logging-helpers.ps1'
    if (Test-Path $loggingHelpers) {
        . $loggingHelpers
        Reset-AlfaPhaseTimings
    } else {
        throw "[oneshot] Missing $loggingHelpers. Run 'git pull' in $RepoRoot."
    }

    # --- Transcript: captures every Write-Host and every native-command line
    # to a UTF-8 log file the operator can paste wholesale.
    $transcriptPath = $null
    if (-not $NoTranscript) {
        $transcriptPath = Get-AlfaWorkerLogPath -RepoRoot $RepoRoot -MemberFolder $MemberFolder -Prefix "run-$MachineName"
        Start-AlfaWorkerTranscript -Path $transcriptPath
    }

    $oneshotStart = Get-Date
    $overallResult = 'OK'
    $failurePhase  = $null
    $failureError  = $null

    try {
        Write-Host ''
        Write-Host ('#' * 66) -ForegroundColor Cyan
        Write-AlfaLog -Level STEP -Message "ALFa AI One-Shot Worker Deploy: $MachineName ($MachineIP)"
        Write-AlfaLog -Level INFO -Message "  RepoRoot: $RepoRoot"
        Write-AlfaLog -Level INFO -Message "  Member:   $MemberFolder"
        Write-AlfaLog -Level INFO -Message "  Started:  $(Get-Date -Format o)"
        if ($transcriptPath) {
            Write-AlfaLog -Level INFO -Message "  Log file: $transcriptPath"
        }
        Write-Host ('#' * 66) -ForegroundColor Cyan

        $envScript       = Join-Path $CommonDir 'ensure-worker-environment.ps1'
        $preflightScript = Join-Path $CommonDir 'nvidia-preflight.ps1'
        $smbScript       = Join-Path $CommonDir 'ensure-smb-drives.ps1'
        $deployLibScript = Join-Path $CommonDir 'deploy-worker-lan.ps1'

        $initScript = Join-Path $CommonDir 'initialize-windows-deploy.ps1'
        if (Test-Path $initScript) {
            . $initScript
        }

        # 0. Environment readiness (self-healing): installs git if missing,
        #    starts Docker Desktop and waits for the engine, probes the hub.
        #    Must come BEFORE anything that shells out to git/docker/SMB.
        Start-AlfaPhase '0/6 Environment readiness (git + Docker Desktop + hub)'
        if (Test-Path $envScript) {
            . $envScript
            Ensure-AlfaWorkerEnvironment
            Stop-AlfaPhase -Result OK
        } else {
            Write-AlfaLog -Level WARN -Message 'ensure-worker-environment.ps1 missing; skipping readiness checks.'
            Stop-AlfaPhase -Result SKIP -Note 'helper missing'
        }

        # 1. Preflight: GPU detection -> ALFA_NODE_GPU_CLASS
        Start-AlfaPhase '1/6 GPU preflight'
        if (Test-Path $preflightScript) {
            . $preflightScript
            Invoke-AlfaNvidiaPreflight -Role 'gpu-worker' | Out-Null
            Write-AlfaLog -Level INFO -Message ("ALFA_NODE_GPU_CLASS = " + ($env:ALFA_NODE_GPU_CLASS))
            Stop-AlfaPhase -Result OK
        } else {
            Write-AlfaLog -Level WARN -Message "nvidia-preflight.ps1 missing; skipping GPU detect."
            Stop-AlfaPhase -Result SKIP -Note 'helper missing'
        }

        # 2. Docker Hub mirror (optional; skip Windows daemon.json on WSL Engine)
        Start-AlfaPhase '2/6 Docker Hub mirror (optional)'
        if (-not $SkipMirror) {
            Initialize-AlfaWindowsDockerMirror
            Stop-AlfaPhase -Result OK
        } else {
            Stop-AlfaPhase -Result SKIP -Note '-SkipMirror'
        }

        # 3. Git pull -- must succeed. Silently running stale code has been the
        # #1 source of "but I already fixed that" loops on this project.
        Start-AlfaPhase '3/6 git pull --ff-only'
        if (-not $SkipPull) {
            Push-Location $RepoRoot
            try {
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                Write-AlfaLog -Level CMD -Message "$ git pull --ff-only origin main"
                & git pull --ff-only origin main
                $exit = $LASTEXITCODE
                $ErrorActionPreference = $prev
                if ($exit -ne 0) {
                    Write-AlfaLog -Level ERROR -Message "git pull --ff-only failed (exit $exit) in $RepoRoot."
                    Write-AlfaLog -Level WARN  -Message '  Common causes:'
                    Write-AlfaLog -Level WARN  -Message '    - Local uncommitted changes that block a fast-forward.'
                    Write-AlfaLog -Level WARN  -Message "      Fix:  cd $RepoRoot ; git status ; git stash"
                    Write-AlfaLog -Level WARN  -Message '    - Diverged branch (someone force-pushed on main).'
                    Write-AlfaLog -Level WARN  -Message "      Fix:  cd $RepoRoot ; git fetch ; git reset --hard origin/main"
                    Write-AlfaLog -Level WARN  -Message '    - No network / no SSH key for github.'
                    Stop-AlfaPhase -Result FAIL -Note "exit $exit"
                    throw "[oneshot] git pull failed -- refusing to run stale code. Pass -SkipPull only if you *really* mean it."
                }
                Stop-AlfaPhase -Result OK
            } finally {
                Pop-Location
            }
        } else {
            Write-AlfaLog -Level WARN -Message '-SkipPull: skipping git pull. You had better know what is in this tree.'
            Stop-AlfaPhase -Result SKIP -Note '-SkipPull'
        }

        # 4. SMB drive mappings (idempotent)
        Start-AlfaPhase '4/6 SMB drive mappings (Y:, Z:)'
        if (Test-Path $smbScript) {
            . $smbScript
            Ensure-AlfaSmbDrives
            Stop-AlfaPhase -Result OK
        } else {
            Write-AlfaLog -Level WARN -Message "ensure-smb-drives.ps1 missing; skipping SMB map."
            Stop-AlfaPhase -Result SKIP -Note 'helper missing'
        }

        # 5. Optional member env (Dockge port) -- no Petals worker env.
        Start-AlfaPhase '5/6 Resolve member env'
        $localEnv = Join-Path $RepoRoot "deploy\cluster-members\$MemberFolder\.env.worker"
        if (Test-Path $localEnv) {
            Write-AlfaLog -Level OK -Message ".env.worker present at $localEnv (legacy name; Dockge uses ALFA_DOCKGE_HOST_PORT if set)"
            Stop-AlfaPhase -Result OK -Note 'local'
        } else {
            Write-AlfaLog -Level WARN -Message 'No .env.worker; Dockge will use default port'
            Stop-AlfaPhase -Result SKIP -Note 'no env'
        }

        # 6. Delegate to LAN-first deployer
        Start-AlfaPhase '6/6 Invoke-AlfaWorkerDeploy (wheels + image + compose up)'
        if (-not (Test-Path $deployLibScript)) {
            Stop-AlfaPhase -Result FAIL -Note 'deploy-worker-lan.ps1 missing'
            throw "[oneshot] Missing $deployLibScript. Run 'git pull' in $RepoRoot."
        }
        . $deployLibScript
        Invoke-AlfaWorkerDeploy `
            -MachineName       $MachineName `
            -MachineIP         $MachineIP `
            -WorkerDir         $RepoRoot `
            -DockgePortDefault $DockgePortDefault `
            -ForceBuild:$ForceBuild
        Stop-AlfaPhase -Result OK
    }
    catch {
        $overallResult = 'FAIL'
        $failurePhase  = Get-AlfaCurrentPhaseName
        $failureError  = $_
        # Close the in-flight phase with FAIL (Stop-AlfaPhase is a no-op if
        # the stack is already empty).
        Stop-AlfaPhase -Result FAIL -Note $_.Exception.Message
        Write-Host ''
        Write-AlfaLog -Level ERROR -Message "UNHANDLED EXCEPTION in phase: $failurePhase"
        Write-AlfaLog -Level ERROR -Message ($_.Exception.Message)
        if ($_.ScriptStackTrace) {
            Write-Host '---- Stack trace ----' -ForegroundColor Red
            Write-Host $_.ScriptStackTrace -ForegroundColor Red
            Write-Host '---- /Stack trace ---' -ForegroundColor Red
        }
    }
    finally {
        $totalSec = [int]((Get-Date) - $oneshotStart).TotalSeconds
        Write-AlfaPhaseSummary -OverallResult $overallResult -Header "DEPLOY $overallResult ($MachineName, ${totalSec}s total)"

        if ($transcriptPath) {
            Write-Host ''
            Write-AlfaLog -Level INFO -Message "Full transcript: $transcriptPath"
            if ($overallResult -ne 'OK') {
                Write-AlfaLog -Level WARN -Message "Paste the transcript into chat so we can diagnose."
            }
            Stop-AlfaWorkerTranscript
        }

        if ($overallResult -ne 'OK') {
            # Re-raise so the caller sees a nonzero exit (important for CI /
            # 'operator will see red if it broke' behaviour). Preserve the
            # original exception; do not synthesize a new one.
            if ($failureError) { throw $failureError }
            throw "[oneshot] Deploy failed in phase '$failurePhase'."
        }
    }

    # Optional compose steps (e.g. Dockge agent) may leave LASTEXITCODE=1 even
    # when the worker stack deployed successfully. Force success exit for callers
    # (build-start-*.ps1) that gate on run.ps1 exit code.
    exit 0
}
