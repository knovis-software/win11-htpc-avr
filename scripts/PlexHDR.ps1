<#
PlexHDR.ps1 - Launch Plex HTPC with a viewing/listening profile, and put everything back on exit.
Built-in Windows APIs only (user32 ChangeDisplaySettingsEx + DisplayConfig HDR state) plus the Sony
Bravia and Denon IP control protocols. No downloads.

Settings (TV / AVR addresses, display modes): htpc.config.json next to this script (see htpc.config.example.json).
Brand-specific parts: the Sony Bravia picture-mode functions below (Invoke-TvVideo / Set-TvPicture) and AvrAudio.ps1
(Denon / Marantz). Swap those for another TV or receiver; the rest is plain Windows + Plex HTPC.

Launch profiles - one shortcut each in the install folder, all through this one script so every profile gets
the gamepad fix and none can forget it:
  PlexHDR.ps1                  'plex'  FULL QUALITY. AVR movie profile (PLII Movie memory + MSMOVIE, Audyssey
                                       Reference, Dynamic EQ on at 0 dB offset, every compressor/EQ off),
                                       then 4K60 + TV 'custom' with light sensor / contrast enhancer / local
                                       dimming off (Plex switches HDR per title). On exit: AVR baseline
                                       restored, TV 'game' (same companions), HDR off, 1080p120 (boot default).
  PlexHDR.ps1 -Mode music      'music' AVR music profile (Multi Ch Stereo since 2026-10-06, Audyssey Reference, Dynamic EQ
                                       on at 10 dB offset, compression/EQ off). Display and TV left alone.
                                       AVR baseline restored on exit.
  Both profiles read the AVR back after Plex is up and confirm the sound mode once a title plays
  (PlexHDR.log here). The pre-profile baseline is kept in avr-baseline.json here until a
  restore has actually reached the unit, so a standby at exit is retried at the next launch.
  Since 2026-09-14 the baseline + profile (~20 s of telnet) run in a background job when the AVR
  is already on, so Plex starts ~6 s after the click instead of ~26 s; on exit the display is
  restored before the AVR is. Standby still takes the serial path (wake, settle, then switch).
  PlexHDR.ps1 -Mode plain      'plain' Changes nothing at all; only keeps the gamepad working.
  Every launching mode takes   -Url <plex web link>  to play that item or PLAYLIST once Plex is up,
  handed to plexopen.ps1, e.g.  -Mode music -Url 'https://app.plex.tv/desktop/#!/server/<id>/...key=%2Fplaylists%2F40511'

Utility modes (no launch):
  PlexHDR.ps1 -Mode movie      4K + HDR on + TV movie mode
  PlexHDR.ps1 -Mode desktop    TV game mode + HDR off + 1080p120
  PlexHDR.ps1 -Mode status     print current mode, HDR state, bit depth, encoding and the live signal
  PlexHDR.ps1 -Mode probe      switch to 4K60 and back, printing the signal each time
Launcher / shortcut line:  pwsh.exe -NoProfile -WindowStyle Hidden -File "<install folder>\PlexHDR.ps1"
#>
param(
  [ValidateSet('plex','music','plain','movie','desktop','status','probe','restore')] [string]$Mode = 'plex',
  [switch]$RestoreDisplay,   # with -Mode restore (started by Start-DetachedRestore): also put TV/HDR/1080p back
  [string]$Url = '',       # optional Plex web link (item or playlist) to play once the player is up
  [string]$PlexExe = '',   # auto-detected below if empty
  [string]$LogFile = '',   # default: PlexHDR.log next to this script
  # Display modes: defaults come from htpc.config.json ("display"), these only apply without it.
  [int]$MovieW = 3840, [int]$MovieH = 2160, [int]$MovieHz = 60,
  [int]$DesktopW = 1920, [int]$DesktopH = 1080, [int]$DesktopHz = 120,
  [int]$SettleSeconds = 3,
  # Who upscales the 1080p desktop: 'tv' sends a real 1080p signal (TV scales); 'gpu' keeps the 4K signal and the GPU's display engine scales.
  [ValidateSet('tv','gpu')] [string]$DesktopScaler = 'tv',
  # Sony Bravia picture-mode switching (optional). Needs IP control with a pre-shared key on the TV; key goes in $TvPskFile (one line).
  # Defaults from htpc.config.json ("tv"); an empty TV IP turns picture-mode switching off.
  [string]$TvIp = '', [string]$TvPskFile = '',
  [string]$TvMovieMode = '', [string]$TvGameMode = '',
  # Plex HTPC has its own "HDR switching" (player.hdrSwitchingEnabled=1): it turns Windows HDR on only while an HDR title
  # plays, so SDR titles and the Plex UI stay SDR. Leave this off and let Plex do it; HDR is still forced off on exit.
  [switch]$HdrAtLaunch
)
. (Join-Path $PSScriptRoot 'HtpcConfig.ps1')
$htpc = Get-HtpcConfig   # not $cfg: functions below use $cfg for plex.ini
if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'PlexHDR.log' }
if (-not $TvIp) { $TvIp = "$($htpc.tv.ip)" }
if (-not $TvPskFile) { $TvPskFile = "$($htpc.tv.pskFile)" }
if (-not $TvMovieMode) { $TvMovieMode = if ($htpc.tv.movieMode) { $htpc.tv.movieMode } else { 'custom' } }
if (-not $TvGameMode) { $TvGameMode = if ($htpc.tv.desktopMode) { $htpc.tv.desktopMode } else { 'game' } }
foreach ($m in @(@{ Key = 'movie'; W = 'MovieW'; H = 'MovieH'; Hz = 'MovieHz' }, @{ Key = 'desktop'; W = 'DesktopW'; H = 'DesktopH'; Hz = 'DesktopHz' })) {
  if ($htpc.display.($m.Key) -match '^(\d+)x(\d+)@(\d+)$' -and -not $PSBoundParameters.ContainsKey($m.W)) {
    Set-Variable $m.W ([int]$Matches[1]); Set-Variable $m.H ([int]$Matches[2]); Set-Variable $m.Hz ([int]$Matches[3])
  }
}
# The receiver's HDMI audio device as Windows names it ("2 - DENON-AVR"); matched as a substring.
$script:AvrAudioName = if ($htpc.avr.windowsAudioName) { $htpc.avr.windowsAudioName } else { 'DENON-AVR' }
$fixedOut = if ($DesktopScaler -eq 'gpu') { 2 } else { 0 }
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }   # for Start-DetachedRestore
if (-not $PlexExe) {
  $PlexExe = @("$env:ProgramFiles\Plex\Plex HTPC\Plex HTPC.exe", "$env:LOCALAPPDATA\Programs\Plex HTPC\Plex HTPC.exe", "${env:ProgramFiles(x86)}\Plex\Plex HTPC\Plex HTPC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
function Log([string]$msg) {
  try {
    # Bound the log. It is append-only and every launch adds ~8 lines, so without
    # this it grows forever. Past the threshold keep the most recent lines only.
    $f = Get-Item $LogFile -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 200KB) { [IO.File]::WriteAllLines($LogFile, (Get-Content $LogFile -Tail 1000)) }
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg)
  } catch {}
}

