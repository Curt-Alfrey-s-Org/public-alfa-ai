#Requires -Version 5.1
<#
.SYNOPSIS
  Install orchestrator GitHub SSH identity onto a Windows worker (org-wide git pull).

.DESCRIPTION
  Copies the operator GitHub SSH key from this PC (%USERPROFILE%\.ssh\id_ed25519)
  to the remote Windows user as id_ed25519_github, writes Host github.com in
  their ~/.ssh/config, converts the alfa-ai origin to SSH, and resets to
  origin/main. Use -RepoRoot when the clone is C:\alfa-ai-worker (not
  %USERPROFILE%\alfa-ai). Use -ExtraRepoRoots for other HTTPS clones
  (C:\alfa-ai-train) so Git Credential Manager wincredman is not used.

  Use when OpenSSH sessions cannot use HTTPS + wincredman (gaming hosts).
  Prefer this over per-repo deploy keys when the host must pull multiple org repos.

  Official: https://docs.github.com/en/authentication/connecting-to-github-with-ssh

  Does NOT commit private keys. Run only from orchestrator (operator) with agent SSH keys.

.PARAMETER SshTarget
  e.g. Colin@orchestrator

.PARAMETER AgentKey
  Path to id_ed25519_93_<host> on orchestrator

.PARAMETER RemoteUserProfile
  Remote Windows profile root, e.g. C:\Users\Colin

.PARAMETER RemoteUser
  Windows account name for icacls grant (e.g. Colin)

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\_common\Install-GitHubSshIdentity-From93.ps1 `
    -SshTarget 'Colin@orchestrator' `
    -AgentKey "$env:USERPROFILE\.ssh\id_ed25519_93_59" `
    -RemoteUserProfile 'C:\Users\Colin' `
    -RemoteUser 'Colin'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SshTarget,
    [Parameter(Mandatory)][string]$AgentKey,
    [Parameter(Mandatory)][string]$RemoteUserProfile,
    [Parameter(Mandatory)][string]$RemoteUser,
    [string]$LocalGitHubKey = (Join-Path $env:USERPROFILE '.ssh\id_ed25519'),
    [string]$RemoteKeyName = 'id_ed25519_github',
    [string]$RepoRelative = 'alfa-ai',
    [string]$RepoRoot = '',
    [string[]]$ExtraRepoRoots = @()
)

function ConvertTo-AlfaGitHubSshUrl {
    param([Parameter(Mandatory)][string]$Url)
    $t = $Url.Trim()
    if ($t -match '^git@github\.com:') {
        return $t
    }
    # Official HTTPS and SSH remote forms:
    # https://docs.github.com/en/get-started/git-basics/about-remote-repositories
    if ($t -match '^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$') {
        return ('operator@example.com:{0}/{1}.git' -f $Matches[1], $Matches[2])
    }
    if ($t -match '^ssh://git@github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$') {
        return ('operator@example.com:{0}/{1}.git' -f $Matches[1], $Matches[2])
    }
    throw "ConvertTo-AlfaGitHubSshUrl: not a GitHub remote: $t"
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localPub = $LocalGitHubKey + '.pub'
if (-not (Test-Path -LiteralPath $LocalGitHubKey)) {
    throw "Missing local GitHub key: $LocalGitHubKey"
}
if (-not (Test-Path -LiteralPath $localPub)) {
    throw "Missing local GitHub pubkey: $localPub"
}
if (-not (Test-Path -LiteralPath $AgentKey)) {
    throw "Missing agent SSH key: $AgentKey"
}

$profileTrim = $RemoteUserProfile.TrimEnd('\')
$remoteKeyWin = Join-Path $profileTrim ".ssh\$RemoteKeyName"
$remoteKeyUnix = ($profileTrim + '/.ssh/' + $RemoteKeyName).Replace('\', '/')
$remotePubUnix = $remoteKeyUnix + '.pub'
if ($RepoRoot -ne '') {
    $repoWin = $RepoRoot.TrimEnd('\')
} else {
    $repoWin = Join-Path $profileTrim $RepoRelative
}

Write-Host ("== Install GitHub SSH identity -> {0} ==" -f $SshTarget) -ForegroundColor Cyan

& scp.exe -o BatchMode=yes -o ConnectTimeout=20 -i $AgentKey $LocalGitHubKey "${SshTarget}:${remoteKeyUnix}"
if ($LASTEXITCODE -ne 0) { throw "scp private key failed (exit $LASTEXITCODE)" }
& scp.exe -o BatchMode=yes -o ConnectTimeout=20 -i $AgentKey $localPub "${SshTarget}:${remotePubUnix}"
if ($LASTEXITCODE -ne 0) { throw "scp public key failed (exit $LASTEXITCODE)" }

$cfgCmd = "icacls `"$remoteKeyWin`" /inheritance:r; icacls `"$remoteKeyWin`" /grant:r ${RemoteUser}:R; @('Host github.com','    HostName github.com','    User git','    IdentityFile $remoteKeyWin','    IdentitiesOnly yes') | Set-Content `"$profileTrim\.ssh\config`" -Encoding ASCII"
& ssh.exe -o BatchMode=yes -o ConnectTimeout=20 -i $AgentKey $SshTarget $cfgCmd
if ($LASTEXITCODE -ne 0) { throw "remote ssh config failed (exit $LASTEXITCODE)" }

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$probeOut = & ssh.exe -o BatchMode=yes -o ConnectTimeout=20 -i $AgentKey $SshTarget "ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i `"$remoteKeyWin`" -T operator@example.com" 2>&1 | Out-String
$ErrorActionPreference = $prevEap
Write-Host $probeOut.Trim()
if ($probeOut -notmatch 'successfully authenticated') {
    throw "GitHub SSH auth failed on $SshTarget"
}

$syncCmd = "cd `"$repoWin`"; git remote set-url origin operator@example.com:example/alfa-ai.git; git fetch origin main; git reset --hard origin/main; git log -1 --oneline; git remote -v"
& ssh.exe -o BatchMode=yes -o ConnectTimeout=60 -i $AgentKey $SshTarget $syncCmd
if ($LASTEXITCODE -ne 0) { throw "git sync failed on $SshTarget (exit $LASTEXITCODE)" }

foreach ($extraRoot in @($ExtraRepoRoots)) {
    if ([string]::IsNullOrWhiteSpace($extraRoot)) { continue }
    $extraWin = $extraRoot.TrimEnd('\')
    $prevEap2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $extraUrlRaw = & ssh.exe -o BatchMode=yes -o ConnectTimeout=20 -i $AgentKey $SshTarget "git -C `"$extraWin`" remote get-url origin" 2>&1 | Out-String
    $ErrorActionPreference = $prevEap2
    $extraUrl = ($extraUrlRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($extraUrl)) {
        throw "git remote get-url failed for $extraWin on $SshTarget"
    }
    $extraSsh = ConvertTo-AlfaGitHubSshUrl -Url $extraUrl
    Write-Host ("== Extra clone {0} -> {1} ==" -f $extraWin, $extraSsh) -ForegroundColor Cyan
    $extraCmd = "cd `"$extraWin`"; git remote set-url origin $extraSsh; git pull --ff-only origin main; git remote -v"
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=60 -i $AgentKey $SshTarget $extraCmd
    if ($LASTEXITCODE -ne 0) { throw "git extra sync failed on $extraWin (exit $LASTEXITCODE)" }
}

Write-Host ("OK {0}" -f $SshTarget) -ForegroundColor Green
