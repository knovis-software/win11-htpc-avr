-- plex-avr-volume.lua - Plex HTPC's volume control (right stick up/down) drives the Denon AVR-S670H.
--
-- Installed to %LOCALAPPDATA%\Plex HTPC\scripts\ (Plex's mpv loads every script there).
-- OFFICE has no receiver, so its right stick keeps changing Plex's own volume.
-- Log: plex-volume.log in log_dir (see below).
--
-- How Plex's volume behaves (measured on a Windows 11 HTPC, Plex HTPC 1.71, 2026-10-06):
--   * increase/decrease_volume change PLEX'S OWN number in steps of 5, clamped to 0-100, and Plex writes that
--     number to mpv's "volume" property. Plex never reads the property back.
--   * So a script that only resets mpv's volume leaves Plex's number climbing: after one push it sat at 100,
--     every further push hit the clamp, Plex wrote nothing, and the Denon stopped (first version, same day).
--
-- What this script does:
--   * The player plays at 95 (parked at 95.001 - audibly the same - so every Plex write is a visible change).
--   * Each change Plex makes is one Denon step (MVUP / MVDOWN, 0.5 dB, HTTP like the Guide-chord key bridge).
--   * Then it sends Plex the opposite action through Plex's own script interface
--     (script-message-to main plex-ui-action <command>, documented in Plex's scripts\scripting.md), so Plex's
--     number goes back to 95 and never sits at the clamp. Those corrections are counted and do not step the Denon.
--   * Holding the stick: Plex auto-repeats about every 60 ms; a repeat that lands while a correction is still in
--     flight finds Plex at 100 and is dropped by Plex, so a hold steps the Denon at roughly half the repeat rate.
--   * Plex's own volume write as each title loads is ignored (armed only after file-loaded). PlexHDR.ps1 writes
--     Volume=0.95 into plex.ini before each launch, so Plex's number starts at 95 too.
-- curl runs as an mpv subprocess: no console window (mpv adds CREATE_NO_WINDOW when the host has none).

local HOME = 95               -- where Plex's own number is kept
local PARK = 95.001           -- what the player actually plays at
-- Receiver address and log folder: script-opts/plex-avr-volume.conf in Plex HTPC's data folder (written by install.ps1):
--   avr_ip=192.168.1.50
--   log_dir=C:/HTPC
local opts = { avr_ip = '', log_dir = '' }
require('mp.options').read_options(opts, 'plex-avr-volume')
local AVR  = 'http://' .. opts.avr_ip .. ':8080/goform/formiPhoneAppDirect.xml?'
local CURL = 'C:/Windows/System32/curl.exe'
local LOG  = (opts.log_dir ~= '' and opts.log_dir or os.getenv('TEMP')) .. '/plex-volume.log'

local armed = false
local plex_val = HOME         -- Plex's own number, as last written
local pending_up, pending_down = 0, 0     -- corrections sent to Plex, not yet seen
local steps_up, steps_down = 0, 0

local function log(s)
    local f = io.open(LOG, 'a')
    if f then f:write(os.date('%Y-%m-%d %H:%M:%S '), s, '\n'); f:close() end
end

local function avr(cmd)
    mp.command_native_async({
        name = 'subprocess', playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { CURL, '-s', '-m', '2', '-o', 'NUL', AVR .. cmd },
    }, function(ok, res, err)
        if not ok or (res and res.status ~= 0) then
            log(cmd .. ' failed: ' .. tostring(err or (res and res.status)))
        end
    end)
end

local function plex(action)
    mp.commandv('script-message-to', 'main', 'plex-ui-action', action)
end

local function round(x) return math.floor(x + 0.5) end
local function park() mp.set_property_number('volume', PARK) end

local function step(dir)
    avr(dir > 0 and 'MVUP' or 'MVDOWN')
    if dir > 0 then steps_up = steps_up + 1 else steps_down = steps_down + 1 end
end

mp.observe_property('volume', 'number', function(_, v)
    if not v or not armed then return end
    if math.abs(v - PARK) < 1e-6 then return end            -- our own park echoing back
    if math.abs(v - round(v)) > 1e-6 then
        -- A non-whole number means Plex stepped from our parked value (it would have to read mpv back,
        -- which this Plex does not do). Kept as a fallback: direction from the park.
        step(v > PARK and 1 or -1)
        park()
        return
    end
    local delta = v - plex_val
    plex_val = v
    if delta < 0 and pending_down > 0 then
        pending_down = pending_down - 1                      -- our own correction arriving
    elseif delta > 0 and pending_up > 0 then
        pending_up = pending_up - 1
    elseif delta ~= 0 then
        local dir = delta > 0 and 1 or -1                    -- the viewer pushed the stick
        step(dir)
        if dir > 0 then plex('decrease_volume'); pending_down = pending_down + 1
        else plex('increase_volume'); pending_up = pending_up + 1 end
    end
    park()
end)

-- CHANNEL COUNT (2026-10-07). Plex's "Channels: Auto" sets mpv's audio-channels to "auto-safe", which follows
-- Windows' speaker setup for the output - Stereo for the Denon endpoints - so a 5.1 AAC track was folded to
-- 2 ch and the Denon upmixed it with PLII (Minions & Monsters). "auto" uses the track's own layout whenever
-- the device accepts it (mpv's exclusive-mode probe of the Denon: 5.1 and 7.1 s32 OK), so 5.1 stays 5.1 and
-- stereo stays stereo for PLII. Windows' speaker setup stays Stereo on purpose: set to 5.1, auto-safe would
-- pad every stereo track into six channels with four silent, and PLII would never engage.
mp.observe_property('audio-channels', 'string', function(_, v)
    if v == 'auto-safe' then
        mp.set_property('audio-channels', 'auto')
        log('channels: Plex chose auto-safe (follows Windows stereo); set auto (the track\'s own layout)')
    end
end)

mp.register_event('start-file', function() armed = false end)

mp.register_event('file-loaded', function()
    local v = mp.get_property_number('volume')
    if v then plex_val = round(v) end
    pending_up, pending_down = 0, 0
    park()
    mp.add_timeout(0.5, function()
        armed = true
        -- If Plex's own number starts away from HOME (plex.ini edited by hand, OFFICE copy...), walk it there
        -- once, as counted corrections, so it never sits at a clamp.
        local n = round((plex_val - HOME) / 5)
        for _ = 1, math.abs(n) do
            if n > 0 then plex('decrease_volume'); pending_down = pending_down + 1
            else plex('increase_volume'); pending_up = pending_up + 1 end
        end
    end)
    log('title loaded: Plex had set ' .. tostring(v) .. '; player parked at 95')
end)

mp.register_event('end-file', function()
    if steps_up + steps_down > 0 then log(('title ended: Denon stepped up %d, down %d'):format(steps_up, steps_down)) end
    steps_up, steps_down = 0, 0
end)

log('loaded')