# Sony Bravia picture settings over the REST API (POST /sony/video, v1.0 — this set rejects v1.1).
# One target per request: the API reports a multi-target failure only as "40004, one of them
# failed", so single targets are the only way to know which. Sony's own doc recommends it too.
function Invoke-TvVideo([string]$method, [string]$paramsJson, [string]$psk) {
  $body = '{"method":"' + $method + '","id":1,"params":[' + $paramsJson + '],"version":"1.0"}'
  $headers = @{}
  if ($psk) { $headers['X-Auth-PSK'] = $psk }
  Invoke-RestMethod -Uri "http://$TvIp/sony/video" -Method Post -Body $body -ContentType 'application/json' -Headers $headers -TimeoutSec 5
}

# Values that must accompany EVERY picture mode we select. They are per mode on the TV, they are
# in the API's exposed set, and the live read on 2026-09-12 found all three wrong (light sensor
# on, contrast enhancer and local dimming on medium) — see ../av-settings-audit.md §4:
#   lightSensor off          — otherwise the picture changes with the room light
#   xtendedDynamicRange off  — "Adv. contrast enhancer", a non-linear contrast tweak
#   autoLocalDimming off     — a backlight function; an OLED has no backlight to dim
# Everything else that matters (Peak luminance, noise reductions, Motionflow, CineMotion,
# Reality Creation, HDR tone mapping) is menu-only and was set by hand 2026-09-13; the API cannot
# read or write it. NOTE the API acts on the SDR mode set while the desktop is SDR; the HDR set
# (used when Plex flips HDR on) was configured once by hand at the same time.
$script:TvModeCompanions = [ordered]@{ lightSensor = 'off'; xtendedDynamicRange = 'off'; autoLocalDimming = 'off' }

# Select a picture mode and pin its companions, then READ BACK. Returns one summary string for
# the log; "tv=custom ok" when every value is confirmed, otherwise what differs.
function Set-TvPicture([string]$mode) {
  if (-not $mode -or -not $TvIp) { return 'skipped(no TV configured)' }
  if (-not $TvPskFile -or -not (Test-Path $TvPskFile)) { return 'skipped(no key file)' }
  try {
    $psk = (Get-Content $TvPskFile -TotalCount 1).Trim()
    $wanted = [ordered]@{ pictureMode = $mode }
    foreach ($k in $script:TvModeCompanions.Keys) { $wanted[$k] = $script:TvModeCompanions[$k] }
    $setErrors = @{}
    foreach ($target in $wanted.Keys) {
      $r = Invoke-TvVideo 'setPictureQualitySettings' ('{"settings":[{"target":"' + $target + '","value":"' + $wanted[$target] + '"}]}') $psk
      if ($r.error) { $setErrors[$target] = ($r.error -join ' ') }
    }
    # Read back — the read-back is the verdict. A set can be refused with "7 Illegal State"
    # when the TV considers the item not adjustable right now (seen for xtendedDynamicRange
    # 2026-09-13) while the value already reads as wanted; that is a note, not a WARN.
    $diff = @(); $notes = @()
    foreach ($target in $wanted.Keys) {
      $r = Invoke-TvVideo 'getPictureQualitySettings' ('{"target":"' + $target + '"}') $psk
      if ($r.error) { $diff += "$target read error $($r.error -join ' ')"; continue }
      $now = ($r.result[0] | Where-Object { $_.target -eq $target } | Select-Object -First 1).currentValue
      # Keep the TV's refusal in the WARN: "40005 Display Is Turned off" (TV in standby, harmless) and a
      # lock such as ALLM ("7 Illegal State") both read back as pictureMode=game, and only the code tells
      # them apart (the 2026-10-09 bluescreen launches all logged this WARN without it).
      if ("$now" -ne $wanted[$target]) { $diff += "$target=$now (wanted $($wanted[$target])$(if ($setErrors.ContainsKey($target)) { "; set refused: $($setErrors[$target])" }))" }
      elseif ($setErrors.ContainsKey($target)) { $notes += "$target set refused ($($setErrors[$target])) but already $now" }
    }
    if ($diff) { return "tv=$mode WARN " + ($diff -join '; ') }
    if ($notes) { return "tv=$mode ok (" + ($notes -join '; ') + ")" }
    "tv=$mode ok (" + (($script:TvModeCompanions.Keys | ForEach-Object { "$_=off" }) -join ' ') + ")"
  } catch { "tv failed: $($_.Exception.Message)" }
}
$ErrorActionPreference = 'Stop'

