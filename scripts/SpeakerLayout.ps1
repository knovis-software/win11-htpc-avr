# SpeakerLayout.ps1 - set the Windows speaker layout (stereo / 5.1) of the Denon's HDMI output, the same way the
# Sound control panel's "Configure speakers" does. Dot-source it:   . <install folder>\SpeakerLayout.ps1
#
#   Get-DenonOutputs                      # the render endpoints named DENON-AVR, active or not
#   Get-SpeakerLayout                     # the active Denon output's shared-mode channel count + mask
#   Set-SpeakerLayout -Layout 5.1         # or stereo; active Denon output only; returns a one-line summary
#
# Why (2026-10-07): games mix live for whatever Windows says the speakers are. With the Denon output at
# Stereo every game rendered 2 ch and the Denon upmixed it. At 5.1 they render real surround; but Windows
# never upmixes, so stereo-only apps (VacuumTube, StreamGrab's browser) would then play from the front pair
# only, and the Denon cannot apply Pro Logic II to multichannel PCM. So the default is 5.1, and
# Start-StereoApp.ps1 drops to stereo while those apps run. The Denon has no centre speaker (SSSPCCEN NO):
# it blends the centre channel into the fronts itself, so Windows stays plain 5.1 rather than a custom mask.
#
# How: IPolicyConfig (CPolicyConfigClient), the undocumented COM interface mmsys.cpl and every audio-switcher
# use; SetDeviceFormat changes the shared-mode format immediately, no service restart. PhysicalSpeakers and
# FullRangeSpeakers are set too, as the control panel's wizard does. Windows keeps these per endpoint GUID,
# and re-creates the Denon endpoint under new GUIDs now and then, so callers always pick the active one by name.

if (-not ('SpkLayout.Native' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SpkLayout {
  [StructLayout(LayoutKind.Sequential, Pack = 2)]
  public struct WFX {
    public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec; public uint nAvgBytesPerSec;
    public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize;
    public ushort wValidBitsPerSample; public uint dwChannelMask; public Guid SubFormat;
  }
  [StructLayout(LayoutKind.Sequential)] public struct PKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Sequential)] public struct PROPVAR { public ushort vt; public ushort r1, r2, r3; public uint ul; public uint pad; }
  [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPolicyConfig {
    [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr fmt);
    [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int bDefault, out IntPtr fmt);
    [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
    [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFmt, IntPtr mixFmt);
    [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int bDefault, out long def, out long min);
    [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, ref long period);
    [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
    [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
    [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int bFxStore, ref PKEY key, out PROPVAR pv);
    [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int bFxStore, ref PKEY key, ref PROPVAR pv);
  }
  [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class CPolicyConfigClient {}

  public static class Native {
    static IPolicyConfig Pc() { return (IPolicyConfig)new CPolicyConfigClient(); }
    // Current shared-mode device format: channels, mask, rate, container bits, valid bits.
    public static uint[] GetFormat(string id) {
      IntPtr p; int hr = Pc().GetDeviceFormat(id, 0, out p);
      if (hr != 0) throw new Exception("GetDeviceFormat hr=0x" + hr.ToString("x8"));
      WFX f = (WFX)Marshal.PtrToStructure(p, typeof(WFX));
      Marshal.FreeCoTaskMem(p);
      uint mask = f.cbSize >= 22 ? f.dwChannelMask : 0;
      uint valid = f.cbSize >= 22 ? f.wValidBitsPerSample : f.wBitsPerSample;
      return new uint[] { f.nChannels, mask, f.nSamplesPerSec, f.wBitsPerSample, valid, f.wFormatTag };
    }
    static readonly Guid PCM = new Guid("00000001-0000-0010-8000-00aa00389b71");
    static readonly Guid FLOAT = new Guid("00000003-0000-0010-8000-00aa00389b71");
    static WFX Make(ushort channels, uint mask, uint rate, ushort bits, ushort valid, Guid sub) {
      WFX n = new WFX();
      n.wFormatTag = 0xFFFE; n.nChannels = channels; n.nSamplesPerSec = rate; n.wBitsPerSample = bits;
      n.nBlockAlign = (ushort)(channels * bits / 8); n.nAvgBytesPerSec = rate * n.nBlockAlign;
      n.cbSize = 22; n.wValidBitsPerSample = valid; n.dwChannelMask = mask; n.SubFormat = sub;
      return n;
    }
    // The device (endpoint) format is integer PCM; the engine's mix format is always 32-bit float with the
    // same channels and rate. Returns the HRESULT (0 = applied).
    public static int TrySet(string id, ushort channels, uint mask, uint rate, ushort bits, ushort valid) {
      var pc = Pc();
      WFX ep = Make(channels, mask, rate, bits, valid, PCM), mix = Make(channels, mask, rate, 32, 32, FLOAT);
      IntPtr pe = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(WFX))), pm = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(WFX)));
      try {
        Marshal.StructureToPtr(ep, pe, false); Marshal.StructureToPtr(mix, pm, false);
        return pc.SetDeviceFormat(id, pe, pm);
      } finally { Marshal.FreeCoTaskMem(pe); Marshal.FreeCoTaskMem(pm); }
    }
    // Same rate and bit depth as now, new channel count and mask; falls back to 24-in-32 and 16-bit if the
    // driver refuses the current depth at that channel count.
    public static void SetLayout(string id, ushort channels, uint mask) {
      var pc = Pc(); IntPtr cur; int hr = pc.GetDeviceFormat(id, 0, out cur);
      if (hr != 0) throw new Exception("GetDeviceFormat hr=0x" + hr.ToString("x8"));
      WFX f = (WFX)Marshal.PtrToStructure(cur, typeof(WFX)); Marshal.FreeCoTaskMem(cur);
      ushort valid = f.cbSize >= 22 ? f.wValidBitsPerSample : f.wBitsPerSample;
      hr = TrySet(id, channels, mask, f.nSamplesPerSec, f.wBitsPerSample, valid);
      if (hr != 0) hr = TrySet(id, channels, mask, f.nSamplesPerSec, 32, 24);
      if (hr != 0) hr = TrySet(id, channels, mask, f.nSamplesPerSec, 16, 16);
      if (hr != 0) throw new Exception("SetDeviceFormat hr=0x" + hr.ToString("x8"));
      // PhysicalSpeakers / FullRangeSpeakers, as the Configure Speakers wizard writes them.
      Guid spk = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
      SetU4(pc, id, spk, 3, mask);                       // PKEY_AudioEndpoint_PhysicalSpeakers
      SetU4(pc, id, spk, 6, 0x3);                        // PKEY_AudioEndpoint_FullRangeSpeakers: front pair
    }
    static void SetU4(IPolicyConfig pc, string id, Guid fmtid, uint pid, uint value) {
      PKEY k = new PKEY(); k.fmtid = fmtid; k.pid = pid;
      PROPVAR v = new PROPVAR(); v.vt = 19; v.ul = value;   // VT_UI4
      pc.SetPropertyValue(id, 0, ref k, ref v);           // best effort: the format above is what apps read
    }
  }
}
'@
}

