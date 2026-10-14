# Start-StereoApp.ps1 - run a stereo-only app with the Denon's Windows output set to stereo, then put it back to
# 5.1 when the app (and anything it hands playback to) is gone. Deployed to the install folder on the HTPC; launcher items
# launch it through shortcuts in the install folder (YouTube.lnk, StreamGrab.lnk).
#
#   Start-StereoApp.ps1 -Exe <path> [-Arguments '<args>'] [-WaitForCommandLine '<regex>']
#
# Why (2026-10-07): the Denon output's default is 5.1 so games render real surround. Windows never upmixes, so a
# stereo app on a 5.1 output plays from the front pair only, and the Denon cannot run Pro Logic II on
# multichannel PCM. At stereo the Denon upmixes it as before.
#
# * Waits for every process with the app's exe path, not just the one it started: VacuumTube is single-instance
#   (a second launch hands over and exits at once) and Electron runs helper processes under the same exe.
# * -WaitForCommandLine: StreamGrab exits as soon as its stream is playing in a dedicated browser profile. The
#   wrapper then hands the wait for that browser to a detached copy of itself (-Watch) and exits, so the launcher -
#   which pauses its controller handling for its child's lifetime - behaves exactly as it did before.
# * Holds: each running copy keeps <install folder>\speaker-layout\holds\<pid>.hold; 5.1 comes back only when no live hold
#   is left, so YouTube closing does not pull 5.1 back under a stream that is still playing.
# Log: <install folder>\speaker-layout\speaker-layout.log
param(
  [string] $Exe = '',
  [string] $Arguments = '',
  [string] $WaitForCommandLine = '',
  [switch] $Watch,
  [string] $Dir = (Join-Path $PSScriptRoot 'speaker-layout')
)
$ErrorActionPreference = 'Continue'
$holds = Join-Path $Dir 'holds'
New-Item -ItemType Directory -Force $holds | Out-Null
$logFile = Join-Path $Dir 'speaker-layout.log'
function Log([string]$m) { try { Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}' -f (Get-Date), $PID, $m) } catch { } }
. (Join-Path (Split-Path $PSCommandPath) 'SpeakerLayout.ps1')

function Add-Hold { Set-Content -Path (Join-Path $holds "$PID.hold") -Value "$Exe $WaitForCommandLine" }
function Get-LiveHolds {
  foreach ($h in Get-ChildItem $holds -Filter '*.hold' -ErrorAction SilentlyContinue) {
    $hp = [int]$h.BaseName
    if ($hp -ne $PID -and (Get-Process -Id $hp -ErrorAction SilentlyContinue)) { $h }
    elseif ($hp -ne $PID) { Remove-Item $h.FullName -ErrorAction SilentlyContinue }   # stale: its process is gone
  }
}
function Release-Hold {
  Remove-Item (Join-Path $holds "$PID.hold") -ErrorAction SilentlyContinue
  $others = @(Get-LiveHolds)
  if ($others.Count) { Log "released; $($others.Count) other stereo app(s) still running - staying stereo"; return }
  Log ("back to 5.1: " + (Set-SpeakerLayout -Layout 5.1))
}
function Get-MatchingProcesses([string]$pattern) {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $pattern -and $_.CommandLine -notmatch 'Start-StereoApp' }
}

if ($Watch) {
  # Detached: wait for the stream browser to close, then release.
  Add-Hold
  Log "watching for processes matching '$WaitForCommandLine'"
  Start-Sleep -Seconds 3
  $deadline = (Get-Date).AddHours(8)
  while ((Get-Date) -lt $deadline -and @(Get-MatchingProcesses $WaitForCommandLine).Count) { Start-Sleep -Seconds 3 }
  Log "stream browser closed"
  Release-Hold
  return
}

if (-not $Exe -or -not (Test-Path $Exe)) { Log "ERROR: app not found: '$Exe'"; return }
Add-Hold
Log "launch $Exe $Arguments"
Log ("stereo: " + (Set-SpeakerLayout -Layout stereo))
try {
  $sp = @{ FilePath = $Exe; PassThru = $true; WorkingDirectory = (Split-Path $Exe) }
  if ($Arguments) { $sp.ArgumentList = $Arguments }
  $p = Start-Process @sp
  $p.WaitForExit()
  # Single-instance apps and helper processes: wait until nothing runs from that exe any more.
  $full = (Resolve-Path $Exe).Path
  while (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $full }).Count) { Start-Sleep -Seconds 2 }
  Log "app closed"
} catch { Log "ERROR running app: $($_.Exception.Message)" }

if ($WaitForCommandLine -and @(Get-MatchingProcesses $WaitForCommandLine).Count) {
  $argv = @('-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-Watch', '-WaitForCommandLine', "`"$WaitForCommandLine`"", '-Dir', "`"$Dir`"")
  Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argv -WindowStyle Hidden | Out-Null
  Start-Sleep -Milliseconds 800     # let the watcher take its hold before this one goes
  Log "playback continues in its browser; a background watcher holds stereo until it closes"
  Remove-Item (Join-Path $holds "$PID.hold") -ErrorAction SilentlyContinue
  return
}
Release-Hold
