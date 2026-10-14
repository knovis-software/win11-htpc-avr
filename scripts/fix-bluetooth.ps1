# fix-bluetooth.ps1 - the HTPC: bring the Intel AX200 Bluetooth radio back when it boots into Code 10.
#
# Started by the "Fix Bluetooth" Start-menu tile, which runs the FixBluetooth scheduled task
# (elevated, no UAC prompt), or directly from an admin PowerShell. Log: <install folder>\fix-bluetooth.log.
#
# What it does, in order, stopping at the first that works:
#   0. read the radio's PnP problem code; 0 = healthy, report and exit
#   1. disable + enable the radio (reloads the Intel firmware; fixed the 2026-09-16 case)
#   2. remove the device + rescan (the old manual route)
# Pairings live in the registry under the radio's own address and survive all of this.
# Never remove the paired devices themselves: that deletes the link keys on the PC side and the
# Xbox pads then have to be re-paired from the pad.

param([switch]$Quiet)   # skip the closing countdown (for unattended runs)

$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'fix-bluetooth.log'
function Log($msg, $color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
    try { Add-Content -Path $log -Value $line } catch {}
    Write-Host $line -ForegroundColor $color
}
function Finish($code) {
    if (-not $Quiet) {
        try {
            for ($i = 20; $i -gt 0; $i--) {
                if ([Console]::KeyAvailable) { break }
                Write-Host -NoNewline ("`rclosing in {0,2} s (any key to close) " -f $i)
                Start-Sleep 1
            }
        } catch {}
    }
    exit $code
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin) {
    Log 'not elevated; relaunching as administrator' Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Log '--- fix-bluetooth start ---' Cyan

function Get-Radio {
    Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_8087*' -and $_.FriendlyName -match 'Intel' } |
        Select-Object -First 1
}
function Get-Code($r) {
    if (-not $r) { return -1 }
    $p = Get-PnpDeviceProperty -InstanceId $r.InstanceId -KeyName DEVPKEY_Device_ProblemCode -ErrorAction SilentlyContinue
    if ($null -eq $p.Data) { -1 } else { [int]$p.Data }
}
function Wait-Healthy($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        Start-Sleep 2
        $r = Get-Radio
        if ($r -and $r.Present -and (Get-Code $r) -eq 0) { return $true }
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Show-Devices {
    $devs = Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'Xbox|Keyboard|Controller|Mouse|Remote|AirPods' } |
        Select-Object -ExpandProperty FriendlyName | Sort-Object
    if ($devs) { Log ('paired devices present: ' + ($devs -join ', ')) Green }
    else { Log 'no paired input devices present yet (pads reconnect when a button is pressed)' Yellow }
}

$radio = Get-Radio
if (-not $radio) {
    Log 'Intel Bluetooth radio not enumerated at all; rescanning' Yellow
    pnputil /scan-devices | Out-Null
    Start-Sleep 10
    $radio = Get-Radio
    if (-not $radio) {
        Log 'still no Intel Bluetooth radio after rescan. Restart Windows; if it is still missing, shut down and pull the plug for 30 s' Red
        Finish 2
    }
}
$code = Get-Code $radio
Log ('radio: {0} [{1}] present={2} problem code={3}' -f $radio.FriendlyName, $radio.InstanceId, $radio.Present, $code)

if ($radio.Present -and $code -eq 0) {
    Log 'radio is healthy; nothing to do' Green
    Show-Devices
    Finish 0
}

Log 'step 1: disable + enable the radio' Cyan
pnputil /disable-device $radio.InstanceId | Out-Null
Start-Sleep 4
pnputil /enable-device $radio.InstanceId | Out-Null
if (Wait-Healthy 25) {
    Log 'fixed by disable/enable' Green
    Start-Sleep 5
    Show-Devices
    Finish 0
}
Log ('still problem code {0} after disable/enable' -f (Get-Code (Get-Radio))) Yellow

Log 'step 2: remove the device and rescan' Cyan
pnputil /remove-device $radio.InstanceId | Out-Null
Start-Sleep 4
pnputil /scan-devices | Out-Null
if (Wait-Healthy 40) {
    Log 'fixed by remove/rescan' Green
    Start-Sleep 5
    Show-Devices
    Finish 0
}

$radio = Get-Radio
Log ('FAILED: radio problem code {0}. Restart Windows; if it comes back in this state, shut down fully and pull the plug for 30 s (the AX200 only resets on a cold start)' -f (Get-Code $radio)) Red
Finish 1
