<#
.SYNOPSIS
    Copy build-start transcript + docker container logs to inference hub for remote analysis.
#>

function Resolve-AlfaCollectScript {
    [CmdletBinding()]
    param([string[]]$RepoRootCandidates)

    foreach ($root in $RepoRootCandidates) {
        if (-not $root) { continue }
        foreach ($name in @('collect-alfa-docker-logs-to-148.ps1', 'collect-alfa-docker-logs-to-148.ps1')) {
            $ps1 = Join-Path $root "scripts\$name"
            if (Test-Path -LiteralPath $ps1) { return $ps1 }
        }
    }
    return $null
}

function Send-AlfaBuildLogsTo148 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$MemberFolder,
        [string]$RepoRoot,
        [string]$BuildTranscriptPath,
        [switch]$NoScp
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $sshHost = if ($env:SSH_HOST) { $env:SSH_HOST } else { 'operator@orchestrator' }
    $remoteDir = if ($env:REMOTE_DIR) { $env:REMOTE_DIR } else { '/home/operator/alfa-ai/logs/cluster-docker' }
    $doScp = (-not $NoScp) -and ($env:SCP_TO_BUILD_HOST -ne '0')

    Write-Host ''
    Write-Host '== Upload logs to inference hub for analysis ==' -ForegroundColor Cyan
    Write-Host "  Remote: ${sshHost}:${remoteDir}/" -ForegroundColor DarkGray

    if ($doScp -and $BuildTranscriptPath -and (Test-Path -LiteralPath $BuildTranscriptPath)) {
        & ssh -o BatchMode=yes -o ConnectTimeout=10 $sshHost "mkdir -p '$remoteDir'" 2>&1 | Out-Null
        & scp -o BatchMode=yes -o ConnectTimeout=10 $BuildTranscriptPath "${sshHost}:${remoteDir}/"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Copied transcript -> ${remoteDir}/$(Split-Path -Leaf $BuildTranscriptPath)" -ForegroundColor Green
        } else {
            Write-Host '  WARN: transcript scp failed' -ForegroundColor Yellow
        }
    }

    $collectPs1 = Resolve-AlfaCollectScript @($RepoRoot, 'C:\alfa-ai-worker', (Join-Path $env:USERPROFILE 'alfa-ai'))
    if (-not $collectPs1) {
        Write-Host '  WARN: collect-alfa-docker-logs-to-148.ps1 not found' -ForegroundColor Yellow
        $ErrorActionPreference = $prev
        return
    }

    if ($NoScp -or ($env:SCP_TO_BUILD_HOST -eq '0')) {
        & $collectPs1 -NoScp
    } else {
        & $collectPs1
    }

    Write-Host "  Analysis dir on inference: $remoteDir" -ForegroundColor Green
    Write-Host ''
    $ErrorActionPreference = $prev
}

function Send-AlfaBuildLogsTo148 { Send-AlfaBuildLogsTo148 @args }