if (-not ('PlexHDR.Native' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace PlexHDR {
public static class Native {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr lp);

  [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology, rotation, scaling, refreshNum, refreshDen, scanLineOrdering; public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Sequential, Size=64)] struct MODE_INFO { public uint infoType; public uint id; public LUID adapterId; }
  [StructLayout(LayoutKind.Sequential)] struct HDR_HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }
  [StructLayout(LayoutKind.Sequential)] struct COLOR_INFO2 { public HDR_HEADER h; public uint value; public uint colorEncoding; public uint bitsPerColorChannel; public uint activeColorMode; }
  [StructLayout(LayoutKind.Sequential)] struct COLOR_INFO { public HDR_HEADER h; public uint value; public uint colorEncoding; public uint bitsPerColorChannel; }
  [StructLayout(LayoutKind.Sequential)] struct SET_STATE { public HDR_HEADER h; public uint value; }
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, [Out] MODE_INFO[] modes, IntPtr topology);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref COLOR_INFO2 info);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref COLOR_INFO info);
  [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SET_STATE info);

  public static string GetMode() {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettingsW(null, -1, ref dm)) return "unknown";
    return dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
  }
  // fixedOutput: 0 = driver default (TV gets the real timing), 2 = DMDFO_STRETCH (GPU scales; signal stays at the panel's native timing)
  public static int SetMode(int w, int h, int hz, bool persist, int fixedOutput) {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettingsW(null, -1, ref dm)) return -100;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmDisplayFrequency = hz;
    dm.dmFields = 0x80000 | 0x100000 | 0x400000;
    if (fixedOutput != 0) { dm.dmDisplayFixedOutput = fixedOutput; dm.dmFields |= 0x20000000; }   // DM_DISPLAYFIXEDOUTPUT
    return ChangeDisplaySettingsExW(null, ref dm, IntPtr.Zero, persist ? 1u : 0u, IntPtr.Zero);   // 1 = CDS_UPDATEREGISTRY (becomes the boot default)
  }
  static bool FirstTarget(out PATH_TARGET t) {
    uint np, nm; t = new PATH_TARGET();
    if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return false;
    var paths = new PATH_INFO[np]; var modes = new MODE_INFO[nm];
    if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0 || np == 0) return false;
    t = paths[0].targetInfo; return true;
  }
  // returns: supported,enabled,api  (api 15 = 24H2+ HDR info, 9 = legacy advanced color)
  public static int[] GetHdr() {
    PATH_TARGET t; if (!FirstTarget(out t)) return new int[] { -1, -1, 0 };
    var c2 = new COLOR_INFO2(); c2.h.type = 15; c2.h.size = (uint)Marshal.SizeOf(typeof(COLOR_INFO2)); c2.h.adapterId = t.adapterId; c2.h.id = t.id;   // GET_ADVANCED_COLOR_INFO_2 (Win11 24H2+)
    if (DisplayConfigGetDeviceInfo(ref c2) == 0)
      return new int[] { (c2.value & 0x10) != 0 ? 1 : 0, (c2.value & 0x20) != 0 ? 1 : 0, 15, (int)c2.bitsPerColorChannel, (int)c2.colorEncoding };
    var c = new COLOR_INFO(); c.h.type = 9; c.h.size = (uint)Marshal.SizeOf(typeof(COLOR_INFO)); c.h.adapterId = t.adapterId; c.h.id = t.id;
    if (DisplayConfigGetDeviceInfo(ref c) == 0)
      return new int[] { (c.value & 1) != 0 ? 1 : 0, (c.value & 2) != 0 ? 1 : 0, 9, (int)c.bitsPerColorChannel, (int)c.colorEncoding };
    return new int[] { -1, -1, 0, 0, 0 };
  }
  [StructLayout(LayoutKind.Sequential)] struct MODE_INFO_RAW { public uint infoType; public uint id; public LUID adapterId; public ulong pixelRate; public uint hNum, hDen, vNum, vDen; public uint activeCx, activeCy, totalCx, totalCy; public uint videoStandard; public uint scanLine; }
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, [Out] MODE_INFO_RAW[] modes, IntPtr topology);
  // actual signal the GPU is driving to the display: "activeW x activeH @ vsync Hz, pixel clock MHz"
  public static string GetTargetSignal() {
    uint np, nm; if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return "err-sizes";
    var paths = new PATH_INFO[np]; var modes = new MODE_INFO_RAW[nm];
    if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0 || np == 0) return "err-query";
    uint idx = paths[0].targetInfo.modeInfoIdx; if (idx >= nm) return "no-target-mode";
    var m = modes[idx]; double v = m.vDen == 0 ? 0 : (double)m.vNum / m.vDen;
    return m.activeCx + "x" + m.activeCy + " @ " + v.ToString("0.###") + " Hz, " + (m.pixelRate / 1e6).ToString("0.#") + " MHz pixel clock";
  }
  // DISPLAYCONFIG_MODE_INFO as a union: target (video signal) fields and source (desktop) fields share offset 16
  [StructLayout(LayoutKind.Explicit, Size=64)] struct MODE_INFO_U {
    [FieldOffset(0)] public uint infoType; [FieldOffset(4)] public uint id; [FieldOffset(8)] public LUID adapterId;
    [FieldOffset(16)] public ulong pixelRate; [FieldOffset(24)] public uint hNum; [FieldOffset(28)] public uint hDen; [FieldOffset(32)] public uint vNum; [FieldOffset(36)] public uint vDen;
    [FieldOffset(40)] public uint activeCx; [FieldOffset(44)] public uint activeCy; [FieldOffset(48)] public uint totalCx; [FieldOffset(52)] public uint totalCy; [FieldOffset(56)] public uint videoStandard; [FieldOffset(60)] public uint scanLine;
    [FieldOffset(16)] public uint srcWidth; [FieldOffset(20)] public uint srcHeight; [FieldOffset(24)] public uint srcPixelFormat; [FieldOffset(28)] public int srcPosX; [FieldOffset(32)] public int srcPosY; }
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [In, Out] PATH_INFO[] paths, ref uint numModes, [In, Out] MODE_INFO_U[] modes, IntPtr topology);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPaths, [In] PATH_INFO[] paths, uint numModes, [In] MODE_INFO_U[] modes, uint flags);
  // Desktop at w x h while the signal keeps its current (native) timing; the GPU's display engine scales. Same thing Settings does.
  public static int SetScaledDesktop(int w, int h, bool persist) {
    uint np, nm; if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return -10;
    var paths = new PATH_INFO[np]; var modes = new MODE_INFO_U[nm];
    if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0 || np == 0) return -11;
    uint si = paths[0].sourceInfo.modeInfoIdx; if (si >= nm) return -12;
    modes[si].srcWidth = (uint)w; modes[si].srcHeight = (uint)h;
    paths[0].targetInfo.scaling = 3;   // DISPLAYCONFIG_SCALING_STRETCHED
    uint flags = 0x80 | 0x20 | 0x400 | (persist ? 0x200u : 0u);   // APPLY | USE_SUPPLIED_DISPLAY_CONFIG | ALLOW_CHANGES | SAVE_TO_DATABASE
    return SetDisplayConfig(np, paths, nm, modes, flags);
  }
  // returns the api type that succeeded (15 or 10), or negative error
  public static int SetHdr(bool on) {
    PATH_TARGET t; if (!FirstTarget(out t)) return -1;
    foreach (uint type in new uint[] { 16, 10 }) {   // 16 = SET_HDR_STATE (24H2+), 10 = legacy SET_ADVANCED_COLOR_STATE
      var s = new SET_STATE(); s.h.type = type; s.h.size = (uint)Marshal.SizeOf(typeof(SET_STATE)); s.h.adapterId = t.adapterId; s.h.id = t.id; s.value = on ? 1u : 0u;
      if (DisplayConfigSetDeviceInfo(ref s) == 0) return (int)type;
    }
    return -2;
  }
}}
"@
}

