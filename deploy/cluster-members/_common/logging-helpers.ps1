<#
.SYNOPSIS
    Shared verbose/logging helpers for ALFa AI worker scripts.

.DESCRIPTION
    Gives every worker script (invoke-worker-oneshot, deploy-worker-lan,
    ensure-worker-environment, etc.) the same operator-friendly pattern:

      - Timestamped lines so operators can tell scrollback apart from NOW.
      - Per-phase stopwatch -> final summary line ("<phase> OK in 42s").
      - Heartbeat ticker around silent blocking native commands
        (docker load / docker build / docker compose up) so a 10-minute
        build does not look identical to a hang.
      - A consistent transcript location so the operator always knows
        where to find the log after a failed run.

    Public API:
      Start-AlfaPhase   <name>           # banner + push stopwatch
      Stop-AlfaPhase    [-Result OK|FAIL]# pop stopwatch, print elapsed
      Write-AlfaLog     <msg> [-Level]   # timestamped console line
      Invoke-AlfaHeartbeatExec           # run a native command with
                                         # heartbeat every -HeartbeatSec
      Get-AlfaWorkerLogPath <member>     # canonical per-member log path
      Start-AlfaWorkerTranscript <path>  # idempotent Start-Transcript

    Designed for PowerShell 5.1 (default on Win11); works in PS 7 too.
    Pure ASCII (check-ps1-ascii.sh must pass).
#>

Set-StrictMode -Version Latest

if (-not (Test-Path variable:script:AlfaPhaseStack)) {
    $script:AlfaPhaseStack = New-Object System.Collections.Generic.Stack[object]
}

function Get-AlfaTimestamp {
    return (Get-Date -Format 'HH:mm:ss.fff')
}

function Write-AlfaLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR', 'BEAT', 'CMD')]
        [string]$Level = 'INFO',
        [string]$Color
    )
    if (-not $Color) {
        switch ($Level) {
            'STEP'  { $Color = 'Cyan' }
            'OK'    { $Color = 'Green' }
            'WARN'  { $Color = 'Yellow' }
            'ERROR' { $Color = 'Red' }
            'BEAT'  { $Color = 'DarkGray' }
            'CMD'   { $Color = 'Gray' }
            default { $Color = 'White' }
        }
    }
    $line = "[{0}] [{1}] {2}" -f (Get-AlfaTimestamp), $Level.PadRight(5), $Message
    Write-Host $line -ForegroundColor $Color
}

function Start-AlfaPhase {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)] [string]$Name)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $entry = [pscustomobject]@{
        Name      = $Name
        Stopwatch = $sw
        StartedAt = (Get-Date)
    }
    $script:AlfaPhaseStack.Push($entry)
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-AlfaLog -Level STEP -Message "PHASE: $Name"
    Write-Host ('=' * 66) -ForegroundColor Cyan
    # Intentionally no return: callers were getting the raw pscustomobject
    # auto-formatted as a table in the transcript ("Name  Stopwatch  StartedAt"
    # noise between every phase banner and its work).
}

function Stop-AlfaPhase {
    [CmdletBinding()]
    param(
        [ValidateSet('OK', 'FAIL', 'SKIP')]
        [string]$Result = 'OK',
        [string]$Note
    )
    if ($script:AlfaPhaseStack.Count -eq 0) { return }
    $entry = $script:AlfaPhaseStack.Pop()
    $entry.Stopwatch.Stop()
    $secs = [int]$entry.Stopwatch.Elapsed.TotalSeconds
    $level = switch ($Result) { 'OK' { 'OK' } 'FAIL' { 'ERROR' } default { 'WARN' } }
    $suffix = if ($Note) { " ($Note)" } else { '' }
    Write-AlfaLog -Level $level -Message ("PHASE END: {0} -> {1} in {2}s{3}" -f $entry.Name, $Result, $secs, $suffix)

    if (-not (Test-Path variable:script:AlfaPhaseTimings)) {
        $script:AlfaPhaseTimings = New-Object System.Collections.Generic.List[object]
    }
    $script:AlfaPhaseTimings.Add([pscustomobject]@{
        Name    = $entry.Name
        Result  = $Result
        Seconds = $secs
        Note    = $Note
    }) | Out-Null
}

