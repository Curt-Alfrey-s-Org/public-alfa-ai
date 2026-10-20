#Requires -Version 5.1
<#
.SYNOPSIS
  Create a read-only GitHub deploy key for alfa-ai on a Windows gaming worker.

.DESCRIPTION
  Generates an unencrypted Ed25519 key pair for git pull over SSH:
    %USERPROFILE%\.ssh\id_ed25519_github_alfa-ai
    %USERPROFILE%\.ssh\id_ed25519_github_alfa-ai.pub

  Add the .pub line to GitHub: example/alfa-ai -> Settings -> Deploy keys
  (read-only). Then set origin to operator@example.com:example/alfa-ai.git.

  Official: https://docs.github.com/en/authentication/connecting-to-github-with-ssh
  https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys

.PARAMETER Comment
  Key comment (shown in GitHub). Default: hostname + Windows user.

.PARAMETER RepoRoot
  If set, run git remote set-url origin to SSH after key exists.

.PARAMETER KeyPath
  Override private key path (default id_ed25519_github_alfa-ai under .ssh).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\_common\Ensure-GitHubDeployKey.ps1 -Comment gaming-worker-b-249-Cody
#>
[CmdletBinding()]
param(
    [string]$Comment = '',
    [string]$RepoRoot = '',
    [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\id_ed25519_github_alfa-ai')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoSshUrl = 'operator@example.com:example/alfa-ai.git'
$SshDir = Split-Path -Parent $KeyPath
$pubPath = $KeyPath + '.pub'

if (-not $Comment) {
    $Comment = (hostname) + '-' + $env:USERNAME + '-alfa-ai-github'
}

function Test-UnencryptedOpenSshPrivateKey([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($text -match 'BEGIN OPENSSH PRIVATE KEY') {
        if ($text -match 'ENCRYPTED') { return $false }
        return $true
    }
    return $false
}

function New-AlfaEd25519KeyPair([string]$PrivatePath, [string]$KeyComment) {
    $py = @'
from pathlib import Path
import sys
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
except ImportError:
    sys.exit(2)
priv_path = Path(sys.argv[1])
comment = sys.argv[2].encode("utf-8")
key = Ed25519PrivateKey.generate()
priv = key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.OpenSSH,
    encryption_algorithm=serialization.NoEncryption(),
)
pub = key.public_key().public_bytes(
    encoding=serialization.Encoding.OpenSSH,
    format=serialization.PublicFormat.OpenSSH,
)
if comment:
    pub = pub + b" " + comment
priv_path.write_bytes(priv)
priv_path.with_suffix(priv_path.suffix + ".pub").write_bytes(pub + b"\n")
print("ok-python")
'@
    $tmpPy = Join-Path $env:TEMP ('alfa-github-ed25519-' + [guid]::NewGuid().ToString('n') + '.py')
    Set-Content -LiteralPath $tmpPy -Value $py -Encoding ASCII
    try {
        $out = & python $tmpPy $PrivatePath $KeyComment 2>&1
        if ($LASTEXITCODE -eq 0 -and ("$out" -match 'ok-python')) {
            return 'python'
        }
    } finally {
        Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $PrivatePath) {
        Remove-Item -LiteralPath $PrivatePath -Force
    }
    if (Test-Path -LiteralPath ($PrivatePath + '.pub')) {
        Remove-Item -LiteralPath ($PrivatePath + '.pub') -Force
    }
    & ssh-keygen.exe -t ed25519 -f $PrivatePath -N '""' -C $KeyComment
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-keygen failed exit=$LASTEXITCODE"
    }
    return 'ssh-keygen'
}

function Set-GitHubSshConfig([string]$IdentityFile) {
    if (-not (Test-Path -LiteralPath $SshDir)) {
        New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
    }
    $cfg = Join-Path $SshDir 'config'
    $block = @"
Host github.com
    HostName github.com
    User git
    IdentityFile $IdentityFile
    IdentitiesOnly yes

"@
    if (Test-Path -LiteralPath $cfg) {
        $existing = Get-Content -LiteralPath $cfg -Raw
        if ($existing -match '(?m)^Host\s+github\.com\s*$') {
            Write-Host "SSH config already has Host github.com ($cfg)" -ForegroundColor Yellow
            return
        }
        Add-Content -LiteralPath $cfg -Value "`n$block" -Encoding ASCII
    } else {
        Set-Content -LiteralPath $cfg -Value $block.TrimEnd() -Encoding ASCII
    }
    Write-Host "Wrote github.com entry in $cfg" -ForegroundColor Green
}

Write-Host '== Ensure GitHub deploy key (alfa-ai) ==' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $SshDir)) {
    New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
}

$needNew = $true
if ((Test-Path -LiteralPath $KeyPath) -and (Test-Path -LiteralPath $pubPath)) {
    if (Test-UnencryptedOpenSshPrivateKey $KeyPath) {
        Write-Host "Key exists: $KeyPath" -ForegroundColor Green
        $needNew = $false
    } else {
        Write-Host "Regenerating invalid/encrypted key: $KeyPath" -ForegroundColor Yellow
        Remove-Item -LiteralPath $KeyPath -Force
        Remove-Item -LiteralPath $pubPath -Force -ErrorAction SilentlyContinue
    }
}

if ($needNew) {
    $how = New-AlfaEd25519KeyPair -PrivatePath $KeyPath -KeyComment $Comment
    if (-not (Test-UnencryptedOpenSshPrivateKey $KeyPath)) {
        throw "Generated key is encrypted or invalid ($how)"
    }
    Write-Host "Created key via $how" -ForegroundColor Green
}

Set-GitHubSshConfig -IdentityFile $KeyPath

$pubLine = (Get-Content -LiteralPath $pubPath -Raw).Trim()
Write-Host ''
Write-Host '=== ADD THIS LINE TO GITHUB (Deploy key, read-only) ===' -ForegroundColor Cyan
Write-Host 'Repo: https://github.com/example/alfa-ai/settings/keys'
Write-Host ''
Write-Host $pubLine
Write-Host ''
Write-Host 'Title suggestion: gaming-worker-b-249-Cody (or gaming-worker-a-219-Corey, etc.)' -ForegroundColor DarkGray
Write-Host 'Check: Allow write access = OFF' -ForegroundColor DarkGray

if ($RepoRoot) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        throw "Not a git repo: $RepoRoot"
    }
    & git -C $RepoRoot remote set-url origin $RepoSshUrl
    if ($LASTEXITCODE -ne 0) { throw 'git remote set-url failed' }
    Write-Host "Set origin to $RepoSshUrl in $RepoRoot" -ForegroundColor Green
    Write-Host "Test: ssh -T operator@example.com"
    Write-Host "Pull: git -C `"$RepoRoot`" pull --ff-only origin main"
}
