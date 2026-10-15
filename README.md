# win11-htpc-avr

Scripts that make a Windows 11 mini-PC + AV receiver + TV behave like an appliance: the right picture and sound for
each kind of content, one volume, a gamepad that just works, and one button that turns everything on.

Built and tested daily on: Beelink SER5 Pro (Ryzen 7 5850U, Vega 8, HDMI 2.0) · Denon AVR-S670H · Sony A75L OLED ·
Plex HTPC 1.71 · Home Assistant · Xbox / 8BitDo pads. Written with AI assistance (Claude); every piece was tested on
that setup.

## What it fixes

| Problem | Fix (file) |
|---|---|
| Plex HTPC silently stops bitstreaming when Windows re-creates the AVR's audio device (AVR on/standby changes its EDID) | Re-points Plex at the active AVR device before every launch (`PlexHDR.ps1`) |
| Denon "MOVIE" recalls the last mode, so TrueHD can play as Stereo | Sets the decoder per title from Plex's log (`AvrAudio.ps1`) |
| Stereo YouTube/browser audio can't be upmixed while Windows is set to 5.1; games need 5.1 | Switches Windows to stereo only while those apps run (`Start-StereoApp.ps1`, `SpeakerLayout.ps1`) |
| Plex sees the gamepad but gets no input | `SDL_JOYSTICK_RAWINPUT=0` for Plex only, plus a working inputmap (`PlexHDR.ps1`, `plex/xinput.json`) |
| Two volume controls (Windows + AVR) | Windows pinned at 100; a Steam chord and a Plex input mapped to volume step the AVR (`avr-volume.ahk`, `plex-avr-volume.lua`) |
| Desktop vs movie picture | 1080p120 desktop for games/UI, 4K60 for Plex, refresh rate matched per title, TV picture mode per activity (`PlexHDR.ps1`) |
| PAL (25 fps) titles pick a 4:3 mode with Plex resolution switching | Adds 1080p25 to the EDID Windows sees (`edid/edid-override.ps1`) |
| A Wi-Fi-only PC can't be woken by Wake-on-LAN | ESP32-S3 USB "keyboard" that listens on Wi-Fi (`dongle/`) |
| One button for everything | Home Assistant package (`homeassistant/htpc-button.yaml`) + launch keys F13/F14 (`launch-keys.ahk`) |

## What's in it

Mostly PowerShell scripts, plus two AutoHotkey scripts and Home Assistant automations:
- **PowerShell** (`scripts/`, `install.ps1`): the Plex launcher and its movie / music / plain profiles, receiver
  control, stereo/5.1 switching, `plexopen://` links, and the installer.
- **AutoHotkey** (`autohotkey/`): `launch-keys.ahk` turns the wake dongle's F13 / F14 into the Plex movie / music
  launchers; `avr-volume.ahk` sends the Windows volume keys (e.g. from a Steam chord) to the receiver.
- **Home Assistant** (`homeassistant/htpc-button.yaml`): the one-button automations - single, double and long press.
- Also: the wake dongle's firmware (`dongle/`), Plex's gamepad map and volume script (`plex/`), the EDID fix (`edid/`).

## Install

1. Install PowerShell 7, AutoHotkey v2 and Plex HTPC. Enable IP control on the TV and the AVR.
2. Copy `htpc.config.example.json` to `htpc.config.json` and fill it in.
3. Elevated PowerShell 7: `pwsh -File .\install.ps1`.
4. Point your launcher or Start menu at the shortcuts in the install folder: `Plex HTPC 4K HDR`, `Plex HTPC Music`,
   `Plex HTPC Plain`, and one per entry in `stereoApps` (e.g. `YouTube`).
5. Optional: flash `dongle/htpc_wake` (Arduino, AtomS3 Lite), add `homeassistant/htpc-button.yaml`, run `edid/edid-override.ps1`.

## Adapting to your gear

| Your gear | Change |
|---|---|
| Denon / Marantz AVR | Nothing - set its IP and Windows audio name (`2 - DENON-AVR`) in the config |
| Other AVR brand | Replace `AvrAudio.ps1` (sound profiles, per-title mode, power) and the URL in `avr-volume.ahk` / `plex-avr-volume.lua` |
| Sony Bravia | Set its IP and pre-shared key file in the config |
| Other TV | Replace `Invoke-TvVideo` / `Set-TvPicture` in `PlexHDR.ps1`, or leave the TV IP empty to skip picture modes |
| Different display modes | `display` in the config |
| Other button / hub | Anything that can make an HTTP request can call the dongle's `/launch` |

## Extras

- `scripts/fix-bluetooth.ps1` - **Intel AX200 only**: brings the Bluetooth radio back when Windows boots it into
  "Code 10" and every pad vanishes. Run elevated.

## Good to know

- **No VRR/FreeSync** on Vega/HDMI 2.0 mini-PCs even if the TV supports it: cap games at 60 (or 40/30) on the 120 Hz desktop.
- **Dolby Vision**: no Windows player sends real DV to a TV. Profile 7/8 play as HDR10; **profile 5 shows purple/green in
  Plex HTPC** (its FFmpeg never hands the DV metadata to the renderer). Convert p5 files to HDR10
  (`ffmpeg -vf libplacebo=apply_dolbyvision=1:...`) and add a "DV without HDR fallback" custom format at -10000 in
  Radarr/Sonarr.
- **Steam volume chord**: Steam > Settings > Controller > Guide Button Chord Layout: left stick up/down = Volume Up/Down
  keys; `avr-volume.ahk` turns those into AVR steps. Leave Guide unmapped in Plex (Steam owns it).
- **Check passthrough from Plex's log**: `spdif-truehd` / `spdif-dts` = bitstream, `floatp` = decoded.
- **TV boot vs AVR input**: a TV's HDMI-CEC can pull the AVR to "TV Audio" after you chose the PC input; the HA package
  guards that for 30 s.