function Get-Mode { [PlexHDR.Native]::GetMode() }
function Set-Mode([int]$w, [int]$h, [int]$hz, [bool]$persist = $false, [int]$fixedOutput = 0) {
  if ($fixedOutput -eq 0) {
    if ((Get-Mode) -eq "${w}x${h}@$hz") { return 'already' }
    $r = [PlexHDR.Native]::SetMode($w, $h, $hz, $persist, 0)
    # -2 = DISP_CHANGE_BADMODE: the mode is not in the list YET. A TV that was just powered on (the family-room
    # button, 2026-10-13 18:35) is "on" for Home Assistant within a second, but the HDMI chain through the Denon
    # takes several more to come up; until then Windows offers no 4K (hdrSupported=False too). Wait for it.
    $waited = 0
    while ($r -eq -2 -and $waited -lt 30) { Start-Sleep 2; $waited += 2; $r = [PlexHDR.Native]::SetMode($w, $h, $hz, $persist, 0) }
    if ($r -ne 0) { throw "display mode change to ${w}x${h}@$hz failed (code $r$(if ($waited) { ", after waiting $waited s for the mode" }))" }
    return $(if ($waited) { "changed (after waiting $waited s for the display chain)" } else { 'changed' })
  }
  # GPU-scaled desktop: make sure the signal timing is the movie (native) timing, then set the desktop size on top of it.
  $t = Set-Mode $MovieW $MovieH $MovieHz $persist 0
  Start-Sleep 2
  $r = [PlexHDR.Native]::SetScaledDesktop($w, $h, $persist)
  if ($r -ne 0) { throw "scaled desktop ${w}x${h} over native timing failed (code $r)" }
  "changed(gpu-scaled; timing $t)"
}
function Get-Hdr {
  $v = [PlexHDR.Native]::GetHdr()
  $enc = @('RGB','YCbCr444','YCbCr422','YCbCr420','Intensity')[[math]::Min($v[4], 4)]
  [pscustomobject]@{ supported = ($v[0] -eq 1); enabled = ($v[1] -eq 1); api = $v[2]; bits = $v[3]; encoding = $enc }
}
function Set-Hdr([bool]$on) {
  $h = Get-Hdr
  if (-not $h.supported) { throw 'display does not report HDR support' }
  if ($h.enabled -eq $on) { return 'already' }
  $r = [PlexHDR.Native]::SetHdr($on)
  if ($r -lt 0) { throw "HDR state change failed (code $r)" }
  "changed(api $r)"
}
function Show-Status { $h = Get-Hdr; "mode=$(Get-Mode) hdrSupported=$($h.supported) hdrOn=$($h.enabled) bits=$($h.bits) enc=$($h.encoding) api=$($h.api) signal=[$([PlexHDR.Native]::GetTargetSignal())]" }

# --- Denon AVR listening profiles (AvrAudio.ps1, kept next to this script) ------------------------------
# Dot-sourced at SCRIPT level so its functions land in script scope. If the file is missing, the launch
# profiles still work and simply leave the audio alone.
$script:HaveAvr = $false
$avrModule = Join-Path $PSScriptRoot 'AvrAudio.ps1'
if (Test-Path $avrModule) { . $avrModule; $script:HaveAvr = $true }

# Capture the baseline, then apply a profile. Never throws: an unreachable AVR must not stop Plex
# from launching.
#
# The baseline lives on disk (AvrAudio.ps1: Save-AvrBaseline) from capture until a restore has
# actually been applied. A file already present here means the previous session's restore was
# skipped — the AVR was in standby when Plex exited — and the unit is still holding that
# session's PROFILE. Snapshotting now would enshrine the profile as the baseline (that is how
# the AVR was found sitting in PLII Music + Flat on 2026-09-12), so the file's state is reused.
#
# TIMING (2026-09-14). The baseline read is 21 telnet queries at 700 ms (~15 s) and the profile
# another ~5 s; until today both ran BEFORE the display switch and the Plex launch, so every launch
# spent ~20 of its ~42 s (launcher click to first frame) waiting on the AVR for nothing Plex needed.
# What Plex does need is the AVR ON, so the HDMI chain is up before the 4K switch — one query.
# So Start-AvrProfile checks power on this thread and, if the unit is already on, runs the
# baseline + profile below in a background thread job while the display switch and the Plex
# launch carry on. The AVR holds ONE telnet connection, so nothing on this thread may touch it
# until Receive-AvrProfile has collected the job (Start-PlexSession does that after Plex is on
# screen, before the read-back). Standby is the exception: wake, settle, then the serial order
# as before, so the chain has settled before the mode change.
#
# The profile's ~15 s read-back is deferred (-NoVerify): Start-PlexSession verifies after Plex is
# on screen, together with the sound-mode watch.
#
# This body runs either in the job (no Log function there; lines come back with the job) or
# inline on this thread for the standby path. It returns Baseline (for Exit-AvrProfile), Ok
# (profile sent without an exception) and Lines (what to log).
$script:AvrEnterBody = {
  param([string]$Module, [string]$ProfileName, [bool]$NoPowerOn)
  $lines = [System.Collections.Generic.List[string]]::new()
  $say = { param($m) $lines.Add(("{0} (at {1:HH:mm:ss})" -f $m, (Get-Date))) }
  $baseline = $null; $ok = $false
  try {
    . $Module
    $baseline = Read-AvrBaseline
    $current = $null      # what the unit holds NOW, for Set-AvrProfile's send-only-what-differs
    if ($baseline) {
      & $say ("avr: previous restore was skipped - reusing its baseline: " + (Format-AvrState $baseline))
    } else {
      $baseline = Get-AvrState
      Save-AvrBaseline $baseline
      $current = $baseline
      & $say ("avr: baseline saved: " + (Format-AvrState $baseline))
    }
    [void](Set-AvrProfile -Profile $ProfileName -NoVerify -NoPowerOn:$NoPowerOn -Current $current -Logger { param($m) & $say $m })
    $ok = $true
  } catch {
    & $say "avr: '$ProfileName' profile failed ($($_.Exception.Message)) - audio left alone"
    $baseline = $null
  }
  [pscustomobject]@{ Baseline = $baseline; Ok = $ok; Lines = $lines.ToArray() }
}
$script:AvrJob = $null       # the running background job, until Receive-AvrProfile
$script:AvrSaved = $null     # the baseline to restore at exit (set by Receive-AvrProfile)

