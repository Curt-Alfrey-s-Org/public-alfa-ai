#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$SessionId,
    [string]$RepoRoot = 'C:/Users/operator\alfa-ai'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'inference-LogSession.ps1')
$log = Join-Path $PSScriptRoot "logs\cluster-start-${SessionId}.log"
if (-not (Test-Path -LiteralPath $log)) {
    $log = Join-Path $PSScriptRoot "logs\cluster-stop-${SessionId}.log"
}
Stop-inferenceLogSession -RepoRoot $RepoRoot -SessionId $SessionId -OrchestratorLogPath $log
