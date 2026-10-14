<#
.SYNOPSIS
  Wake the HTPC from another PC through the AtomS3 wake dongle, optionally waiting for SSH.
.DESCRIPTION
  1. Sends a Wake-on-LAN magic packet to the DONGLE's MAC (broadcast UDP 9 and 7) - no ARP
     for the HTPC is needed, the dongle never sleeps.
  2. Also hits the dongle's HTTP trigger if it is reachable (belt and braces).
  3. With -BoxIp, polls TCP 22 on the HTPC until it answers (default 90 s).
  Idempotent: the dongle taps LEFT SHIFT, harmless if the HTPC is already awake.
.EXAMPLE
  .\wake-htpc.ps1 -DongleMac E8:F6:0A:00:00:00 -BoxIp 192.168.1.40
#>
param(
  [Parameter(Mandatory)] [string]$DongleMac,   # the DONGLE's MAC (shown at its GET /), not the PC's
  [string]$DongleIp  = '',                      # optional; mDNS name htpc-wake.local when empty
  [string]$BoxIp     = '',                      # optional: the HTPC's IP, to wait until SSH answers
  [int]$TimeoutSec   = 90
)
$ErrorActionPreference = 'Continue'
$mac = ($DongleMac -replace '[-:]', '')
$bytes = [byte[]](0..5 | % { 0xFF }) + [byte[]](1..16 | % { for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToByte($mac.Substring($i, 2), 16) } })
$udp = New-Object System.Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
foreach ($port in 9, 7) { [void]$udp.Send($bytes, $bytes.Length, '255.255.255.255', $port) }
$udp.Close()
Write-Host "magic packet sent to dongle $DongleMac"
$target = if ($DongleIp) { $DongleIp } else { 'htpc-wake.local' }
try { $r = Invoke-RestMethod -Uri "http://$target/wake" -TimeoutSec 5; Write-Host "dongle http: $($r.did)" } catch { Write-Host "dongle http not reachable ($target) - relying on the magic packet" }
if (-not $BoxIp) { return }
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
  if (Test-NetConnection $BoxIp -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue) { Write-Host ("HTPC SSH up after {0:n0} s" -f $sw.Elapsed.TotalSeconds); exit 0 }
  Start-Sleep 3
}
Write-Warning "HTPC port 22 not answering after $TimeoutSec s"
exit 1
