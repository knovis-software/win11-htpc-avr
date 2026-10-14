# AvrAudio.ps1 — set the Denon AVR-S670H to a listening profile over its telnet
# control protocol. Dot-sourced by PlexHDR.ps1; can also be used standalone.
#
#   . .\AvrAudio.ps1
#   $saved = Get-AvrState                     # read-only snapshot (every field below)
#   Set-AvrProfile -Profile movie             # or music
#   Restore-AvrState -State $saved            # put the listening settings back
#
# Protocol: plain TCP on port 23, ASCII commands terminated with CR. A query is
# the command plus "?" and the AVR answers with its current value. Verified
# against an AVR-S670H on 2026-09-10 (Denon/Marantz share this telnet protocol). The AVR answers queries
# even in standby. No Denon protocol document names the S670H; the commands
# come from the FY23 chart (X2800H family) and the AVR-1713 doc (the PLII-era
# one that defines PSMODE:), and are trusted only where this unit has answered.
# Sources and the manual pages behind every value: ../av-settings-audit.md.
#
# THINGS THAT WILL BITE:
#  1. The AVR accepts ONE telnet connection at a time and holds it. Always close
#     the socket. If a connection is left open, later attempts hang.
#  2. Sound mode is per-input-signal-type and cannot be set while the unit is in
#     standby. Power on and let it settle first, and always READ BACK — asking
#     for a mode is not the same as getting it.
#  3. An MS reply is NOT always a valid set command. Pro Logic II's flavour
#     (Movie / Music / Game) lives in a separate PSMODE: setting. Verified on the
#     unit 2026-09-10: "PSMODE:MUSIC" selects PLII Music from ANY mode (it even
#     pulls the AVR out of Multi Ch Stereo), whereas sending "MSDOLBY PLII MS",
#     "MSMUSIC" or "MSDOLBY PLII" changes nothing. The MS line only REPORTS it.
#  4. MSMOVIE is a RECALL, not a choice. The manual (p.102): the MOVIE button
#     "memorizes the last sound mode selected for its button" and only falls
#     back to "the most appropriate sound mode" when that one is unsupported.
#     Its candidates include Multi Ch Stereo and Mono Movie for every signal, so
#     a mode someone once picked by hand is what MSMOVIE brings back. That is why
#     Watch-AvrSoundMode reads the mode back once a stream is playing.
#  5. Surround Parameter items (DRC, Loudness Management, Cinema EQ, LFE, the
#     PLII parameters) are stored PER SOUND MODE and some "cannot be set while
#     playback is stopped" (manual p.128) — sending them at launch, before a
#     bitstream exists, may do nothing. They are re-sent from Watch-AvrSoundMode
#     once a decoder mode is confirmed. Audyssey items, Tone, Restorer and
#     Dialog Enhancer are stored PER INPUT (p.136, p.98, p.134, p.96).
#
# The IP is pinned here. If the AVR's DHCP lease ever moves, every call fails
# soft ("unreachable - skipping") and Plex still launches without the profile —
# so give the AVR a router DHCP reservation rather than trusting the lease.

# Receiver address from htpc.config.json ("avr": { "ip" }) in this folder.
. (Join-Path $PSScriptRoot 'HtpcConfig.ps1')
$script:AvrIp           = "$((Get-HtpcConfig).avr.ip)"
$script:AvrBaselineFile = Join-Path $PSScriptRoot 'avr-baseline.json'   # see Save-AvrBaseline