function Start-AvrProfile([string]$name) {
  if (-not $script:HaveAvr) { Log "avr: AvrAudio.ps1 not found next to PlexHDR.ps1 - audio left alone"; return }
  try { $power = (Get-AvrState -Fields Power).Power }
  catch { Log "avr: unreachable ($($_.Exception.Message)) - audio left alone"; return }
  if ($power -like 'PWON*') {
    # Thread jobs are built into pwsh 7 (what the shortcuts run); Start-Job is the slower fallback.
    $starter = if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { 'Start-ThreadJob' } else { 'Start-Job' }
    $script:AvrJob = & $starter -ScriptBlock $script:AvrEnterBody -ArgumentList $avrModule, $name, $true
    $script:AvrProfileName = $name
    Log "avr: on - baseline + '$name' profile running in the background ($starter); display and Plex carry on"
  } else {
    # Standby: the HDMI chain is down until the unit wakes, so wake it and settle BEFORE the mode
    # switch. Serial, as every launch was before 2026-09-14 (baseline is read in standby, as before).
    Log "avr: in standby ($power) - waking first, then baseline and profile before the display switch"
    $r = & $script:AvrEnterBody $avrModule $name $false
    $r.Lines | ForEach-Object { Log $_ }
    if ($r.Ok) { $script:AvrProfileName = $name }
    $script:AvrSaved = $r.Baseline
  }
}
# Collect the background job (idempotent). Must run before anything else talks to the AVR.
function Receive-AvrProfile {
  if (-not $script:AvrJob) { return }
  $job = $script:AvrJob; $script:AvrJob = $null
  try {
    $null = Wait-Job $job -Timeout 90
    if ($job.State -ne 'Completed') { throw "job state $($job.State)" }
    $r = Receive-Job $job -ErrorAction Stop | Select-Object -Last 1
    $r.Lines | ForEach-Object { Log $_ }
    if (-not $r.Ok) { $script:AvrProfileName = $null }
    $script:AvrSaved = $r.Baseline
  } catch {
    Log "avr: background profile failed ($($_.Exception.Message)) - audio left alone"
    $script:AvrProfileName = $null
  } finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
}
function Exit-AvrProfile {
  Receive-AvrProfile
  $saved = $script:AvrSaved
  if (-not $script:HaveAvr -or -not $saved) { return }
  try {
    $result = Restore-AvrState -State $saved -Logger { param($m) Log $m }
    Log "avr: restore $result"
    # Only a restore that reached the unit retires the baseline; a skipped one is retried next launch.
    if ("$result" -like 'restored*') { Remove-AvrBaseline }
  } catch { Log "avr: restore failed ($($_.Exception.Message)) - baseline kept" }
}

