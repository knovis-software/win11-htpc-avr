<#
.SYNOPSIS
  Wake the HTPC from another PC through the AtomS3 wake dongle.
.DESCRIPTION
  1. Sends a Wake-on-LAN magic packet to the DONGLE's MAC (broadcast UDP 9 and 7) - the dongle never sleeps.
  2. Also hits the dongle's HTTP trigger if it is reachable (belt and braces).
  Idempotent: the dongle taps LEFT SHIFT, harmless if the HTPC is already awake.
.EXAMPLE
  .\wake-htpc.ps1 -DongleMac E8:F6:0A:00:00:00
#>
param(
  [Parameter(Mandatory)] [string]$DongleMac,   # the DONGLE's MAC (shown at its GET /), not the PC's
  [string]$DongleIp = ''                        # optional; mDNS name htpc-wake.local when empty
)
$mac = ($DongleMac -replace '[-:]', '')
$bytes = [byte[]](0..5 | % { 0xFF }) + [byte[]](1..16 | % { for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToByte($mac.Substring($i, 2), 16) } })
$udp = New-Object System.Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
foreach ($port in 9, 7) { [void]$udp.Send($bytes, $bytes.Length, '255.255.255.255', $port) }
$udp.Close()
Write-Host "magic packet sent to dongle $DongleMac"
$target = if ($DongleIp) { $DongleIp } else { 'htpc-wake.local' }
try { $r = Invoke-RestMethod -Uri "http://$target/wake" -TimeoutSec 5; Write-Host "dongle http: $($r.did)" } catch { Write-Host "dongle http not reachable ($target) - relying on the magic packet" }
