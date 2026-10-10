#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
& (Join-Path $PSScriptRoot '..\_common\sync-llamacpp-vendor-from-hub.ps1') -RepoDir $RepoDir
