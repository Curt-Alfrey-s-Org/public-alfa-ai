<#
.SYNOPSIS
    Validate .ps1 files for Windows PowerShell 5.1 (ASCII + parser).

.DESCRIPTION
    Run from repo root on apps (pwsh) or Windows before commit / after editing
    cluster deploy scripts. Catches Unicode-in-string parse failures on PS 5.1
    and unbalanced try/finally blocks.

.EXAMPLE
    pwsh -NoProfile -File deploy/cluster-members/_common/Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy/cluster-members
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Path = @(),

    [switch]$Recurse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AlfaPowerShellAscii {
    param([string]$FilePath)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $issues = @()
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) {
            $line = 1
            $col = 1
            for ($j = 0; $j -lt $i; $j++) {
                if ($bytes[$j] -eq 10) { $line++; $col = 1 } else { $col++ }
            }
            $issues += [pscustomobject]@{
                Line = $line
                Col  = $col
                Code = 'U+' + ('{0:X4}' -f $bytes[$i])
            }
            if ($issues.Count -ge 8) { break }
        }
    }
    return @($issues)
}

function Test-AlfaPowerShellParse {
    param([string]$FilePath)

    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)
    if ($null -eq $errors -or $errors.Count -eq 0) { return @() }
    return @($errors)
}

$files = @()
if ($Recurse) {
    foreach ($root in $Path) {
        if (-not (Test-Path -LiteralPath $root)) {
            Write-Error "Path not found: $root"
        }
        $files += Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse | ForEach-Object { $_.FullName }
    }
} else {
    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Error "Path not found: $p"
        }
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) {
            $files += Get-ChildItem -LiteralPath $p -Filter '*.ps1' -File | ForEach-Object { $_.FullName }
        } else {
            $files += $item.FullName
        }
    }
}

if ($files.Count -eq 0) {
    Write-Error 'No .ps1 files to check. Pass -Path or -Recurse deploy/cluster-members'
}

$failed = $false
foreach ($file in @($files | Sort-Object -Unique)) {
    $asciiIssues = @(Test-AlfaPowerShellAscii -FilePath $file)
    $parseIssues = @(Test-AlfaPowerShellParse -FilePath $file)

    if ($asciiIssues.Count -eq 0 -and $parseIssues.Count -eq 0) {
        Write-Host "OK  $file" -ForegroundColor Green
        continue
    }

    $failed = $true
    Write-Host "FAIL $file" -ForegroundColor Red
    foreach ($a in $asciiIssues) {
        Write-Host ("  non-ASCII {0} at line {1} col {2} (use ASCII - see windows-powershell-51-syntax.mdc)" -f $a.Code, $a.Line, $a.Col) -ForegroundColor Yellow
    }
    foreach ($e in $parseIssues) {
        Write-Host ("  parse: {0}" -f $e.ToString()) -ForegroundColor Yellow
    }
}

if ($failed) { exit 1 }
Write-Host ("`nAll {0} script(s) passed ASCII + parser checks." -f @($files | Sort-Object -Unique).Count) -ForegroundColor Green
exit 0
