#Requires -Version 5.1
# Quick LAN ping matrix from WOLF1 (orchestrator). Read-only.
$hosts = @(1, 59, 93, 100, 102, 103, 105, 106, 107, 110, 111, 126, 148, 219, 229, 240, 248, 249)
Write-Host "== From $env:COMPUTERNAME (ping 1 packet each) =="
foreach ($last in $hosts) {
    $ip = "orchestrator0.$last"
    $ok = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ok) {
        Write-Host "$ip OK"
    } else {
        Write-Host "$ip FAIL"
    }
}
