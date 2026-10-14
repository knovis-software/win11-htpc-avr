# Runs <install folder>\PlexHDR.ps1 with the given arguments inside the interactive desktop session
# (display changes only work there) and prints its output.
# Examples:
#   pwsh -File <install folder>\run-in-session.ps1 -ScriptArgs "-Mode status"
#   pwsh -File <install folder>\run-in-session.ps1 -ScriptArgs "-Mode desktop -DesktopScaler gpu"
param([Parameter(Mandatory=$true)] [string]$ScriptArgs, [int]$WaitSeconds = 120)
if ($ScriptArgs -notmatch '-Mode\s+\S+') { throw "ScriptArgs must include -Mode <mode> (refusing to run the default 'plex' mode from here)" }
$out = Join-Path $PSScriptRoot 'session_last.txt'
Set-Content $out '' -Encoding UTF8
$task = 'plexhdr-session'
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"& '$(Join-Path $PSScriptRoot 'PlexHDR.ps1')' $ScriptArgs *> '$out'`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $task
for ($i = 0; $i -lt $WaitSeconds; $i++) { Start-Sleep 1; if ((Get-ScheduledTask -TaskName $task).State -eq 'Ready') { break } }
Unregister-ScheduledTask -TaskName $task -Confirm:$false
Get-Content $out -EA SilentlyContinue
