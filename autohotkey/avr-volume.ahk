; avr-volume.ahk - the Windows volume keys go to the Denon AVR-S670H instead of Windows.
;
; Steam is the only thing on this box that interprets controller chords. Its stock Guide-button
; chord, Guide + left stick up / down, emits the ordinary VOLUME_UP / VOLUME_DOWN keys. This
; script hooks exactly those keys (plus VOLUME_MUTE) system-wide and sends the matching command
; to the receiver, so the chord moves the AVR and Windows volume is left alone (set to 100 once at start). It reads no
; controller and has no chords of its own: Steam owns chords, the active window owns the rest.
;
; Transport: the AVR's HTTP control endpoint on port 8080 (formiPhoneAppDirect.xml?<cmd>), ~15 ms
; per command, nothing held open - so it never collides with PlexHDR's telnet session, which the
; AVR limits to one client (AvrAudio.ps1). In standby the AVR answers 200 and ignores volume.
;
; Installed to the install folder by install.ps1, started at logon by the AvrVolume task
#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsPerHotkey 1
Persistent
SetWorkingDir A_ScriptDir

; Receiver address from htpc.ini next to this script (install.ps1 writes it from htpc.config.json).
global AvrIp   := IniRead(A_ScriptDir "\htpc.ini", "avr", "ip", "")
global LogFile := A_ScriptDir "\avr-volume.log"

WriteLog(msg) {                           ; not "Log": that name is a built-in function in v2
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`n", LogFile)
}

AvrGet(path) {
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.SetTimeouts(300, 300, 400, 400)   ; resolve, connect, send, receive (ms)
    req.Open("GET", "http://" AvrIp ":8080/goform/" path, false)
    req.Send()
    return req.ResponseText
}

AvrSend(cmd) {                            ; MVUP / MVDOWN = 0.5 dB; Steam repeats the key while the stick is held
    try AvrGet("formiPhoneAppDirect.xml?" cmd)
    catch as e
        WriteLog(cmd " failed: " e.Message)
}

AvrMuteToggle() {
    try {
        status := AvrGet("formMainZone_MainZoneXmlStatusLite.xml")
        muted := InStr(status, "<Mute><value>on</value>")
        AvrGet("formiPhoneAppDirect.xml?" (muted ? "MUOFF" : "MUON"))
    } catch as e
        WriteLog("mute toggle failed: " e.Message)
}

; Windows master volume is set to 100 and unmuted ONCE, at start. After that the keys below are
; swallowed, so nothing ordinary can move it; the script does not police it further (user's call).
PinWindowsVolume() {
    try {
        if (SoundGetVolume() < 99.5)
            SoundSetVolume(100)
        if SoundGetMute()
            SoundSetMute(false)
    } catch as e {
        WriteLog("windows volume pin failed: " e.Message)
    }
}

; No ~ prefix: the keys are swallowed, Windows never sees them.
Volume_Up::
{
    AvrSend("MVUP")
}

Volume_Down::
{
    AvrSend("MVDOWN")
}

Volume_Mute::
{
    AvrMuteToggle()
}

PinWindowsVolume()
WriteLog("started - volume keys -> AVR " AvrIp " over HTTP; windows volume set to 100 once")
