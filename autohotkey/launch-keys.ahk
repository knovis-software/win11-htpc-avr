; launch-keys.ahk - F13 / F14 from the wake dongle start the Plex launchers (AutoHotkey v2).
; Home Assistant's family-room button -> dongle GET /launch?action=movie|music&token=... -> the dongle types
; F13 (movie) or F14 (music) as a USB keyboard -> this script opens the SAME shortcut the launcher items use,
; so a launch is defined in exactly one place (the install folder's .lnk -> PlexHDR.ps1).
; Installed to the install folder by install.ps1 and run
; at every logon by the HaLaunchKeys task. F13/F14 exist on no real keyboard here, so nothing else sends them.
#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

LogFile := A_ScriptDir "\launch-keys.log"

F13::Launch("movie", A_ScriptDir "\Plex HTPC 4K HDR.lnk")
F14::Launch("music", A_ScriptDir "\Plex HTPC Music.lnk")

Launch(what, shortcut) {
    ; A second PlexHDR would see its own Plex exit at once and restore the desktop display mode under the
    ; running title, so a press while Plex is up does nothing.
    if ProcessExist("Plex HTPC.exe") {
        WriteLog(what ": Plex HTPC already running - nothing launched")
        return
    }
    try {
        Run('"' shortcut '"')
        WriteLog(what ": opened " shortcut)
    } catch as e {
        WriteLog(what ": FAILED to open " shortcut " - " e.Message)
    }
}

WriteLog(msg) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LogFile)
}