# Every field this module reads, sets or restores: query, and the prefix of the
# reply line that answers it. ORDER MATTERS for Restore-AvrState (see there).
$script:AvrFields = @(
    @{ Name = 'Power';       Query = 'PW?';            Prefix = 'PW' }
    @{ Name = 'Input';       Query = 'SI?';            Prefix = 'SI' }
    @{ Name = 'Volume';      Query = 'MV?';            Prefix = 'MV' }
    @{ Name = 'PlMode';      Query = 'PSMODE: ?';      Prefix = 'PSMODE:' }      # PLII flavour, kept while other modes are active
    @{ Name = 'Surround';    Query = 'MS?';            Prefix = 'MS' }
    @{ Name = 'MultEq';      Query = 'PSMULTEQ: ?';    Prefix = 'PSMULTEQ:' }
    @{ Name = 'DynamicEq';   Query = 'PSDYNEQ ?';      Prefix = 'PSDYNEQ' }
    @{ Name = 'RefLevel';    Query = 'PSREFLEV ?';     Prefix = 'PSREFLEV' }     # Dynamic EQ reference level offset, per input
    @{ Name = 'DynamicVol';  Query = 'PSDYNVOL ?';     Prefix = 'PSDYNVOL' }
    @{ Name = 'Drc';         Query = 'PSDRC ?';        Prefix = 'PSDRC' }        # per sound mode
    @{ Name = 'Lom';         Query = 'PSLOM ?';        Prefix = 'PSLOM' }        # Loudness Management (TrueHD dialnorm + DRC enable)
    @{ Name = 'CinemaEq';    Query = 'PSCINEMA EQ. ?'; Prefix = 'PSCINEMA EQ.' } # per sound mode
    @{ Name = 'Tone';        Query = 'PSTONE CTRL ?';  Prefix = 'PSTONE CTRL' }  # per input; locked while Dynamic EQ is on
    @{ Name = 'Lfe';         Query = 'PSLFE ?';        Prefix = 'PSLFE' }        # per sound mode
    @{ Name = 'DialogEnh';   Query = 'PSDEH ?';        Prefix = 'PSDEH' }        # per input
    @{ Name = 'Restorer';    Query = 'PSRSTR ?';       Prefix = 'PSRSTR' }       # per input; PCM 44.1/48 only — the music signal
    @{ Name = 'GraphicEq';   Query = 'PSGEQ ?';        Prefix = 'PSGEQ' }
    @{ Name = 'Panorama';    Query = 'PSPAN ?';        Prefix = 'PSPAN' }        # PLII Music parameters, stored under that mode
    @{ Name = 'Dimension';   Query = 'PSDIM ?';        Prefix = 'PSDIM' }
    @{ Name = 'CenterWidth'; Query = 'PSCEN ?';        Prefix = 'PSCEN' }
    @{ Name = 'Signal';      Query = 'SSINFAISSIG ?';  Prefix = 'SSINFAISSIG' }  # input signal type code (logged, not interpreted)
)

