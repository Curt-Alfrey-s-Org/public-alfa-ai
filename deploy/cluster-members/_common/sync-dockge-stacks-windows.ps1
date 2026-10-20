<#
.SYNOPSIS
    Stage Docker Compose files into a Dockge-visible stacks/ tree on Windows hosts.
#>

function Sync-AlfaDockgeStackFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StacksDir,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string[]]$SourceFiles,
        [string]$EnvSource,
        [string]$EnvDestName = '.env'
    )

    $dest = Join-Path $StacksDir $Name
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    foreach ($src in $SourceFiles) {
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Dockge stack source missing: $src"
        }
        $leaf = Split-Path -Leaf $src
        Copy-Item -LiteralPath $src -Destination (Join-Path $dest $leaf) -Force
    }
    if ($EnvSource -and (Test-Path -LiteralPath $EnvSource)) {
        Copy-Item -LiteralPath $EnvSource -Destination (Join-Path $dest $EnvDestName) -Force
    }
    return $dest
}

function Sync-Alfaoperator93DockgeStacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    $stacksDir = Join-Path $RepoDir 'stacks'
    $llcDir = Join-Path $RepoDir 'deploy\llamacpp-rpc'

    if (-not (Test-Path $stacksDir)) {
        New-Item -ItemType Directory -Path $stacksDir -Force | Out-Null
    }

    $llcCompose = Join-Path $llcDir 'docker-compose.rpc-server.wsl-93.yml'
    if (-not (Test-Path $llcCompose)) {
        $llcCompose = Join-Path $llcDir 'docker-compose.rpc-server.yml'
    }
    $llcEnv = Join-Path $llcDir '.env.rpc'
    if ((Test-Path $llcCompose) -and (Test-Path $llcEnv)) {
        Sync-AlfaDockgeStackFolder -StacksDir $stacksDir -Name 'llamacpp-rpc' `
            -SourceFiles @($llcCompose) `
            -EnvSource $llcEnv `
            -EnvDestName '.env.rpc' | Out-Null
    }

    Write-Host "  Dockge stacks staged under: $stacksDir" -ForegroundColor Green
    return $stacksDir
}

function Sync-AlfaWorkerDockgeStacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkerDir,
        [switch]$IncludeLlamacppRpc
    )

    $stacksDir = Join-Path $WorkerDir 'stacks'
    if (-not (Test-Path $stacksDir)) {
        New-Item -ItemType Directory -Path $stacksDir -Force | Out-Null
    }

    if ($IncludeLlamacppRpc) {
        $llcDir = Join-Path $WorkerDir 'deploy\llamacpp-rpc'
        $llcCompose = Join-Path $llcDir 'docker-compose.rpc-server.yml'
        $llcEnv = Join-Path $llcDir '.env.rpc'
        if ((Test-Path $llcCompose) -and (Test-Path $llcEnv)) {
            Sync-AlfaDockgeStackFolder -StacksDir $stacksDir -Name 'llamacpp-rpc' `
                -SourceFiles @($llcCompose) `
                -EnvSource $llcEnv `
                -EnvDestName '.env.rpc' | Out-Null
        }
    }

    Write-Host "  Dockge worker stacks staged under: $stacksDir" -ForegroundColor Green
    return $stacksDir
}
