<#
.SYNOPSIS
    Ensure the hub SMB drive letters are mapped on this Windows worker.
    Idempotent -- safe to call every deploy. Maps:

        Y: -> \\hub\petals-wheels   (PyPI wheel hub)
        Z: -> \\hub\huggingface     (HF model cache)

    Optional:
        I: -> \\hub\docker-images   (prebuilt worker tarballs -- used by
             deploy-worker-lan.ps1 via UNC; the drive letter is convenience only
             and not required for docker load.)

    Policy ref: docs/HUB_ARTIFACTS.md, .cursor/rules/hub-hub-first.mdc
.EXAMPLE
    . "$PSScriptRoot\ensure-smb-drives.ps1"
    Ensure-AlfaSmbDrives
#>

function Ensure-AlfaSmbDrives {
    [CmdletBinding()]
    param(
        [string]$HubHost = 'hub',
        [hashtable]$Mapping = @{
            'Y' = 'petals-wheels'
            'Z' = 'huggingface'
            'I' = 'docker-images'
        }
    )

    Write-Host '== Ensuring SMB drive mappings ==' -ForegroundColor Cyan
    foreach ($letter in $Mapping.Keys) {
        $share   = $Mapping[$letter]
        $drive   = "${letter}:"
        $uncPath = "\\$HubHost\$share"

        $existing = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
        if ($existing -and $existing.DisplayRoot -eq $uncPath) {
            Write-Host "  $drive  -> $uncPath  (already mapped)" -ForegroundColor Green
            continue
        }
        if ($existing) {
            Write-Host "  $drive  -> $($existing.DisplayRoot)  (remapping to $uncPath)" -ForegroundColor Yellow
            & net use $drive /delete /yes 2>&1 | Out-Null
        }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & net use $drive $uncPath /PERSISTENT:YES 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  $drive  -> $uncPath  (mapped)" -ForegroundColor Green
            } else {
                # Read-only shares on hub sometimes return an error even
                # when the mapping succeeds. Verify by Test-Path.
                if (Test-Path $drive) {
                    Write-Host "  $drive  -> $uncPath  (mapped, net use returned $LASTEXITCODE)" -ForegroundColor Green
                } else {
                    Write-Host "  $drive  -> $uncPath  FAILED (net use exit $LASTEXITCODE)" -ForegroundColor Red
                    Write-Host "    Check that the share exists on hub and this host is authenticated." -ForegroundColor Yellow
                }
            }
        } finally {
            $ErrorActionPreference = $prevEAP
        }
    }
    Write-Host ''
}
