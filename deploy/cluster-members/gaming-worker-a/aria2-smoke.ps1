#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$u = 'http://hub/jsonrpc'
$secret = $env:ARIA2_RPC_KEY
if ([string]::IsNullOrWhiteSpace($secret)) {
    throw 'ARIA2_RPC_KEY is not set. Set it to the hub aria2 RPC secret first (see deploy/aria2/README.md).'
}
$body = @{ jsonrpc = '2.0'; id = 1; method = 'aria2.getVersion'; params = @("token:$secret") } | ConvertTo-Json -Compress
Write-Host "POST $u (aria2.getVersion via hub)"

for ($i = 0; $i -lt 20; $i++) {
    try {
        Invoke-RestMethod -Uri $u -Method Post -ContentType 'application/json' -Body $body | ConvertTo-Json -Depth 5
        exit 0
    } catch {
        Start-Sleep -Seconds 1
    }
}

throw "hub aria2 RPC unreachable after 20s: $u"