# ---------------------------------------------------------------------------
# Low-level: send commands / queries on one connection, return the raw replies.
# ---------------------------------------------------------------------------
function Invoke-AvrCommand {
    param(
        [string[]] $Commands,
        [string]   $Ip        = $script:AvrIp,
        [int]      $SettleMs  = 700,   # the AVR is slow; below ~500 QUERY replies get lost
        [int]      $TimeoutMs = 3000
    )
    $client = New-Object Net.Sockets.TcpClient
    $replies = @()
    try {
        if (-not $client.ConnectAsync($Ip, 23).Wait($TimeoutMs)) {
            throw "AVR at $Ip did not accept a telnet connection (asleep, or another client holds it)"
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1500
        foreach ($cmd in $Commands) {
            $bytes = [Text.Encoding]::ASCII.GetBytes($cmd + "`r")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            Start-Sleep -Milliseconds $SettleMs
            $buffer = New-Object byte[] 4096
            $text = ''
            try {
                while ($stream.DataAvailable) {
                    $n = $stream.Read($buffer, 0, $buffer.Length)
                    $text += [Text.Encoding]::ASCII.GetString($buffer, 0, $n)
                }
            } catch { }
            # The AVR volunteers unrelated status lines; keep them all, split on CR.
            $replies += ,@($cmd, (($text -split "`r") | Where-Object { $_.Trim() }))
        }
    } finally {
        $client.Close(); $client.Dispose()
    }
    # The comma matters (fixed 2026-10-06): without it PowerShell unrolls a ONE-element result,
    # so a single query (Get-AvrState -Fields Power) came back as ('PW?', 'PWON') instead of a
    # list holding that pair, Get-AvrState picked character [1] of each and read Power as empty.
    # Every launch since 2026-09-14 therefore logged "in standby ()" and took the slow serial
    # path, and the exit restore's power check was unreliable the same way.
    return ,$replies
}

# ---------------------------------------------------------------------------
# Read-only state, as a flat object with one property per $AvrFields entry.
# Safe to call any time, including standby. A field the unit does not answer
# (a feature this model lacks, or a query it ignores) is $null, and every
# consumer below treats $null as "unknown", never as a mismatch.
# ~15 s: 21 queries at 700 ms. Pass -Fields to read a subset.
# ---------------------------------------------------------------------------
function Get-AvrState {
    param(
        [string]   $Ip     = $script:AvrIp,
        [string[]] $Fields = @()        # names from $AvrFields; empty = all
    )
    $wanted = if ($Fields.Count) { $script:AvrFields | Where-Object { $Fields -contains $_.Name } } else { $script:AvrFields }
    $r = Invoke-AvrCommand -Ip $Ip -Commands @($wanted | ForEach-Object { $_.Query })
    $all = $r | ForEach-Object { $_[1] }
    $state = [ordered]@{}
    foreach ($f in $wanted) {
        $prefix = $f.Prefix
        $state[$f.Name] = ($all | Where-Object { $_ -like "$prefix*" } | Select-Object -First 1)
    }
    [pscustomobject]$state
}

function Format-AvrState($State) {
    "{0} | {1} | {2} | {3} | ref {4} | {5} | {6} | {7}" -f $State.Surround, $State.PlMode, $State.MultEq,
        $State.DynamicEq, $State.RefLevel, $State.DynamicVol, $State.Drc, $State.Input
}

# ---------------------------------------------------------------------------
# The profiles. Every value is from the AVR-S670H manual unless marked; page
# numbers and the reasoning are in ../av-settings-audit.md §2 and §5.
#
# Both profiles assert the FULL neutral set rather than inheriting it, so a
# stray menu change on the remote can never ride along under a profile:
#   Audyssey MultEQ Reference — "We recommend the 'Reference' setting" (p.136).
#     Flat is NOT a music curve: the manual defines it as "optimized for small
#     rooms where your listening position is closer to the speakers". Music ran
#     on Flat from 2026-09-10 to 2026-09-13 on a mistaken X-curve rationale.
#   Dynamic EQ ON — loudness compensation the manual recommends "when using the
#     unit with the volume turned down" (p.159). Reference is 0 dB = display 80
#     on the 0-98 scale (p.135, p.137); normal listening here is 18-55 dB below.
#   Reference Level Offset — live whenever Dynamic EQ is on and stored per
#     input (p.137): 0 dB "movies"; 10 dB "jazz ... also TV content, usually
#     mixed at 10 dB below film reference"; 15 dB pop/rock; 5 dB classical.
#     movie = 0, music = 10 (a mixed library; 15 if it is mostly pop/rock).
#   Dynamic Volume OFF — the Audyssey leveller; never wanted for either use.
#   Dynamic Compression OFF — the decoder's own compressor; exists only while a
#     Dolby/DTS bitstream plays (p.129), so see point 5 at the top.
#   Loudness Management ON — the default; OFF would also drop TrueHD dialnorm.
#   Cinema EQ OFF, Tone OFF, LFE 0 dB, Dialog Enhancer OFF, Restorer OFF,
#   Graphic EQ OFF — the manual's defaults, all "no processing".
#
# Sound mode:
#   movie -> PSMODE:CINEMA (so a 2-ch Dolby source upmixes with PLII Movie, not
#            with whatever flavour the last music session left) then MSMOVIE,
#            which RECALLS the MOVIE button's last choice (point 4). The signal
#            defaults (p.228) are what we want — DD -> Dolby Digital, DTS -> DTS
#            Surround, 2-ch -> PLII / Neo:6 — and Watch-AvrSoundMode confirms it.
#   music -> SINCE 2026-10-06: MSMCH STEREO (Multi Ch Stereo, every speaker plays the
#            stereo mix; the user's call - fuller than the steered upmix below).
#            Until then: PSMODE:MUSIC, i.e. Pro Logic II Music (the AVR then REPORTS it as
#            "MSDOLBY PLII MS" - point 3; that string cannot set it). A real
#            upmixer: it steers only the ambience to the surrounds and keeps the
#            front stereo image intact. Chosen over MSMCH STEREO (Multi Channel
#            Stereo), which copies the same signal to every speaker and
#            collapses the image. PLII Music parameters at the manual's
#            defaults (p.131): Panorama off, Dimension 3, Center Width 3.
# ---------------------------------------------------------------------------
$script:AvrProfiles = @{
    movie = [ordered]@{
        PlMode      = 'PSMODE:CINEMA'
        Surround    = 'MSMOVIE'
        MultEq      = 'PSMULTEQ:AUDYSSEY'
        DynamicEq   = 'PSDYNEQ ON'
        RefLevel    = 'PSREFLEV 0'
        DynamicVol  = 'PSDYNVOL OFF'
        Drc         = 'PSDRC OFF'
        Lom         = 'PSLOM ON'
        CinemaEq    = 'PSCINEMA EQ.OFF'
        Tone        = 'PSTONE CTRL OFF'
        Lfe         = 'PSLFE 00'
        DialogEnh   = 'PSDEH OFF'
        Restorer    = 'PSRSTR OFF'
        GraphicEq   = 'PSGEQ OFF'
    }
    # music = Multi Ch Stereo since 2026-10-06 (user: all speakers playing is the better music experience);
    # it was Pro Logic II Music from 2026-09-10, which steers mostly ambience to the surrounds.
    music = [ordered]@{
        Surround    = 'MSMCH STEREO'
        MultEq      = 'PSMULTEQ:AUDYSSEY'
        DynamicEq   = 'PSDYNEQ ON'
        RefLevel    = 'PSREFLEV 10'
        DynamicVol  = 'PSDYNVOL OFF'
        Drc         = 'PSDRC OFF'
        Lom         = 'PSLOM ON'
        CinemaEq    = 'PSCINEMA EQ.OFF'
        Tone        = 'PSTONE CTRL OFF'
        Lfe         = 'PSLFE 00'
        DialogEnh   = 'PSDEH OFF'
        Restorer    = 'PSRSTR OFF'
        GraphicEq   = 'PSGEQ OFF'
    }
}

# Sound modes MSMOVIE may legitimately land on (native decoders, the PLII / Neo:6
# movie upmixers, plain stereo for PCM) versus the ones that mean a stray manual
# choice is being recalled (point 4). Prefix matches against the MS reply.
$script:AvrMovieModeBad = @('MSMCH STEREO', 'MSMONO MOVIE', 'MSROCK ARENA', 'MSJAZZ CLUB', 'MSMATRIX',
                            'MSVIDEO GAME', 'MSVIRTUAL', 'MSWIDE SCREEN', 'MSSUPER STADIUM',
                            'MSDOLBY PLII MS', 'MSDOLBY PLII GM', 'MSDTS NEO:6 M')
# Per-sound-mode items re-asserted once a decoder mode is confirmed (point 5).
$script:AvrPerModeFields = @('Drc', 'CinemaEq', 'Lfe')

# Compare a read-back against a profile. $null on the unit = unknown, not a
# mismatch (the model lacks the feature or ignored the query). Surround is
# never compared here: it resolves against the live signal (Watch-AvrSoundMode).
function Test-AvrSettings {
    param($State, $Settings, [scriptblock] $Logger, [string[]] $Skip = @('Surround'))
    $ok = $true; $unknown = @()
    foreach ($name in $Settings.Keys) {
        if ($Skip -contains $name) { continue }
        $have = $State.$name
        if (-not $have) { $unknown += $name; continue }
        if ($have -notlike "$($Settings[$name])*") {
            & $Logger "avr: WARN $name is '$have', wanted '$($Settings[$name])'"
            $ok = $false
        }
    }
    if ($unknown) { & $Logger ("avr: not answered by this unit (left as is): " + ($unknown -join ', ')) }
    return $ok
}

# ---------------------------------------------------------------------------
# SEND ONLY WHAT DIFFERS (2026-10-06). Until then every launch sent the whole
# profile (14-16 commands) and every exit the whole baseline (~17), although the
# read-backs showed for weeks that the unit already held all of it: the neutral
# items are stored per input / per sound mode (point 5) and the HTPC is the only
# source on its input. The redundant ones were not harmless to look at - each
# command the unit cannot apply in its current state flashes "not available" on
# the TV: Tone while Dynamic EQ is on (manual p.98), DRC / Cinema EQ / LFE while
# playback is stopped (p.128), Restorer without a 44.1/48 kHz PCM signal (p.134).
# Now: compare with a read of the unit and send only mismatches, in profile
# order. A field the unit does not answer ($null) is unknown and left alone, as
# Test-AvrSettings already treats it. -Always names fields sent regardless (the
# MSMOVIE recall: its target is a button, not a value a read can match).
# Tone is skipped whenever the target has Dynamic EQ on: it is locked then
# (p.98), so sending it can only produce the message.
# ---------------------------------------------------------------------------
function Get-AvrDelta {
    param($Current, $Target, [string[]] $Always = @(), [string[]] $Skip = @())
    foreach ($name in $Target.Keys) {
        if ($Skip -contains $name) { continue }
        $want = $Target[$name]
        if (-not $want) { continue }
        if ($Always -contains $name) { [pscustomobject]@{ Name = $name; Cmd = $want; Have = 'always sent' }; continue }
        $have = $Current.$name
        if (-not $have) { continue }
        if ($have -like "$want*") { continue }
        [pscustomobject]@{ Name = $name; Cmd = $want; Have = $have }
    }
}
# Dot access works on both a profile (ordered dictionary) and a saved state (object).
function Get-AvrToneSkip($Target) { if ("$($Target.DynamicEq)" -like 'PSDYNEQ ON*') { @('Tone') } else { @() } }
function Format-AvrDelta($Delta) { ($Delta | ForEach-Object { if ($_.Have -eq 'always sent') { $_.Cmd } else { "$($_.Cmd) (was $($_.Have))" } }) -join ' ; ' }

function Set-AvrProfile {
    [CmdletBinding()]
    param(
        # Named $ProfileName, not $Profile: $PROFILE is a PowerShell automatic
        # variable and a parameter of that name silently shadows it. The alias
        # keeps the natural call form: Set-AvrProfile -Profile movie.
        [Parameter(Mandatory)] [Alias('Profile')] [ValidateSet('movie','music')] [string] $ProfileName,
        [string] $Ip           = $script:AvrIp,
        [switch] $NoPowerOn,                 # skip waking the AVR if it is in standby
        [int]    $PowerOnWaitS = 6,          # HDMI/DSP settle after PWON before modes take
        [switch] $NoVerify,                  # skip the ~15 s read-back (PlexHDR verifies later, after Plex is up)
        $Current = $null,                    # a Get-AvrState read of the unit as it is NOW; read here if absent
        [scriptblock] $Logger  = { param($m) Write-Host $m }
    )
    function say($m) { & $Logger "avr: $m" }

    $settings = $script:AvrProfiles[$ProfileName]
    if (-not $settings) { say "unknown profile '$ProfileName'"; return $false }

    try {
        $power = (Get-AvrState -Ip $Ip -Fields Power).Power
    } catch {
        say "unreachable ($($_.Exception.Message)) - skipping audio setup"
        return $false
    }

    # Modes are ignored in standby, so wake it unless told not to.
    if ($power -notlike 'PWON*') {
        if ($NoPowerOn) { say "in standby and -NoPowerOn given - skipping"; return $false }
        say "powering on (was $power)"
        Invoke-AvrCommand -Ip $Ip -Commands @('PWON') | Out-Null
        Start-Sleep -Seconds $PowerOnWaitS
    }

    # Stored values survive standby, so a read taken before a power-on still describes the unit.
    if (-not $Current) { $Current = Get-AvrState -Ip $Ip -Fields @($settings.Keys | Where-Object { $_ -ne 'Surround' }) }
    $skip = Get-AvrToneSkip $settings
    $delta = @(Get-AvrDelta -Current $Current -Target $settings -Always @('Surround') -Skip $skip)
    $unknown = @($settings.Keys | Where-Object { $_ -ne 'Surround' -and $skip -notcontains $_ -and -not $Current.$_ })
    $note = $(if ($skip) { '; Tone not sent (locked while Dynamic EQ is on)' }) + $(if ($unknown) { "; not answered, left alone: $($unknown -join ', ')" })
    if ($delta.Count) {
        say ("applying '$ProfileName', only what differs ($($delta.Count) of $($settings.Count)): " + (Format-AvrDelta $delta) + $note)
        # Set commands need no reply parsed, so a shorter gap than a query's.
        Invoke-AvrCommand -Ip $Ip -Commands @($delta.Cmd) -SettleMs 300 | Out-Null
    } else {
        say "'$ProfileName' already set - nothing sent$note"
    }
    if ($NoVerify) { return $true }

    Start-Sleep -Milliseconds 500
    $after = Get-AvrState -Ip $Ip
    say ("now: " + (Format-AvrState $after))
    return (Test-AvrSettings -State $after -Settings $settings -Logger $Logger)
}

# ---------------------------------------------------------------------------
# PER-TITLE SOUND MODE for the movie profile (2026-10-06). MSMOVIE recalls the
# MOVIE button's memory, and on this unit that memory held Stereo for Dolby
# TrueHD (Ghost Protocol, 2026-10-06: a TrueHD 7.1 bitstream played as Stereo).
# So the launcher no longer trusts the recall: when a title starts it knows the
# exact format from Plex's log, and sets the mode this format should get. The
# Denon memorises a mode chosen while a signal plays, so after the first fix per
# format the recall is usually right and this only confirms it.
#   Dolby bitstream (AC-3, E-AC-3, TrueHD), 3+ ch -> native Dolby decoder
#   DTS bitstream (DTS, DTS-HD),          3+ ch -> native DTS decoder
#   PCM from Plex (decoded AAC/Opus...),  3+ ch -> Multi Ch In (native for PCM)
#   anything 2-ch or mono                       -> Dolby Pro Logic II Movie
# Set commands from the Denon FY23 protocol (MSDOLBY DIGITAL, MSDTS SURROUND,
# MSMULTI CH IN); PLII Movie is selected with PSMODE:CINEMA (point 3). Ok lists
# the MS replies that count as right; the first live replies get logged, so an
# unexpected native-mode name shows up in PlexHDR.log as a WARN, not silently.
# ---------------------------------------------------------------------------
$script:AvrTitleModes = @{
    dolby   = @{ Label = 'native Dolby';        Cmd = 'MSDOLBY DIGITAL'; Ok = @('MSDOLBY DIGITAL', 'MSDOLBY D+', 'MSDOLBY D EX', 'MSDOLBY TRUEHD', 'MSDOLBY HD', 'MSDOLBY AUDIO') }
    dts     = @{ Label = 'native DTS';          Cmd = 'MSDTS SURROUND';  Ok = @('MSDTS SURROUND', 'MSDTS-HD', 'MSDTS HD', 'MSDTS ES', 'MSDTS96', 'MSDTS EXPRESS') }
    multich = @{ Label = 'Multi Ch In';         Cmd = 'MSMULTI CH IN';   Ok = @('MSMULTI CH IN') }
    plii    = @{ Label = 'Pro Logic II Movie';  Cmd = 'PSMODE:CINEMA';   Ok = @('MSDOLBY PLII MV') }
    mchstereo = @{ Label = 'Multi Ch Stereo';   Cmd = 'MSMCH STEREO';    Ok = @('MSMCH STEREO') }   # music profile, 2-ch
}
# Pure: which mode a title should get. $Format is mpv's AO format (spdif-truehd, s32, float...),
# $TrackChannels the source track's channel count, $OutChannels what the AO actually sends.
function Get-AvrTitleMode {
    param([string] $Format, [int] $TrackChannels, [int] $OutChannels)
    if ($Format -like 'spdif-*') {
        if ($TrackChannels -gt 0 -and $TrackChannels -lt 3) { return 'plii' }
        $codec = $Format.Substring(6)
        if ($codec -in 'ac3', 'eac3', 'truehd') { return 'dolby' }
        if ($codec -like 'dts*') { return 'dts' }
        return $null
    }
    if ($OutChannels -ge 3) { return 'multich' }
    if ($OutChannels -ge 1) { return 'plii' }
    return $null
}
# The per-sound-mode items (DRC, Cinema EQ, LFE) for the movie profile, sent only where they differ.
# Called ONCE per launch, at the first title: whatever is changed on the remote later in the session
# (compression late at night) is left alone. Returns a summary. Never throws.
function Set-AvrPerModeItems {
    param([string] $Ip = $script:AvrIp)
    try {
        $sub = [ordered]@{}; foreach ($f in $script:AvrPerModeFields) { $sub[$f] = $script:AvrProfiles.movie[$f] }
        $have = Get-AvrState -Ip $Ip -Fields $script:AvrPerModeFields
        $delta = @(Get-AvrDelta -Current $have -Target $sub)
        if (-not $delta.Count) { return 'already right - nothing sent' }
        Invoke-AvrCommand -Ip $Ip -Commands @($delta.Cmd) -SettleMs 300 | Out-Null
        return 'set: ' + (Format-AvrDelta $delta)
    } catch { return "failed ($($_.Exception.Message))" }
}

# Read the mode once the signal is there, fix it if it is not the one this format should get,
# read back. Returns a one-line summary for the log. Never throws.
function Set-AvrTitleMode {
    param([Parameter(Mandatory)] [string] $Mode, [string] $Ip = $script:AvrIp)
    $want = $script:AvrTitleModes[$Mode]
    try {
        $s = Get-AvrState -Ip $Ip -Fields Surround, Signal
        $have = [string]$s.Surround
        $isOk = { param($m) [bool]($want.Ok | Where-Object { $m -like "$_*" }) }
        if (& $isOk $have) { return "wants $($want.Label); Denon already $have (signal $($s.Signal))" }
        Invoke-AvrCommand -Ip $Ip -Commands @($want.Cmd) -SettleMs 300 | Out-Null
        Start-Sleep -Milliseconds 1500
        $now = [string](Get-AvrState -Ip $Ip -Fields Surround, Signal).Surround
        if (& $isOk $now) { return "wants $($want.Label); Denon was $have -> sent $($want.Cmd) -> now $now" }
        return "WARN wants $($want.Label); Denon was $have -> sent $($want.Cmd) -> still $now (unexpected reply name? see AvrTitleModes)"
    } catch { return "WARN title mode check failed ($($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------
# After Plex is up: confirm the sound mode that MSMOVIE / PSMODE:MUSIC actually
# produced once a stream is playing (point 4), and re-assert the per-sound-mode
# neutral items for that mode (point 5). Polls while the process lives, up to
# TimeoutS. Never throws.
#   movie: any native decoder / PLII Movie / Neo:6 Cinema / Stereo = fine; a
#          mode in $AvrMovieModeBad = WARN (someone picked it under MOVIE once;
#          fix it once on the remote and MSMOVIE recalls the right one after).
#   music: MSDOLBY PLII MS = confirmed; anything else after the timeout = WARN.
# ---------------------------------------------------------------------------
function Watch-AvrSoundMode {
    param(
        [Parameter(Mandatory)] [ValidateSet('movie','music')] [string] $ProfileName,
        [System.Diagnostics.Process] $Process = $null,   # stop early when it exits
        [int] $TimeoutS  = 180,
        [int] $IntervalS = 15,
        [string] $Ip = $script:AvrIp,
        [scriptblock] $Logger = { param($m) Write-Host $m }
    )
    function say($m) { & $Logger "avr: $m" }
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    $last = ''
    $resent = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $IntervalS
        if ($Process -and $Process.HasExited) { return }
        try { $s = Get-AvrState -Ip $Ip -Fields Surround, Signal } catch { say "watch: unreachable ($($_.Exception.Message))"; return }
        $mode = [string]$s.Surround
        if ($mode -ne $last) { say ("playing: {0} (signal {1})" -f $mode, $s.Signal); $last = $mode }
        if (-not $mode) { continue }

        if ($ProfileName -eq 'music') {
            if ($mode -like 'MSDOLBY PLII MS*') { say "music mode confirmed"; return }
            # PSMODE:MUSIC sent at launch, before any signal, only sets the PLII flavour
            # memory; the mode the unit actually enters when 2-ch PCM arrives is its
            # per-signal memory under the MUSIC button, which was DTS Neo:6 Music on
            # 2026-09-13. Sent again WITH the signal present it switches to PLII
            # Music (verified live that day: MSDTS NEO:6 M -> MSDOLBY PLII MS). Once.
            if (-not $resent) {
                say "not PLII Music yet ($mode) - re-sending PSMODE:MUSIC with the signal present"
                Invoke-AvrCommand -Ip $Ip -Commands @('PSMODE:MUSIC') -SettleMs 300 | Out-Null
                $resent = $true
            }
            continue
        }
        # movie
        foreach ($bad in $script:AvrMovieModeBad) {
            if ($mode -like "$bad*") {
                say "WARN MSMOVIE recalled '$mode' - a mode picked by hand under the MOVIE button. Fix once: play a title, press MOVIE, choose the native decoder (or Dolby PLII Movie for stereo)."
                return
            }
        }
        if ($mode -like 'MSSTEREO*') { continue }   # PCM / idle - keep waiting for the stream
        # A decoder or upmixer mode: per-sound-mode items can be set now - but only the ones
        # this mode does not already hold (each needless one flashes on the TV).
        $sub = [ordered]@{}; foreach ($f in $script:AvrPerModeFields) { $sub[$f] = $script:AvrProfiles.movie[$f] }
        $have = Get-AvrState -Ip $Ip -Fields $script:AvrPerModeFields
        $delta = @(Get-AvrDelta -Current $have -Target $sub)
        if ($delta.Count) {
            Invoke-AvrCommand -Ip $Ip -Commands @($delta.Cmd) -SettleMs 300 | Out-Null
            $chk = Get-AvrState -Ip $Ip -Fields $script:AvrPerModeFields
            [void](Test-AvrSettings -State $chk -Settings $sub -Logger $Logger -Skip @())
            say "movie mode confirmed: $mode; per-mode items set: $(Format-AvrDelta $delta)"
        } else {
            [void](Test-AvrSettings -State $have -Settings $sub -Logger $Logger -Skip @())
            say "movie mode confirmed: $mode; per-mode items already right - nothing sent"
        }
        return
    }
    if ($ProfileName -eq 'music') { say "WARN no Pro Logic II Music within ${TimeoutS}s (last: '$last')" }
    else                          { say "no bitstream seen within ${TimeoutS}s (last: '$last') - per-mode items not re-asserted" }
}

# ---------------------------------------------------------------------------
# Baseline persistence. The state captured BEFORE a profile is applied is the
# baseline to restore at exit. Two things made that go wrong before 2026-09-13:
#   - Restore-AvrState must skip when the unit is in standby at exit (modes
#     cannot be set then), so a session in which the AVR auto-slept — a music
#     session that ended after the box idled — left the PROFILE on the unit.
#   - The next launch then snapshotted that profile as its "baseline", and
#     faithfully put PLII Music + Flat back after the film. Seen live 2026-09-12.
# So the baseline is written to disk when captured, and only removed once a
# restore has actually been applied. A file present at launch means the last
# restore never happened: reuse it instead of snapshotting a profile.
# ---------------------------------------------------------------------------
function Save-AvrBaseline { param($State, [string] $Path = $script:AvrBaselineFile)
    $State | ConvertTo-Json -Compress | Set-Content -Path $Path -Encoding UTF8
}
function Read-AvrBaseline { param([string] $Path = $script:AvrBaselineFile)
    if (-not (Test-Path $Path)) { return $null }
    try { Get-Content -Path $Path -Raw | ConvertFrom-Json } catch { $null }
}
function Remove-AvrBaseline { param([string] $Path = $script:AvrBaselineFile)
    Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Put the listening settings back the way a Get-AvrState snapshot found them.
# PlexHDR.ps1 calls this when Plex exits, so whatever you do next on this input
# does not inherit Movie or Pro Logic II Music.
#
# POWER IS DELIBERATELY NOT RESTORED. If the AVR was in standby when Plex
# launched, Set-AvrProfile woke it; switching it back off at exit would kill the
# sound for whatever you do next, which is worse than leaving it on.
#
# Surround is restored in TWO steps, in this order (verified on the unit
# 2026-09-10):
#   1. the saved PSMODE (e.g. "PSMODE:CINEMA") - this is what actually brings
#      back a Pro Logic II mode, since the MS string alone cannot (point 3 at the
#      top). It also restores the PLII flavour memory, so a later MSMOVIE does not
#      resolve to PLII Music just because a music session ran.
#   2. the saved MS string verbatim - a no-op if the saved mode was Pro Logic II,
#      and the thing that wins if it was anything else (e.g. "MSMCH STEREO"),
#      because PSMODE on its own would have left the AVR in Pro Logic II.
# then every other saved field, in $AvrFields order. Read back and compared.
#
# Returns one of: 'restored', 'restored-with-warnings', 'skipped-standby',
# 'unreachable', 'empty'. Only the first two mean the baseline was applied.
# ---------------------------------------------------------------------------
function Restore-AvrState {
    param(
        [Parameter(Mandatory)] $State,
        [string] $Ip = $script:AvrIp,
        [scriptblock] $Logger = { param($m) Write-Host $m }
    )
    function say($m) { & $Logger "avr: $m" }

    $restorable = $script:AvrFields | Where-Object { $_.Name -notin 'Power', 'Input', 'Volume', 'Signal' } | ForEach-Object { $_.Name }
    $cmds = @($restorable | ForEach-Object { $State.$_ } | Where-Object { $_ })
    if (-not $cmds) { say "saved state was empty - nothing to restore"; return 'empty' }

    try {
        $power = (Get-AvrState -Ip $Ip -Fields Power).Power
    } catch {
        say "unreachable at exit ($($_.Exception.Message)) - settings left as they are"
        return 'unreachable'
    }
    if ($power -notlike 'PWON*') { say "in standby at exit - cannot restore now; baseline kept for the next launch"; return 'skipped-standby' }

    # Only what differs (see Get-AvrDelta). PSMODE before the MS string, as above. A saved
    # Pro Logic II / Neo:6 reply string is never sent: it cannot set anything (point 3), and
    # its PSMODE carries the mode. Tone is skipped while the saved state has Dynamic EQ on.
    $target = [ordered]@{}
    foreach ($f in $restorable) {
        $v = $State.$f
        if (-not $v) { continue }
        if ($f -eq 'Surround' -and ($v -like 'MSDOLBY PLII*' -or $v -like 'MSDTS NEO:6*')) { continue }
        $target[$f] = $v
    }
    $now = Get-AvrState -Ip $Ip -Fields $restorable
    $delta = @(Get-AvrDelta -Current $now -Target $target -Skip (Get-AvrToneSkip $State))
    if (-not $delta.Count) { say "already at the saved state - nothing sent"; return 'restored' }

    say ("restoring only what differs ($($delta.Count)): " + (Format-AvrDelta $delta))
    Invoke-AvrCommand -Ip $Ip -Commands @($delta.Cmd) -SettleMs 300 | Out-Null
    Start-Sleep -Milliseconds 500
    $after = Get-AvrState -Ip $Ip -Fields $restorable
    say ("now: " + (Format-AvrState $after))

    $ok = $true
    foreach ($field in $restorable) {
        if (-not ($State.$field -and $after.$field) -or ($after.$field -eq $State.$field)) { continue }
        # A saved Pro Logic II / Neo:6 reply string cannot be sent back (point 3);
        # its PSMODE was restored instead, and the MS reply resolves against the
        # signal still on the input (a bitstream lingers for a while after Plex
        # exits). Not a failure — the PLII memory is what carries over.
        if ($field -eq 'Surround' -and ($State.Surround -like 'MSDOLBY PLII*' -or $State.Surround -like 'MSDTS NEO:6*')) {
            say "note: Surround reads '$($after.Surround)' (saved '$($State.Surround)' is an upmixer reply; its PSMODE was restored and the mode follows the signal)"
            continue
        }
        say "WARN $field came back as '$($after.$field)', wanted '$($State.$field)'"
        $ok = $false
    }
    if ($ok) { 'restored' } else { 'restored-with-warnings' }
}

# Dot-source this file to get the functions:      . .\AvrAudio.ps1
# Nothing runs on load, deliberately — PlexHDR.ps1 dot-sources it and decides
# when to act, and a stray call here would poke the AVR just by loading.
