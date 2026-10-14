# keepawake.ps1  —  runs forever as SYSTEM (scheduled task SshKeepAwake).
# Holds a system power request (PowerRequestSystemRequired) while at least one
# ESTABLISHED inbound SSH connection (:22) exists, so the machine cannot idle-sleep.
# Clears it when none remain, so the normal idle-sleep timeout resumes. Display
# timeout is left alone. Verifiable via `powercfg /requests`:
#   SYSTEM:  [PROCESS] \Device\...\powershell.exe  SSH session active
$ErrorActionPreference = 'Stop'
$log = 'C:\ProgramData\keepawake\keepawake.log'
function Log($m){ "{0} {1}" -f ([DateTime]::Now.ToString('s')), $m | Out-File $log -Append -Encoding utf8 }

Add-Type -Namespace Win32 -Name PowerReq -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public struct REASON_CONTEXT {
    public uint Version;
    public uint Flags;
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] public string Reason;
}
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr PowerCreateRequest(ref REASON_CONTEXT Context);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool PowerSetRequest(System.IntPtr PowerRequest, int RequestType);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool PowerClearRequest(System.IntPtr PowerRequest, int RequestType);
'@

$ctx = New-Object 'Win32.PowerReq+REASON_CONTEXT'
$ctx.Version = 0
$ctx.Flags   = 1                     # POWER_REQUEST_CONTEXT_SIMPLE_STRING
$ctx.Reason  = 'SSH session active'
$h = [Win32.PowerReq]::PowerCreateRequest([ref]$ctx)
if ($h -eq [IntPtr]::Zero) { Log 'PowerCreateRequest returned NULL - aborting'; return }
$SYSTEM_REQUIRED = 1                  # POWER_REQUEST_TYPE.PowerRequestSystemRequired

Log 'keepawake started'
$held = $false
while ($true) {
    try {
        $n = @(Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue).Count
        if ($n -gt 0 -and -not $held) {
            [void][Win32.PowerReq]::PowerSetRequest($h, $SYSTEM_REQUIRED); $held = $true
            Log "HOLD ($n SSH connection(s)) - system-required set"
        } elseif ($n -eq 0 -and $held) {
            [void][Win32.PowerReq]::PowerClearRequest($h, $SYSTEM_REQUIRED); $held = $false
            Log 'RELEASE (no SSH) - normal idle sleep resumes'
        }
    } catch { Log ('loop error: ' + $_.Exception.Message) }
    Start-Sleep -Seconds 30
}