$script:SpkLayouts = @{
  'stereo' = @{ Channels = 2; Mask = 0x3 }      # FL FR
  '5.1'    = @{ Channels = 6; Mask = 0x3F }     # FL FR FC LFE BL BR (KSAUDIO_SPEAKER_5POINT1). The AMD HDMI driver
                                                # refuses the side-surround mask 0x60F (hr 0x80070490, probed 2026-10-07);
                                                # over HDMI the Denon plays BL/BR on its surrounds either way.
}

# The receiver's HDMI audio device as Windows names it (htpc.config.json avr.windowsAudioName, default DENON-AVR).
function Get-AvrAudioName {
  if ($script:AvrAudioName) { return $script:AvrAudioName }
  . (Join-Path $PSScriptRoot 'HtpcConfig.ps1')
  $n = (Get-HtpcConfig).avr.windowsAudioName
  if ($n) { $n } else { 'DENON-AVR' }
}
function Get-DenonOutputs {
  $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
  $nameKey = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
  foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
    $name = (Get-ItemProperty "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue).$nameKey
    if ($name -notlike "*$(Get-AvrAudioName)*") { continue }
    $state = [int]((Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DeviceState) -band 0xF
    [pscustomobject]@{ Guid = $k.PSChildName.ToLower(); Id = '{0.0.0.00000000}.' + $k.PSChildName.ToLower(); Active = ($state -eq 1); Name = $name }
  }
}

function Get-SpeakerLayout {
  $a = @(Get-DenonOutputs | Where-Object Active)
  if ($a.Count -ne 1) { return "no single active Denon output ($($a.Count) active)" }
  $f = [SpkLayout.Native]::GetFormat($a[0].Id)
  $name = ($script:SpkLayouts.GetEnumerator() | Where-Object { $_.Value.Channels -eq $f[0] } | Select-Object -First 1).Key
  "$(if ($name) { $name } else { "$($f[0]) ch" }) (mask 0x$('{0:X}' -f $f[1]), $($f[2]) Hz, $($f[4])/$($f[3]) bit) on $($a[0].Guid)"
}

# Applies to EVERY Denon entry, active or not (Windows accepts a format change on an inactive endpoint - verified
# 2026-10-07), so switching the receiver on or off while an app runs cannot leave the other entry on the wrong
# layout. The standby entry (the Denon passing the TV's stereo-only EDID through) refuses 5.1; that is expected
# and reported, not an error. Returns one summary line, e.g. "5.1: f3595288 set (was 2 ch), 54baacdc stereo-only".
function Set-SpeakerLayout {
  param([Parameter(Mandatory)] [ValidateSet('stereo', '5.1')] [string] $Layout)
  $want = $script:SpkLayouts[$Layout]
  $outs = @(Get-DenonOutputs)
  if (-not $outs.Count) { return "${Layout}: no Denon output known to Windows" }
  $parts = foreach ($o in $outs) {
    $tag = $o.Guid.Substring(1, 8) + $(if ($o.Active) { '*' } else { '' })
    try { $before = [SpkLayout.Native]::GetFormat($o.Id) } catch { "$tag unreadable"; continue }
    if ($before[0] -eq $want.Channels -and ($before[1] -eq $want.Mask -or $before[1] -eq 0)) { "$tag already"; continue }
    try { [SpkLayout.Native]::SetLayout($o.Id, [uint16]$want.Channels, [uint32]$want.Mask) }
    catch { "$tag $(if ($Layout -eq '5.1') { 'stereo-only' } else { 'refused' })"; continue }
    $after = [SpkLayout.Native]::GetFormat($o.Id)
    if ($after[0] -ne $want.Channels) { "$tag WARN reads $($after[0]) ch" } else { "$tag set (was $($before[0]) ch)" }
  }
  "${Layout}: " + ($parts -join ', ') + '  (* = active)'
}
