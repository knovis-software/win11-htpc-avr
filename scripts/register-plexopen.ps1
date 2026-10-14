# register-plexopen.ps1 - register (or remove) the plexopen:// URL scheme for the current user,
# pointing it at plexopen.ps1 in this folder. No admin rights needed (HKCU only).
#
#   .\register-plexopen.ps1            # register
#   .\register-plexopen.ps1 -Remove    # unregister
#
# After registering, a launcher item whose target is
#   ${PLEXURL}app.plex.tv/desktop/#!/server/<id>/details?key=...
# with the per-device path variable PLEXURL = "plexopen://" opens through plexopen.ps1
# (Plex HTPC via Companion, browser fallback). On a device without Plex HTPC set
# PLEXURL = "https://" and the same item opens in the browser as before.

param([switch] $Remove)

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Classes\plexopen'

if ($Remove) {
    if (Test-Path $key) { Remove-Item $key -Recurse -Force; Write-Host "removed $key" }
    else { Write-Host "nothing to remove" }
    exit 0
}

$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'plexopen.ps1'
if (-not (Test-Path $script)) { throw "plexopen.ps1 not found next to this script" }

# Pick a PowerShell host whose path SURVIVES UPGRADES, then prove it actually runs.
#
# Two traps, one on each kind of install:
#
#  1. (Get-Command pwsh.exe).Source on a Store/winget PowerShell resolves to a
#     VERSION-STAMPED path, e.g.
#       C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__.../pwsh.exe
#     which ceases to exist the moment PowerShell updates. Nothing re-runs this
#     script on upgrade, so the handler dies silently. (Seen for real: a key still
#     naming 7.6.5.0 after pwsh had moved to 7.6.6.0.)
#
#  2. The app-execution-alias looks like the stable answer, but on a machine with
#     an MSI-installed PowerShell it is a ZERO-BYTE STUB that only opens the Store.
#     Preferring it there would replace a perfectly good path with a dead one.
#     (Seen for real on the HTPC: alias present, 0 bytes; MSI install fine.)
#
# So: prefer the MSI location, then a *non-empty* alias, then a resolved path that
# is not version-stamped, and finally Windows PowerShell 5.1 -- and verify.
$candidates = @()
$candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')

# NOTE: do not size-check the alias. App-execution aliases are ZERO-BYTE reparse
# points on every machine -- a working one and a Store stub are both 0 bytes, so
# size tells you nothing. Only actually running it does.
$alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
if (Test-Path $alias) { $candidates += $alias }

$resolved = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if ($resolved -and $resolved -notmatch '\\WindowsApps\\Microsoft\.PowerShell_') { $candidates += $resolved }

$candidates += "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$host_exe = $null
foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    # Actually run it: a path can exist, be zero bytes, and still be either
    # perfectly good (a real alias) or useless (a Store stub) -- see trap 2.
    # Running is the only test that separates them.
    try {
        $probe = & $c -NoProfile -Command 'Write-Output ok' 2>$null
        if ($probe -contains 'ok') { $host_exe = $c; break }
    } catch { }
}
if (-not $host_exe) { throw "no working PowerShell host found; tried:`n  " + ($candidates -join "`n  ") }
Write-Host "host: $host_exe"

$cmd = "`"$host_exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" `"%1`""

New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name '(default)' -Value 'URL:Plex open'
Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
New-Item -Path "$key\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$key\shell\open\command" -Name '(default)' -Value $cmd

# DefaultIcon - the icon Windows shows for a plexopen:// link, the same way steam://
# names steam.exe. Registered here so the icon belongs to the PROTOCOL, per machine,
# rather than being stored on individual launcher items. Plex HTPC's exe carries a 256 px
# icon, so it stays crisp. Skipped (with a note) when Plex HTPC is not installed.
$iconCandidates = @()
if ($env:PLEX_HTPC_EXE) { $iconCandidates += $env:PLEX_HTPC_EXE }
$running = Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($running -and $running.Path) { $iconCandidates += $running.Path }
$iconCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Plex HTPC\Plex HTPC.exe')
$iconCandidates += (Join-Path $env:ProgramFiles 'Plex\Plex HTPC\Plex HTPC.exe')
if (${env:ProgramFiles(x86)}) { $iconCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Plex\Plex HTPC\Plex HTPC.exe') }
foreach ($dr in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $iconCandidates += (Join-Path $dr.Root 'Plex HTPC\Plex HTPC.exe')
}
$iconExe = $iconCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($iconExe) {
    New-Item -Path "$key\DefaultIcon" -Force | Out-Null
    Set-ItemProperty -Path "$key\DefaultIcon" -Name '(default)' -Value "`"$iconExe`",0"
    Write-Host "icon: $iconExe,0"
} else {
    Write-Host "icon: Plex HTPC.exe not found - DefaultIcon not set (set PLEX_HTPC_EXE and re-run)"
}

Write-Host "registered plexopen:// ->"
Write-Host "  $cmd"
Write-Host "test:  Start-Process 'plexopen://app.plex.tv/desktop/#!/server/<serverId>/details?key=%2Flibrary%2Fmetadata%2F<ratingKey>'"
