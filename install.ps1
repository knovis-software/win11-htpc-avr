# install.ps1 - install or update on the HTPC. Run from a clone of this repo in an elevated PowerShell 7:
#   pwsh -File .\install.ps1
# Needs htpc.config.json (copy htpc.config.example.json). Safe to re-run: files are replaced, tasks re-registered.
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$cfgFile = Join-Path $repo 'htpc.config.json'
if (-not (Test-Path $cfgFile)) { throw "copy htpc.config.example.json to htpc.config.json and fill it in first" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
$dir = $cfg.installDir; $user = "$env:COMPUTERNAME\$($cfg.user)"
New-Item -ItemType Directory -Force $dir, "$dir\speaker-layout\holds" | Out-Null

# 1. Scripts, AutoHotkey, config - one flat folder (the scripts find each other through their own folder).
Copy-Item "$repo\scripts\*.ps1", "$repo\autohotkey\*.ahk", $cfgFile $dir -Force
"[avr]`nip=$($cfg.avr.ip)" | Set-Content "$dir\htpc.ini" -Encoding ascii          # AutoHotkey reads this

# 2. Plex HTPC: gamepad inputmap, and the right-stick -> AVR volume script with its settings.
$plex = "$env:LOCALAPPDATA\Plex HTPC"
New-Item -ItemType Directory -Force "$plex\inputmaps", "$plex\scripts", "$plex\script-opts" | Out-Null
Copy-Item "$repo\plex\xinput.json" "$plex\inputmaps\" -Force
Copy-Item "$repo\plex\plex-avr-volume.lua" "$plex\scripts\" -Force
"avr_ip=$($cfg.avr.ip)`nlog_dir=$($dir -replace '\\','/')" | Set-Content "$plex\script-opts\plex-avr-volume.conf" -Encoding ascii

# 3. Shortcuts your launcher (or Start menu) opens. The launch keys and plexopen use the first two.
$pwsh = (Get-Command pwsh.exe).Source
if ($pwsh -like '*WindowsApps*') { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }   # never a version-stamped Store path
$sh = New-Object -ComObject WScript.Shell
foreach ($l in @(@{ N = 'Plex HTPC 4K HDR'; A = '' }, @{ N = 'Plex HTPC Music'; A = ' -Mode music' }, @{ N = 'Plex HTPC Plain'; A = ' -Mode plain' })) {
  $s = $sh.CreateShortcut("$dir\$($l.N).lnk"); $s.TargetPath = $pwsh
  $s.Arguments = "-NoProfile -WindowStyle Hidden -File `"$dir\PlexHDR.ps1`"$($l.A)"; $s.WorkingDirectory = $dir; $s.Save()
}

# 4. Resident AutoHotkey scripts: logon tasks in the interactive session (a GUI started from a service lands in session 0).
$ahk = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
if (Test-Path $ahk) {
  foreach ($t in @(@{ Name = 'AvrVolume'; Script = 'avr-volume.ahk' }, @{ Name = 'HaLaunchKeys'; Script = 'launch-keys.ahk' })) {
    $action = New-ScheduledTaskAction -Execute $ahk -Argument "`"$dir\$($t.Script)`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    if ((Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue).State -eq 'Running') { Stop-ScheduledTask -TaskName $t.Name }
    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $t.Name
  }
} else { Write-Warning "AutoHotkey v2 not found - volume keys and launch keys skipped (winget install AutoHotkey.AutoHotkey)" }

# 5. plexopen:// links (open Plex web links in Plex HTPC).
& "$dir\register-plexopen.ps1"
"installed to $dir"