# Plex's audio settings can silently lose passthrough: if the saved WASAPI endpoint is not found at
# startup (Windows re-creates the HDMI endpoint under a new GUID after a driver/EDID change — two dead
# DENON-AVR GUIDs sit in this box's registry) or the audio page is edited, Plex falls back to
# "auto" (a Basic-kind device), and with a Basic device it clears every codec toggle and decodes
# to PCM. Seen 2026-09-13: a channel-layout edit did exactly that and a DTS film played as stereo.
# Read-only check of plex.ini before Plex starts; a WARN in the log is the whole point.
function Test-PlexAudioConfig {
  $ini = Join-Path $env:LOCALAPPDATA 'Plex HTPC\plex.ini'
  if (-not (Test-Path $ini)) { return 'plex.ini not found' }
  $cfg = @{}
  foreach ($line in Get-Content $ini) { if ($line -match '^([^=;#\[]+)=(.*)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() } }
  $problems = @()
  if ($cfg['player.audioDevice'] -notlike 'wasapi/*') { $problems += "audioDevice='$($cfg['player.audioDevice'])' (not the HDMI endpoint)" }
  if ($cfg['player.audioDeviceKind'] -ne '2')          { $problems += "audioDeviceKind=$($cfg['player.audioDeviceKind']) (2 = HDMI)" }
  foreach ($codec in 'DolbyDigital','DolbyDigitalPlus','TrueHd','DTS','DTSHd') { if ($cfg[$codec] -ne '1') { $problems += "$codec=$($cfg[$codec])" } }
  if ($cfg['player.audioChannelLayout'] -and $cfg['player.audioChannelLayout'] -ne 'auto') { $problems += "channelLayout=$($cfg['player.audioChannelLayout']) (auto keeps stereo music 2-ch for PLII)" }
  if ($problems) { return 'WARN passthrough is OFF in Plex - fix in Settings > Audio (pick the receiver HDMI device, re-enable the codecs): ' + ($problems -join '; ') }
  'ok (HDMI device, 5 codecs, channels auto)'
}

# Point Plex at the Denon BY NAME before every start (2026-10-06). Windows re-creates the DENON-AVR
# HDMI endpoint under a new GUID whenever the receiver's HDMI identity changes (five GUIDs between
# 2026-09-22 and 2026-10-06, all on the same AMD HDMI audio function - not driver reinstalls). Plex
# stores the device by GUID and picks the first PRESENT entry of QtAudioDevicePreferredOrder, so each
# new GUID silently drops it to "auto" (Basic kind: no passthrough, Windows-negotiated stereo). This
# finds the one ACTIVE render endpoint named DENON-AVR and writes it into plex.ini the way Plex's own
# audio page does: first in the preferred order, HDMI kind with the five codecs in its QtAudioDevices
# entry, and the flat player.audio* / codec keys. Only while Plex is closed (Plex rewrites plex.ini on
# exit); never when there is not exactly one active Denon output; one rolling backup beside the file.
$script:PlexCodecs = @('ac3', 'dts', 'dts-hd', 'eac3', 'truehd')
function Get-ActiveDenonEndpoints {
  $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
  $nameKey = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'          # PKEY_Device_FriendlyName ("2 - DENON-AVR")
  foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
    $state = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DeviceState
    if (([int]$state -band 0xF) -ne 1) { continue }               # 1 = DEVICE_STATE_ACTIVE
    $name = (Get-ItemProperty "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue).$nameKey
    if ($name -like "*$($script:AvrAudioName)*") { [pscustomobject]@{ Guid = $k.PSChildName.ToLower(); Name = $name } }
  }
}
function Repair-PlexAudioDevice([int]$WaitSeconds = 0) {
  $ini = Join-Path $env:LOCALAPPDATA 'Plex HTPC\plex.ini'
  if (-not (Test-Path $ini)) { return 'skipped (plex.ini not found)' }
  if (Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue) { return 'skipped (Plex already running; it rewrites plex.ini on exit)' }
  # The output appears only once the receiver is on and HDMI has settled (after a wake or a 4K switch).
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  do {
    $eps = @(Get-ActiveDenonEndpoints)
    if ($eps.Count -ge 1 -or (Get-Date) -ge $deadline) { break }
    Start-Sleep -Milliseconds 500
  } while ($true)
  if ($eps.Count -eq 0) { return "skipped (no active $($script:AvrAudioName) output - receiver off?)" }
  if ($eps.Count -gt 1) { return "skipped ($($eps.Count) active $($script:AvrAudioName) outputs - ambiguous: $(($eps.Guid) -join ', '))" }
  $dev = "wasapi/$($eps[0].Guid)"

  $text = [IO.File]::ReadAllText($ini)
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = [Collections.Generic.List[string]]($text -split '\r?\n')
  function Get-Line([string]$key) { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith("$key=")) { return $i } }; -1 }
  function Get-Val([string]$key) { $i = Get-Line $key; if ($i -ge 0) { $lines[$i].Substring($key.Length + 1) } else { $null } }
  # Qt quotes these values and escapes " and \ with a backslash. Refuse anything else rather than guess.
  function Read-QtJson([string]$key) {
    $v = Get-Val $key
    if (-not $v) { return $null }
    if ($v -notmatch '^"(.*)"$') { return $null }
    $inner = $Matches[1]
    if ($inner -match '\\[^"\\]') { return $null }
    [regex]::Replace($inner, '\\(["\\])', '$1')
  }
  function Write-Val([string]$key, [string]$value) {
    $i = Get-Line $key
    if ($i -ge 0) { $lines[$i] = "$key=$value" } else { $w = Get-Line 'player.audioDevice'; $lines.Insert([Math]::Max(1, $w + 1), "$key=$value") }
  }
  function Write-QtJson([string]$key, [string]$json) { Write-Val $key ('"' + $json.Replace('\', '\\').Replace('"', '\"') + '"') }

  # Preferred order: the current Denon first, everything else kept in its order.
  $order = Read-QtJson 'QtAudioDevicePreferredOrder'
  $names = if ($order) { @([regex]::Matches($order, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) } else { @('auto') }
  $newOrder = @($dev) + @($names | Where-Object { $_ -ne $dev })
  $orderJson = '[' + (($newOrder | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'

  # Device table: a JSON array of flat objects. Split it with a string-aware scanner - device names
  # themselves contain braces ("wasapi/{guid}"), so a regex over braces cuts entries apart.
  $devices = Read-QtJson 'QtAudioDevices'
  $codecJson = '[' + (($script:PlexCodecs | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
  $entryJson = $null; $devicesJson = $null; $mine = $null
  if ($devices) {
    $objs = [Collections.Generic.List[string]]::new()
    $depth = 0; $inStr = $false; $esc = $false; $start = -1
    for ($c = 0; $c -lt $devices.Length; $c++) {
      $ch = $devices[$c]
      if ($inStr) { if ($esc) { $esc = $false } elseif ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }; continue }
      if ($ch -eq '"') { $inStr = $true }
      elseif ($ch -eq '{') { if ($depth -eq 0) { $start = $c }; $depth++ }
      elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $objs.Add($devices.Substring($start, $c - $start + 1)) } }
    }
    if ($depth -ne 0 -or $inStr -or $objs.Count -eq 0) { $devices = $null; $objs.Clear() }
  }
  if ($devices) {
    $mine = $objs | Where-Object { $_ -match ('"name":"' + [regex]::Escape($dev) + '"') } | Select-Object -First 1
    $desc = if ($mine -and $mine -match '"description":"([^"]*)"') { $Matches[1] } else { $eps[0].Name + ' (AMD High Definition Audio Device)' }
    $seen = if ($mine -and $mine -match '"lastPresent":"([^"]*)"') { $Matches[1] } else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    $entryJson = '{"name":"' + $dev + '","description":"' + $desc + '","present":true,"lastPresent":"' + $seen +
                 '","kind":2,"channelLayout":"auto","transcodeToAC3":false,"passthroughCodecs":' + $codecJson + '}'
    $rest = @($objs | Where-Object { $_ -ne $mine })
    $devicesJson = '[' + ((@($rest) + @($entryJson)) -join ',') + ']'
  }

  $want = [ordered]@{
    'player.audioDevice' = $dev; 'player.audioDeviceKind' = '2'; 'player.audioChannelLayout' = 'auto'
    'DolbyDigital' = '1'; 'DolbyDigitalPlus' = '1'; 'TrueHd' = '1'; 'DTS' = '1'; 'DTSHd' = '1'
  }
  $already = ($order -and $names.Count -gt 0 -and $names[0] -eq $dev) -and
             ($devices -and $mine -and $mine -match '"kind":2' -and $mine -match [regex]::Escape('"passthroughCodecs":' + $codecJson)) -and
             (@($want.Keys | Where-Object { (Get-Val $_) -ne $want[$_] }).Count -eq 0)
  if ($already) { return "ok (already $dev)" }

  $before = "audioDevice=$(Get-Val 'player.audioDevice'), first preferred=$(if ($names) { $names[0] } else { 'none' })"
  foreach ($k in $want.Keys) { Write-Val $k $want[$k] }
  Write-QtJson 'player.audioPassthroughCodecs' $codecJson
  Write-QtJson 'QtAudioDevicePreferredOrder' $orderJson
  if ($devicesJson) { Write-QtJson 'QtAudioDevices' $devicesJson }
  Copy-Item $ini "$ini.bak-plexhdr" -Force
  $tmp = "$ini.tmp-plexhdr"
  [IO.File]::WriteAllText($tmp, ($lines -join $nl), (New-Object Text.UTF8Encoding($false)))
  Move-Item $tmp $ini -Force
  "fixed: now $dev ($($eps[0].Name)), HDMI, 5 codecs; was $before$(if (-not $devicesJson) { '; device table left alone (unreadable)' })"
}

# Plex's own player volume starts every title at the value saved in plex.ini (Volume=, 0-1). It was 0.8,
# which made every title Plex decodes ~6 dB quieter than passthrough ones. On the HTPC the player is
# parked at 95 and Plex's volume control drives the Denon instead (plex-avr-volume.lua, avr-volume/), so
# the saved value is set to 0.95 before each start (2026-10-06). Only while Plex is closed.
function Set-PlexStartVolume([string]$Value = '0.95') {
  $ini = Join-Path $env:LOCALAPPDATA 'Plex HTPC\plex.ini'
  if (-not (Test-Path $ini)) { return 'skipped (plex.ini not found)' }
  if (Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue) { return 'skipped (Plex already running)' }
  $text = [IO.File]::ReadAllText($ini)
  $m = [regex]::Match($text, '(?m)^Volume=([0-9.]+)')
  if (-not $m.Success) { return 'skipped (no Volume= line yet)' }
  if ([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) -eq [double]$Value) { return "ok (already $Value)" }
  $new = $text.Substring(0, $m.Groups[1].Index) + $Value + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
  [IO.File]::WriteAllText($ini, $new, (New-Object Text.UTF8Encoding($false)))
  "set to $Value (was $($m.Groups[1].Value))"
}

# Movie profile, while Plex runs: follow Plex's own log and, as each title STARTS, set the Denon's sound mode
# for that title's audio format (AvrAudio.ps1 Get-AvrTitleMode / Set-AvrTitleMode). Plex logs the selected track
# ("(+) Audio ... (truehd 8ch 48000Hz)") and then the output it opened ("AO: [wasapi] 192000Hz 7.1 8ch
# spdif-truehd"); the AO line after a track line is the title start. Nothing is touched DURING a title, so a
# change made on the remote mid-film (compression late at night) stays until the next title. The per-sound-mode
# items (DRC, Cinema EQ, LFE) are set once, at the first title. Replaces the 3-minute Watch-AvrSoundMode for the
# movie profile, which "confirmed" on the Plex menu's 2-ch PCM a minute before the film (2026-10-06).
# Music profile (2026-10-06): same watcher, but 2-ch tracks get Multi Ch Stereo instead of PLII Movie.
function Watch-PlexTitles([System.Diagnostics.Process]$Process, [datetime]$Since, [string]$Profile = 'movie') {
  $log = Join-Path $env:LOCALAPPDATA 'Plex HTPC\logs\Plex HTPC.log'
  $culture = [Globalization.CultureInfo]::InvariantCulture
  $offset = 0L; $partial = ''; $track = $null; $pending = $false; $first = $true
  while (-not $Process.HasExited) {
    Start-Sleep -Seconds 2
    if (-not (Test-Path $log)) { continue }
    $chunk = ''
    try {
      $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite, Delete')
      try {
        if ($fs.Length -lt $offset) { $offset = 0L; $partial = '' }     # Plex started a fresh log file
        [void]$fs.Seek($offset, 'Begin')
        $chunk = (New-Object IO.StreamReader($fs)).ReadToEnd()
        $offset = $fs.Length
      } finally { $fs.Dispose() }
    } catch { continue }
    if (-not $chunk) { continue }
    $lines = @(($partial + $chunk) -split "`n")
    $partial = $lines[-1]
    if ($lines.Count -le 1) { continue }
    foreach ($line in $lines[0..($lines.Count - 2)]) {
      $line = $line.TrimEnd()
      if ($line -notmatch '^([A-Z][a-z]{2} \d{2}, \d{4} \d{2}:\d{2}:\d{2})') { continue }
      if ([datetime]::ParseExact($Matches[1], 'MMM dd, yyyy HH:mm:ss', $culture) -lt $Since) { continue }
      if ($line -match '\(\+\) Audio .*\((\S+) (\d+)ch \d+Hz[^)]*\)$') {
        $track = @{ Codec = $Matches[1]; Ch = [int]$Matches[2] }; $pending = $true; continue
      }
      if ($pending -and $line -match 'AO: \[\w+\] \d+Hz \S+ (\d+)ch (\S+)$') {
        $pending = $false
        $outCh = [int]$Matches[1]; $fmt = $Matches[2]
        $mode = Get-AvrTitleMode -Format $fmt -TrackChannels $track.Ch -OutChannels $outCh
        if ($Profile -eq 'music' -and $mode -eq 'plii') { $mode = 'mchstereo' }
        $desc = "$($track.Codec) $($track.Ch)ch, sent as $fmt $($outCh)ch"
        if (-not $mode) { Log "title: $desc - no rule for it, Denon left alone"; continue }
        Start-Sleep -Seconds 4      # let the Denon lock on to the new signal first
        Log ("title: $desc; " + (Set-AvrTitleMode -Mode $mode))
        if ($first) { $first = $false; Log ("title: per-mode items (first title only): " + (Set-AvrPerModeItems)) }
      }
    }
  }
}

# Hand the post-Plex restore (TV picture mode, HDR off, 1080p, AVR baseline) to a detached background copy of
# this script, so THIS process - the one the launcher launched - exits as soon as Plex does. the launcher pauses its own
# controller handling for its child's lifetime (KTargetExecutor: requestGamepadSuspend), so until 2026-10-06 it
# waited ~17 s after Plex closed for the restore to finish before the pad worked again.
function Start-DetachedRestore([switch]$Display) {
  $argv = @('-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$script:SelfPath`"", '-Mode', 'restore', '-LogFile', "`"$LogFile`"")
  if ($Display) { $argv += '-RestoreDisplay' }
  try {
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argv -WindowStyle Hidden | Out-Null
    Log "restore handed to a background process; launcher exits now so the launcher gets the controller back"
  } catch {
    Log "background restore failed to start ($($_.Exception.Message)) - restoring here instead"
    Invoke-Restore -Display:$Display
  }
}
function Invoke-Restore([switch]$Display) {
  if ($Display) {
    Log ("tv: " + (Set-TvPicture $TvGameMode))
    try { Log ("hdr: " + (Set-Hdr $false)) } catch { Log "hdr off failed: $($_.Exception.Message)" }
    Start-Sleep $SettleSeconds
    try { Log ("mode: " + (Set-Mode $DesktopW $DesktopH $DesktopHz $true $fixedOut)) } catch { Log "mode restore failed: $($_.Exception.Message)" }
    Log "restored: $(Show-Status)"
  }
  if ($script:HaveAvr) {
    if (-not $script:AvrSaved) { $script:AvrSaved = Read-AvrBaseline }
    Exit-AvrProfile
  }
}

# --- The ONE place Plex HTPC is started -----------------------------------------------------------------
# Every launch profile goes through here, so the gamepad fix and the optional -Url hand-off exist once.
function Start-PlexSession([int]$AudioWaitSeconds = 0) {
  if (-not $PlexExe -or -not (Test-Path $PlexExe)) { throw "Plex HTPC not found" }
  try { Log ("plex audio device: " + (Repair-PlexAudioDevice -WaitSeconds $AudioWaitSeconds)) }
  catch { Log "plex audio device: repair failed ($($_.Exception.Message)) - plex.ini left as it was" }
  Log ("plex audio config: " + (Test-PlexAudioConfig))
  try { Log ("plex start volume: " + (Set-PlexStartVolume)) } catch { Log "plex start volume: failed ($($_.Exception.Message))" }
  # Windows speaker layout of the Denon output defaults to 5.1 so games get real surround (speaker-layout/,
  # 2026-10-07). Plex no longer depends on it (its player uses the track's own layout), but a launch is a
  # reliable moment with the receiver on, so re-assert it here - unless a stereo app holds it (Start-StereoApp).
  $spk = Join-Path $PSScriptRoot 'SpeakerLayout.ps1'
  if (Test-Path $spk) {
    try {
      $held = @(Get-ChildItem (Join-Path $PSScriptRoot 'speaker-layout\holds') -Filter '*.hold' -ErrorAction SilentlyContinue | Where-Object { Get-Process -Id ([int]$_.BaseName) -ErrorAction SilentlyContinue })
      if ($held.Count) { Log "speaker layout: left alone ($($held.Count) stereo app(s) running)" }
      else { . $spk; Log ("speaker layout: " + (Set-SpeakerLayout -Layout 5.1)) }
    } catch { Log "speaker layout: failed ($($_.Exception.Message))" }
  }
  # Plex HTPC 1.71 embeds SDL2, whose RawInput joystick backend ENUMERATES a pad but never delivers a
  # single event: its hidden message window gets no pump when SDL is driven from Qt worker threads.
  # Forcing XInput (polling, no window) fixes it. Scoped to this process deliberately - machine-wide
  # would also hit the launcher (SDL3). Write-up: README, "Gamepad in Plex HTPC"
  $env:SDL_JOYSTICK_RAWINPUT = '0'
  $since = (Get-Date).AddSeconds(-2)
  $p = Start-Process -FilePath $PlexExe -PassThru
  Log "plex started pid $($p.Id); $(Show-Status)"
  if ($Url) {
    # plexopen resolves the server and sends playMedia through the PMS Companion proxy. Plex is already
    # running, so plexopen will not cold-start it; pinning PLEX_HTPC_LAUNCH to the bare exe means that
    # even if it decided to, it could not recurse back into this script. -NoFallback: never throw a
    # browser window over the TV on failure.
    $plexopen = Join-Path $PSScriptRoot 'plexopen.ps1'
    if (Test-Path $plexopen) {
      $env:PLEX_HTPC_LAUNCH = $PlexExe
      Log "handing -Url to plexopen: $Url"
      try { & $plexopen -NoFallback $Url *>&1 | ForEach-Object { Log "plexopen: $_" } }
      catch { Log "plexopen failed: $($_.Exception.Message)" }
    } else { Log "plexopen.ps1 not found next to PlexHDR.ps1 - -Url ignored" }
  }
  # Plex is on screen: now the AVR work that was deferred so the launch would not wait on telnet.
  # 0. Collect the background baseline + profile job (it owns the telnet connection until then).
  # 1. Read back the profile (Set-AvrProfile ran with -NoVerify).
  # 2. Watch for the stream: MSMOVIE is a RECALL of the MOVIE button's last choice, so the mode it
  #    produced is only knowable once a title plays; and the per-sound-mode items (DRC, Cinema EQ,
  #    LFE) can only be set once that mode is active. AvrAudio.ps1 points 4 and 5.
  Receive-AvrProfile
  if ($script:HaveAvr -and $script:AvrProfileName -and -not $p.HasExited) {
    try {
      $state = Get-AvrState
      Log ("avr: after launch: " + (Format-AvrState $state))
      [void](Test-AvrSettings -State $state -Settings $script:AvrProfiles[$script:AvrProfileName] -Logger { param($m) Log $m })
      Watch-PlexTitles -Process $p -Since $since -Profile $script:AvrProfileName
    } catch { Log "avr: post-launch check failed ($($_.Exception.Message))" }
  }
  $p.WaitForExit()
  Log "plex exited"
}

switch ($Mode) {
  'status'  { Show-Status }
  'probe'   {
    "before: " + (Show-Status)
    "set 4K60: " + (Set-Mode $MovieW $MovieH $MovieHz); Start-Sleep $SettleSeconds
    "at 4K60: " + (Show-Status)
    "restore: " + (Set-Mode $DesktopW $DesktopH $DesktopHz $false $fixedOut); Start-Sleep $SettleSeconds
    "after: " + (Show-Status)
  }
  'movie'   { "mode: " + (Set-Mode $MovieW $MovieH $MovieHz $true); Start-Sleep $SettleSeconds; "hdr: " + (Set-Hdr $true); Start-Sleep 2; "tv: " + (Set-TvPicture $TvMovieMode); Show-Status }
  'desktop' { "tv: " + (Set-TvPicture $TvGameMode); "hdr: " + (Set-Hdr $false); Start-Sleep $SettleSeconds; "mode: " + (Set-Mode $DesktopW $DesktopH $DesktopHz $true $fixedOut); Start-Sleep 2; Show-Status }
  'plex' {
    Log "launch requested (plex/full); plex='$PlexExe'; url='$Url'; before: $(Show-Status)"
    try {
      # AVR POWER FIRST. It sits in the HDMI chain, so waking it from standby renegotiates HDMI; doing
      # that before the 4K switch means the chain has settled before the mode changes, not mid-switch.
      # When it is already on, the baseline + profile run in the background from here (see
      # Start-AvrProfile) and the display switch and launch do not wait for them.
      Start-AvrProfile 'movie'
      # Mode is saved (persisted) on purpose: toggling HDR makes Windows re-apply the saved configuration,
      # so a temporary mode would be lost. The exit path saves 1080p again.
      Log ("mode: " + (Set-Mode $MovieW $MovieH $MovieHz $true)); Start-Sleep $SettleSeconds
      if ($HdrAtLaunch) { Log ("hdr: " + (Set-Hdr $true)); Start-Sleep 2 }
      Log ("tv: " + (Set-TvPicture $TvMovieMode))
      Start-PlexSession -AudioWaitSeconds 15
    } catch { Log "ERROR: $($_.Exception.Message)" }
    finally {
      # Collect the AVR job (its baseline is on disk), then hand the restore to a background process and exit,
      # so the launcher gets the controller back the moment Plex closes. The restore keeps its order: display FIRST
      # (~5 s, the user is looking at it), then the AVR (telnet nobody is waiting for).
      Receive-AvrProfile
      Start-DetachedRestore -Display
    }
  }
  'restore' {
    # Started by Start-DetachedRestore after Plex exits; not meant to be run by hand.
    Log "restore (background): display=$([bool]$RestoreDisplay)"
    Invoke-Restore -Display:$RestoreDisplay
  }
  'music' {
    # Display and TV deliberately untouched: nothing is gained from 4K/HDR for album art, and skipping
    # the switch avoids the HDMI resync flashes.
    Log "launch requested (music); plex='$PlexExe'; url='$Url'"
    try {
      Start-AvrProfile 'music'
      Start-PlexSession -AudioWaitSeconds 15
    } catch { Log "ERROR: $($_.Exception.Message)" }
    finally { Receive-AvrProfile; Start-DetachedRestore }
  }
  'plain' {
    # No AV changes at all. Exists only so Plex still gets the gamepad fix - launching the exe directly
    # silently loses it, because the fix is an environment variable that must be set before start.
    Log "launch requested (plain - no AV changes); plex='$PlexExe'; url='$Url'"
    try { Start-PlexSession } catch { Log "ERROR: $($_.Exception.Message)" }
  }
}
