# edid-override.ps1 - add 1080p25 (CTA VIC 33) to the display Windows sees, so Plex HTPC's resolution switching has a
# real 1920x1080@25 mode for PAL content. Without it, Plex can pick a driver-scaled 4:3 mode (e.g. 1600x1200@25).
# Run elevated on the HTPC. Same registry location CRU writes (EDID_OVERRIDE), so CRU can inspect or remove it too.
#   edid-override.ps1 -Instance 'DISPLAY\DON0079\5&23001d87&1&UID268' -Apply
#   edid-override.ps1 -Instance ... -Undo
# Find -Instance: Device Manager > Monitors > (the AVR / TV) > Details > Device instance path.
# How: copies the live EDID, swaps one unused interlaced entry (1080i60 / 1080i50 / 480i) in the CTA video data block
# for VIC 33 - same length, so nothing else moves - fixes the checksum, writes the override, restarts the GPU driver.
# The override is a frozen copy: if the TV / AVR later reports different capabilities, run -Undo and -Apply again.
param([string]$Instance = '', [switch]$Apply, [switch]$Undo)
$ErrorActionPreference = 'Stop'
if (-not $Instance) { throw 'pass -Instance DISPLAY\<model>\<instance> (Device Manager > Monitors > Details > Device instance path)' }
$k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$Instance\Device Parameters"
function Restart-Gpu {
  foreach ($g in (Get-PnpDevice -Class Display -PresentOnly).InstanceId) { pnputil /restart-device "$g" | Select-Object -Last 1 }
}
if ($Undo) { Remove-Item "$k\EDID_OVERRIDE" -Recurse -Force -ErrorAction SilentlyContinue; 'override removed'; Restart-Gpu; return }
if (-not $Apply) { 'use -Apply or -Undo'; return }

$e = [byte[]](Get-ItemProperty $k).EDID
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'edid-original.bin'), $e)
if ($e.Length -lt 256 -or $e[128] -ne 0x02) { throw 'no CTA-861 extension block - use CRU instead' }
$b = 128; $i = $b + 4; $vdb = -1; $len = 0
while ($i -lt $b + $e[$b + 2]) { $tag = $e[$i] -shr 5; $l = $e[$i] -band 0x1F; if ($tag -eq 2) { $vdb = $i; $len = $l; break }; $i += $l + 1 }
if ($vdb -lt 0) { throw 'no video data block - use CRU instead' }
$vics = for ($j = 1; $j -le $len; $j++) { $e[$vdb + $j] -band 0x7F }
if ($vics -contains 33) { 'the EDID already lists 1080p25 - nothing to do'; return }
$pos = -1; foreach ($spare in 5, 20, 6, 7, 21, 22) { for ($j = 1; $j -le $len; $j++) { if (($e[$vdb + $j] -band 0x7F) -eq $spare) { $pos = $vdb + $j; break } }; if ($pos -ge 0) { break } }
if ($pos -lt 0) { throw 'no unused interlaced mode to swap - add VIC 33 with CRU instead' }
"swapping VIC $($e[$pos] -band 0x7F) at byte $pos for VIC 33 (1080p25)"
$e[$pos] = 33
$sum = 0; for ($j = 128; $j -lt 255; $j++) { $sum += $e[$j] }; $e[255] = [byte]((256 - ($sum % 256)) % 256)
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'edid-override.bin'), $e)
New-Item -Path "$k\EDID_OVERRIDE" -Force | Out-Null
for ($blk = 0; $blk -lt $e.Length / 128; $blk++) {
  New-ItemProperty -Path "$k\EDID_OVERRIDE" -Name "$blk" -PropertyType Binary -Value ([byte[]]$e[($blk * 128)..($blk * 128 + 127)]) -Force | Out-Null
}
'override written'
Restart-Gpu
