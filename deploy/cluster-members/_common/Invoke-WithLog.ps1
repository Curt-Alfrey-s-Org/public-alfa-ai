<#
.SYNOPSIS
  Run a PowerShell script with live console + UTF-8 log capture.

.DESCRIPTION
  Invokes the target script in a child `powershell.exe` process via
  System.Diagnostics.Process so that:

  - stderr from native tools (git, docker, etc.) is captured as plain text
    rather than being wrapped into PowerShell NativeCommandError records.
    This is what killed the previous `Tee-Object` / `*>&1` pipeline wrapper
    on worker hosts as soon as `git fetch` printed `From https://github.com/...`
    on stderr.
  - The log file is written as UTF-8 (no BOM) so it is readable on Linux
    for central analysis.  The old `Tee-Object -FilePath` default was
    UTF-16 LE + BOM, which is why past logs rendered as spaced-out
    characters when cat'd on the hub.
  - A single writer owns the log file (no Start-Transcript vs Tee-Object
    collision that produced "The process cannot access the file..." errors).
  - stdout and stderr are both streamed line-by-line to the console while
    being appended to the log, with `[stderr]` prefixes on stderr lines so
    they are easy to spot but do not terminate the pipeline.
  - The child's real exit code is forwarded via `exit`.

.PARAMETER ScriptPath
  Absolute path to the .ps1 script to run.

.PARAMETER LogPath
  Absolute path to the log file to create/append to.  Parent directory is
  created if missing.

.PARAMETER ExtraArgs
  Optional extra string arguments passed to the child script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ScriptPath,
    [Parameter(Mandatory = $true)] [string] $LogPath,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $ExtraArgs
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "Target script missing: $ScriptPath" -ForegroundColor Red
    exit 2
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    $null = New-Item -ItemType Directory -Force -Path $logDir
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$header = @(
    "== $(Get-Date -Format o) ==",
    "host=$env:COMPUTERNAME user=$env:USERNAME",
    "script=$ScriptPath",
    "args=$($ExtraArgs -join ' ')",
    ('-' * 72)
) -join "`r`n"
[System.IO.File]::WriteAllText($LogPath, $header + "`r`n", $utf8NoBom)

function Append-Log {
    param([string] $Line, [switch] $IsErr)
    $text = if ($IsErr) { "[stderr] $Line" } else { $Line }
    if ($IsErr) {
        Write-Host $text -ForegroundColor Yellow
    } else {
        Write-Host $text
    }
    [System.IO.File]::AppendAllText($LogPath, $text + "`r`n", $utf8NoBom)
}

$pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = 'powershell.exe' }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $pwshExe
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

$argList = New-Object 'System.Collections.Generic.List[string]'
$argList.Add('-NoProfile')
$argList.Add('-ExecutionPolicy'); $argList.Add('Bypass')
$argList.Add('-File'); $argList.Add($ScriptPath)
if ($ExtraArgs) { foreach ($a in $ExtraArgs) { $argList.Add($a) } }

$sb = New-Object System.Text.StringBuilder
foreach ($a in $argList) {
    if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
    if ($a -match '\s|"') {
        [void]$sb.Append('"' + ($a -replace '"','\"') + '"')
    } else {
        [void]$sb.Append($a)
    }
}
$psi.Arguments = $sb.ToString()

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$null = $proc.Start()

# Concurrent async reads from both streams, processed in the main runspace so
# $LogPath / $utf8NoBom / Append-Log are all in scope.
$outReader = $proc.StandardOutput
$errReader = $proc.StandardError
$outTask = $outReader.ReadLineAsync()
$errTask = $errReader.ReadLineAsync()

while ($outTask -or $errTask) {
    $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
    if ($outTask) { $tasks.Add($outTask) }
    if ($errTask) { $tasks.Add($errTask) }

    $arr = $tasks.ToArray()
    $idx = [System.Threading.Tasks.Task]::WaitAny($arr)
    $done = $arr[$idx]
    $line = $done.Result

    if ($done -eq $outTask) {
        if ($null -eq $line) {
            $outTask = $null
        } else {
            Append-Log -Line $line
            $outTask = $outReader.ReadLineAsync()
        }
    } else {
        if ($null -eq $line) {
            $errTask = $null
        } else {
            Append-Log -Line $line -IsErr
            $errTask = $errReader.ReadLineAsync()
        }
    }
}

$proc.WaitForExit()
$exit = $proc.ExitCode

$footer = "`r`n---`r`nexit_code=$exit`r`nfinished=$(Get-Date -Format o)`r`n"
[System.IO.File]::AppendAllText($LogPath, $footer, $utf8NoBom)

if ($exit -ne 0) {
    Write-Host "Script exited with code $exit" -ForegroundColor Red
} else {
    Write-Host "Script exited cleanly (0)" -ForegroundColor Green
}
exit $exit