function Write-AlfaPhaseSummary {
    [CmdletBinding()]
    param([string]$OverallResult = 'OK', [string]$Header = 'RUN SUMMARY')
    if (-not (Test-Path variable:script:AlfaPhaseTimings) -or
        $script:AlfaPhaseTimings.Count -eq 0) {
        return
    }
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-AlfaLog -Level STEP -Message $Header
    Write-Host ('=' * 66) -ForegroundColor Cyan
    $total = 0
    foreach ($t in $script:AlfaPhaseTimings) {
        $total += $t.Seconds
        $color = switch ($t.Result) { 'OK' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        $noteStr = if ($t.Note) { " ($($t.Note))" } else { '' }
        $line = "  {0,-6}  {1,5}s  {2}{3}" -f $t.Result, $t.Seconds, $t.Name, $noteStr
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    $resultColor = if ($OverallResult -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("  TOTAL  {0,5}s  ({1})" -f $total, $OverallResult) -ForegroundColor $resultColor
    Write-Host ('=' * 66) -ForegroundColor Cyan
}

function Reset-AlfaPhaseTimings {
    $script:AlfaPhaseStack = New-Object System.Collections.Generic.Stack[object]
    $script:AlfaPhaseTimings = New-Object System.Collections.Generic.List[object]
}

function Get-AlfaCurrentPhaseName {
    if ($script:AlfaPhaseStack.Count -gt 0) {
        return $script:AlfaPhaseStack.Peek().Name
    }
    return '<no phase>'
}

# --------------------------------------------------------------------------
# Invoke-AlfaHeartbeatExec: run a native command with a heartbeat
# --------------------------------------------------------------------------
# WHY: docker load, docker build, docker compose build/up can block the
# console for 5-25 minutes with no output. That is indistinguishable from
# a hang to a watching operator. We launch the command via Start-Process
# -PassThru -NoNewWindow so its stdout/stderr still inherit the console
# (no output lost), then poll WaitForExit($HeartbeatSec*1000) so we can
# print a heartbeat line on every timeout cycle.
function Invoke-AlfaHeartbeatExec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string[]]$ArgumentList,
        [Parameter(Mandatory)] [string]$Label,
        [int]$HeartbeatSec = 15,
        [string]$WorkingDirectory
    )

    if ($FilePath -eq 'docker' -and (Get-Command Resolve-AlfaDockerHeartbeatExec -ErrorAction SilentlyContinue)) {
        $resolved = Resolve-AlfaDockerHeartbeatExec -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
        $FilePath = $resolved.FilePath
        $ArgumentList = $resolved.ArgumentList
        $WorkingDirectory = $resolved.WorkingDirectory
    }

    $displayArgs = ($ArgumentList -join ' ')
    Write-AlfaLog -Level CMD -Message ("$ $FilePath $displayArgs")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add($a) }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        $ended = $proc.WaitForExit([int]($HeartbeatSec * 1000))
        if ($ended) { break }
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        Write-AlfaLog -Level BEAT -Message ("still running: {0} (elapsed {1}s, no hang)" -f $Label, $elapsed)
    }
    $sw.Stop()

    $exit = $proc.ExitCode
    $totalSec = [int]$sw.Elapsed.TotalSeconds

    if ($exit -eq 0) {
        Write-AlfaLog -Level OK -Message ("{0} finished in {1}s (exit 0)" -f $Label, $totalSec)
    } else {
        Write-AlfaLog -Level ERROR -Message ("{0} FAILED in {1}s (exit {2})" -f $Label, $totalSec, $exit)
    }
    return $exit
}

# PS 5.1 compatibility: ProcessStartInfo.ArgumentList was added in .NET 6 /
# PS 7. On PS 5.1 fall back to the classic .Arguments string. We detect at
# runtime by probing a new object.
$__alfaProbePsi = New-Object System.Diagnostics.ProcessStartInfo
$__alfaHasArgList = $null -ne ($__alfaProbePsi.PSObject.Properties['ArgumentList'])

if (-not $__alfaHasArgList) {
    function Invoke-AlfaHeartbeatExec {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [string]$FilePath,
            [Parameter(Mandatory)] [string[]]$ArgumentList,
            [Parameter(Mandatory)] [string]$Label,
            [int]$HeartbeatSec = 15,
            [string]$WorkingDirectory
        )

        if ($FilePath -eq 'docker' -and (Get-Command Resolve-AlfaDockerHeartbeatExec -ErrorAction SilentlyContinue)) {
            $resolved = Resolve-AlfaDockerHeartbeatExec -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
            $FilePath = $resolved.FilePath
            $ArgumentList = $resolved.ArgumentList
            $WorkingDirectory = $resolved.WorkingDirectory
        }

        $sb = New-Object System.Text.StringBuilder
        foreach ($a in $ArgumentList) {
            if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
            if ($a -match '\s|"') {
                [void]$sb.Append('"' + ($a -replace '"', '\"') + '"')
            } else {
                [void]$sb.Append($a)
            }
        }
        $argString = $sb.ToString()

        Write-AlfaLog -Level CMD -Message ("$ $FilePath $argString")

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName         = $FilePath
        $psi.Arguments        = $argString
        $psi.UseShellExecute  = $false
        $psi.CreateNoWindow   = $false
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            $ended = $proc.WaitForExit([int]($HeartbeatSec * 1000))
            if ($ended) { break }
            $elapsed = [int]$sw.Elapsed.TotalSeconds
            Write-AlfaLog -Level BEAT -Message ("still running: {0} (elapsed {1}s, no hang)" -f $Label, $elapsed)
        }
        $sw.Stop()

        $exit = $proc.ExitCode
        $totalSec = [int]$sw.Elapsed.TotalSeconds
        if ($exit -eq 0) {
            Write-AlfaLog -Level OK -Message ("{0} finished in {1}s (exit 0)" -f $Label, $totalSec)
        } else {
            Write-AlfaLog -Level ERROR -Message ("{0} FAILED in {1}s (exit {2})" -f $Label, $totalSec, $exit)
        }
        return $exit
    }
}

# --------------------------------------------------------------------------
# Transcript management
# --------------------------------------------------------------------------
function Get-AlfaWorkerLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$MemberFolder,
        [string]$Prefix = 'run'
    )
    $logDir = Join-Path $RepoRoot "deploy\cluster-members\$MemberFolder\logs"
    if (-not (Test-Path $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    }
    # PS 5.1 has no Get-Date -AsUTC; ToUniversalTime() works everywhere.
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z'
    return (Join-Path $logDir "$Prefix-$stamp.log")
}

function Start-AlfaWorkerTranscript {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    # Be defensive: if a prior transcript is still active in this session we
    # cannot start a new one. Stop it (ignore errors -- the "no active
    # transcript" case is a cmdlet-error, not a real problem).
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
    try {
        Start-Transcript -Path $Path -Force -ErrorAction Stop | Out-Null
        Write-AlfaLog -Level OK -Message ("Transcript ON -> $Path")
    } catch {
        Write-AlfaLog -Level WARN -Message ("Transcript could not start: $_")
    }
}

function Stop-AlfaWorkerTranscript {
    [CmdletBinding()]
    param()
    try { Stop-Transcript | Out-Null } catch { }
}
