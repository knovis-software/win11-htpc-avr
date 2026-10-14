# plexopen.ps1 - open a Plex web-app link in Plex HTPC via Plex Companion (relayed through the
# Plex Media Server), falling back to the default browser when that is not possible.
#
# Usage:
#   plexopen.ps1 <url> [-DryRun]
#
# <url> is any of:
#   https://app.plex.tv/desktop/#!/server/<serverId>/details?key=%2Flibrary%2Fmetadata%2F<ratingKey>
#   https://app.plex.tv/desktop/#!/provider/tv.plex.provider.discover/details?key=%2Flibrary%2Fmetadata%2F<guidHex>
#   plexopen://app.plex.tv/desktop/#!/...      (custom-scheme form: "plexopen://" is swapped for "https://")
#
# Resolution chain:
#   1. Parse the link into (serverId, key) or (discover guid).
#   2. Account token + HTPC client id: read from Plex HTPC's plex.ini (PlexAuthToken=, ClientID=);
#      token alternatively from Plex for Windows' plex.ini or the PLEX_TOKEN environment variable.
#   3. Server address: plex.tv /api/v2/resources, matched on serverId, preferring a local connection
#      (cached in plexopen.cache.json next to this script).
#   4. Discover guid -> library ratingKey via <server>/library/all?guid=plex://<type>/<guid>.
#      (verified 2026-09-08 against a real server for a movie and a TV show)
#   5. Player: Plex HTPC, started if not running, then the server's /clients list is polled until
#      HTPC's client id appears. Modern Plex HTPC (1.71, 2026) has no Companion listener of its own;
#      it registers the PMS as its Companion proxy, so commands go to the SERVER with
#      X-Plex-Target-Client-Identifier = HTPC's client id (verified: /player/navigation/home moves
#      the HTPC UI; /player/mirror/details is answered 400 - the capability list has no "mirror").
#   6. POST <server>/playQueues for the item, then GET <server>/player/playback/playMedia with
#      containerKey=/playQueues/<id> - starts playback in HTPC (verified 2026-09-08, The Matrix,
#      confirmed by the server's /status/sessions). There is no way to show the item's details
#      page instead: HTPC answers /player/mirror/details with 400.
#   Any failure -> Start-Process <https url> (default browser).

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Url,
    [switch] $DryRun,
    # Set by PlexHDR.ps1, which calls this while Plex is already on the TV: a failure
    # must not throw a browser window over the player. Log it and exit 1 instead.
    [switch] $NoFallback
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may default to TLS 1.0 for https; plex.tv requires 1.2.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$script:ClientId   = 'htpc-plexopen'
$script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CachePath  = Join-Path $script:ScriptDir 'plexopen.cache.json'
$script:LogPath    = Join-Path $script:ScriptDir 'plexopen.log'
$script:HtpcIni    = Join-Path $env:LOCALAPPDATA 'Plex HTPC\plex.ini'
$script:CommandId  = 0

function Log([string] $msg) {
    # Never let the account token reach the log (error messages can echo whole URLs).
    if ($script:Token) { $msg = $msg.Replace($script:Token, '<token>') }
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg
    Write-Host $line
    try {
        # Bound the log. It is append-only and every launch adds ~9 lines, so without
        # this it grows forever -- slowly, but with no limit. Past the threshold, keep
        # the most recent lines and drop the rest; history here is only ever useful for
        # diagnosing the last few launches.
        $f = Get-Item $script:LogPath -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt 200KB) {
            $keep = Get-Content $script:LogPath -Tail 1000
            [IO.File]::WriteAllLines($script:LogPath, $keep)
        }
        Add-Content -Path $script:LogPath -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

function Fallback([string] $httpsUrl, [string] $why) {
    if ($NoFallback) {
        # The caller owns the screen (PlexHDR.ps1, Plex already up): report, never open a browser.
        Log "failed (no fallback): $why"
        exit 1
    }
    Log "fallback (browser): $why"
    if (-not $DryRun) { Start-Process $httpsUrl }
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Parse the link
# ---------------------------------------------------------------------------
if (-not $Url) { Write-Host "usage: plexopen.ps1 <plex web url> [-DryRun] [-NoFallback]"; exit 2 }

$httpsUrl = $Url -replace '^plexopen://', 'https://'
Log "open: $httpsUrl"

$link = [ordered]@{ kind = 'unknown'; serverId = ''; key = ''; guid = ''; type = ''; playlistId = '' }
# Playlists are checked first and matched on the KEY, not the path segment: any
# #!/server/<id>/<anything>?key=/playlists/<n>. Doing this before the details rule below means a
# playlist reached through a details page is still treated as a playlist. Verified 2026-09-10 that
# POST /playQueues?playlistID=<n> works for audio, video and smart playlists alike.
$playlistHit = $null
if ($httpsUrl -match '#!/server/([0-9a-f]{40})/[^?]*\?key=([^&]+)') {
    $plServer = $Matches[1]
    # Left side is evaluated before -match overwrites $Matches, so [2] is still the key here.
    if ([uri]::UnescapeDataString($Matches[2]) -match '^/playlists/(\d+)') { $playlistHit = @{ serverId = $plServer; id = $Matches[1] } }
}
if ($playlistHit) {
    $link.kind       = 'playlist'
    $link.serverId   = $playlistHit.serverId
    $link.playlistId = $playlistHit.id
    $link.key        = "/playlists/$($playlistHit.id)"
}
elseif ($httpsUrl -match '#!/server/([0-9a-f]{40})/details\?key=([^&]+)') {
    $link.kind     = 'library'
    $link.serverId = $Matches[1]
    $link.key      = [uri]::UnescapeDataString($Matches[2])
}
elseif ($httpsUrl -match '#!/provider/tv\.plex\.provider\.discover/details\?key=([^&]+)') {
    $link.kind = 'discover'
    $k = [uri]::UnescapeDataString($Matches[1])
    if ($k -match '/library/metadata/([0-9a-f]{24})$') { $link.guid = $Matches[1] }
    else { Fallback $httpsUrl "unrecognised discover key '$k'" }
}
elseif ($httpsUrl -match '#!/media/([0-9a-f]{40})/com\.plexapp\.plugins\.library') {
    # Section / folder browse links (source=N&key=/library/sections/N/folder?parent=M).
    # Companion has no "show this container" command.
    Fallback $httpsUrl "library browse link (section/folder) - not an item"
}
else {
    Fallback $httpsUrl "not a recognised app.plex.tv item link"
}
Log ("parsed: kind={0} serverId={1} key={2} guid={3}" -f $link.kind, $link.serverId, $link.key, $link.guid)

# ---------------------------------------------------------------------------
# 2. Account token and HTPC client id
# ---------------------------------------------------------------------------
function Get-IniValue([string] $ini, [string] $pattern) {
    if (-not (Test-Path $ini)) { return $null }
    $m = Select-String -Path $ini -Pattern $pattern | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}
function Get-PlexToken {
    # Plex HTPC writes PlexAuthToken=; Plex for Windows writes myPlexAccessToken=.
    $t = Get-IniValue $script:HtpcIni '^(?:PlexAuthToken|myPlexAccessToken)=(\S+)'
    if ($t) { Log "token: from $script:HtpcIni"; return $t }
    $desktopIni = Join-Path $env:LOCALAPPDATA 'Plex\plex.ini'
    $t = Get-IniValue $desktopIni '^(?:PlexAuthToken|myPlexAccessToken)=(\S+)'
    if ($t) { Log "token: from $desktopIni"; return $t }
    if ($env:PLEX_TOKEN) { Log "token: from PLEX_TOKEN env"; return $env:PLEX_TOKEN }
    return $null
}

$headers = @{
    'X-Plex-Client-Identifier' = $script:ClientId
    'X-Plex-Product'           = 'HTPC plexopen'
    'X-Plex-Version'           = '1.0'
    'X-Plex-Device-Name'       = $env:COMPUTERNAME
    'Accept'                   = 'application/json'
}
$token = Get-PlexToken
if (-not $token) { Fallback $httpsUrl "no Plex token found (Plex HTPC / Plex for Windows plex.ini, or PLEX_TOKEN)" }
$headers['X-Plex-Token'] = $token
$script:Token = $token
# XML variant for server calls whose JSON form trips ConvertFrom-Json (duplicate "guid"/"Guid"
# keys on metadata) or that are simpler to regex (play queue creation, Companion responses).
$xmlHeaders = $headers.Clone(); $xmlHeaders.Remove('Accept')

# ---------------------------------------------------------------------------
# 3. Server address (plex.tv resources, cached)
# ---------------------------------------------------------------------------
# Cache is a flat JSON object { "<serverId>": "<base url>" }, loaded into a hashtable
# (PowerShell 5.1 has no ConvertFrom-Json -AsHashtable).
function Load-Cache {
    $h = @{}
    if (Test-Path $script:CachePath) {
        try {
            $o = Get-Content $script:CachePath -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch {}
    }
    return $h
}
function Save-Cache($cache) {
    try { $cache | ConvertTo-Json -Depth 3 | Set-Content -Path $script:CachePath } catch {}
}
function Test-Server([string] $base) {
    try {
        $r = Invoke-RestMethod -Uri "$base/identity" -Headers $headers -TimeoutSec 4
        return $r.MediaContainer.machineIdentifier
    } catch { return $null }
}
$script:Resources = $null
function Get-Resources {
    if (-not $script:Resources) {
        $script:Resources = Invoke-RestMethod -Uri 'https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0' -Headers $headers -TimeoutSec 15
    }
    return $script:Resources
}
function Resolve-Server([string] $serverId) {
    $cache = Load-Cache
    if ($cache.ContainsKey($serverId)) {
        $base = $cache[$serverId]
        if ((Test-Server $base) -eq $serverId) { return $base }
        Log "cached server address $base no longer answers; re-resolving"
    }
    $dev = Get-Resources | Where-Object { $_.clientIdentifier -eq $serverId -and $_.provides -match 'server' } | Select-Object -First 1
    if (-not $dev) { return $null }
    # Prefer local plain-http (no cert fuss), then local https, then remote.
    $conns = @($dev.connections | Sort-Object { if ($_.local) { 0 } else { 1 } }, { if ($_.protocol -eq 'http') { 0 } else { 1 } })
    foreach ($c in $conns) {
        foreach ($base in @("http://$($c.address):$($c.port)", $c.uri)) {
            if ((Test-Server $base) -eq $serverId) {
                $cache[$serverId] = $base
                Save-Cache $cache
                return $base
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 4. Discover guid -> library item
# ---------------------------------------------------------------------------
function Resolve-Discover([string] $guid) {
    # Ask the Discover provider what this is (movie / show) so the library guid prefix is right.
    $type = $null
    try {
        # Ask for XML: the provider's JSON carries both "guid" and "Guid", which PowerShell 5.1's
        # ConvertFrom-Json rejects. Invoke-RestMethod may hand the body back as a plain string.
        $d = Invoke-RestMethod -Uri "https://discover.provider.plex.tv/library/metadata/$guid" -Headers $xmlHeaders -TimeoutSec 10
        if ($d -is [string]) { $d = [xml]($d -replace '^[^<]*') }
        $mc = $d.MediaContainer
        $meta = @($mc.Video) + @($mc.Directory) | Where-Object { $_ } | Select-Object -First 1
        $type = $meta.type
        Log ("discover: '{0}' ({1}) type={2}" -f $meta.title, $meta.year, $type)
    } catch { Log "discover provider lookup failed: $($_.Exception.Message)" }
    $types = if ($type) { @($type) } else { @('movie', 'show') }

    # Find the owning server: try every owned server.
    $servers = @(Get-Resources | Where-Object { $_.provides -match 'server' -and $_.owned })
    foreach ($s in $servers) {
        $base = Resolve-Server $s.clientIdentifier
        if (-not $base) { continue }
        foreach ($t in $types) {
            $q = [uri]::EscapeDataString("plex://$t/$guid")
            try {
                $r = Invoke-RestMethod -Uri "$base/library/all?guid=$q" -Headers $headers -TimeoutSec 10
                if ([int]$r.MediaContainer.size -gt 0) {
                    $item = $r.MediaContainer.Metadata | Select-Object -First 1
                    Log ("library match: '{0}' ({1}) ratingKey={2} on {3}" -f $item.title, $item.year, $item.ratingKey, $s.name)
                    return @{ serverId = $s.clientIdentifier; base = $base; key = "/library/metadata/$($item.ratingKey)"; type = $item.type }
                }
            } catch { Log "guid query failed on $($s.name): $($_.Exception.Message)" }
        }
    }
    return $null
}

$serverBase = $null
if ($link.kind -in 'library', 'playlist') {   # a playlist lives on a server exactly like an item
    $serverBase = Resolve-Server $link.serverId
    if (-not $serverBase) { Fallback $httpsUrl "server $($link.serverId) not reachable" }
}
elseif ($link.kind -eq 'discover') {
    $hit = Resolve-Discover $link.guid
    if (-not $hit) { Fallback $httpsUrl "discover item $($link.guid) not in any library" }
    $link.serverId = $hit.serverId; $link.key = $hit.key; $link.type = $hit.type
    $serverBase = $hit.base
}
Log "server: $serverBase  key: $($link.key)"

# ---------------------------------------------------------------------------
# 4b. What kind of media is it? Decided BEFORE the player is started (step 5), because the kind
#     picks the launch profile: music starts PlexHDR's music mode (AVR Pro Logic II Music, display
#     left alone) instead of the 4K HDR movie mode.
# ---------------------------------------------------------------------------
# Media class for the playMedia "type" parameter (music | video | photo), from the item's metadata type.
# A playlist's own type is 'playlist', which says nothing about what is IN it - Best Movies and Nature
# Shuffle are video playlists - so playlists are resolved from playlistType just below, and only reach
# the 'playlist' entry here if that lookup fails.
function Get-MediaClass([string] $itemType) {
    switch ($itemType) {
        { $_ -in 'artist', 'album', 'track', 'audio', 'playlist' } { return 'music' }
        { $_ -in 'photo', 'photoalbum' }                           { return 'photo' }
        default                                                   { return 'video' }
    }
}
if ($link.kind -eq 'playlist') {
    try {
        $pm = Invoke-WebRequest -Uri "$serverBase$($link.key)" -Headers $xmlHeaders -TimeoutSec 10 -UseBasicParsing
        if ($pm.Content -match 'playlistType="([^"]+)"') { $link.type = $Matches[1] }   # audio | video | photo
        else { Log "playlist $($link.playlistId) reports no playlistType - assuming music" }
    } catch { Log "playlist type lookup failed: $($_.Exception.Message)" }
}
if (-not $link.type) {
    try {
        $m = Invoke-WebRequest -Uri "$serverBase$($link.key)" -Headers $xmlHeaders -TimeoutSec 10 -UseBasicParsing
        if ($m.Content -match '<(?:Video|Directory|Track|Photo|Playlist)[^>]*\stype="([^"]+)"') { $link.type = $Matches[1] }
    } catch { Log "metadata type lookup failed: $($_.Exception.Message)" }
}
$mediaClass = Get-MediaClass $link.type
# /playQueues and playMedia use DIFFERENT words for audio: the queue endpoint wants type=audio, the
# playMedia command wants type=music. Verified 2026-09-10 - type=audio creates the queue. This script
# used to send 'music' to both, so music items never had a working path.
$pqType = if ($mediaClass -eq 'music') { 'audio' } else { $mediaClass }
Log "item type: $($link.type) -> playMedia '$mediaClass', playQueue '$pqType'"

# ---------------------------------------------------------------------------
# 5. Player (Plex HTPC) - start if needed, wait until the server lists it as a client
# ---------------------------------------------------------------------------
function Find-HtpcExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Plex HTPC\Plex HTPC.exe'),
        (Join-Path $env:ProgramFiles 'Plex\Plex HTPC\Plex HTPC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Plex\Plex HTPC\Plex HTPC.exe')
    )
    if ($env:PLEX_HTPC_EXE) { $candidates = @($env:PLEX_HTPC_EXE) + $candidates }
    # A running instance tells us where it lives (e.g. an install on another drive).
    $proc = Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { $candidates = @($proc.Path) + $candidates }
    # The NSIS uninstall entry records the chosen install directory.
    foreach ($hive in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $entries = Get-ItemProperty $hive -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Plex HTPC*' }
        foreach ($e in $entries) {
            foreach ($p in @($e.InstallLocation, $e.DisplayIcon, $e.UninstallString)) {
                if (-not $p) { continue }
                $dir = ($p -replace '^"|"$|,\d+$' -replace '\\[^\\]+\.exe.*$', '')
                if ($dir) { $candidates += (Join-Path $dir 'Plex HTPC.exe') }
            }
        }
    }
    # Last resort: "<drive>:\Plex HTPC\Plex HTPC.exe" on any fixed drive.
    foreach ($dr in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $candidates += (Join-Path $dr.Root 'Plex HTPC\Plex HTPC.exe')
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
# Prefer a curated launch shortcut over starting the executable directly. On the HTPC
# '<install folder>\Plex HTPC 4K HDR.lnk' runs PlexHDR.ps1, which switches the display to 4K,
# sets the Sony picture mode over IP, launches the player, and restores 1080p and game
# mode when it exits. Starting the .exe ourselves would silently skip all of that.
# Music gets '<install folder>\Plex HTPC Music.lnk' (PlexHDR -Mode music: AVR Pro Logic II Music, Audyssey
# Flat, display left alone) so an album or audio playlist does not come up in movie mode. This only
# matters on a cold start: an already-running Plex HTPC keeps whatever profile it was launched with.
function Find-HtpcLaunchTarget([string] $mediaClass) {
    $candidates = @()
    # PlexHDR.ps1 pins this to the bare exe when it hands over a -Url, so it must win for every kind.
    if ($env:PLEX_HTPC_LAUNCH) { $candidates += $env:PLEX_HTPC_LAUNCH }
    if ($mediaClass -eq 'music') { $candidates += (Join-Path $PSScriptRoot 'Plex HTPC Music.lnk') }
    $candidates += (Join-Path $PSScriptRoot 'Plex HTPC 4K HDR.lnk')
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
function Test-HtpcRegistered([string] $htpcId) {
    try {
        $r = Invoke-WebRequest -Uri "$serverBase/clients" -Headers $headers -TimeoutSec 5 -UseBasicParsing
        return ($r.Content -match [regex]::Escape($htpcId))
    } catch { return $false }
}

$htpcId = Get-IniValue $script:HtpcIni '^ClientID=(\S+)'
$htpc   = Find-HtpcExe
if (-not $htpc -and -not $htpcId) { Fallback $httpsUrl "Plex HTPC not installed on this machine" }
if (-not $htpcId) { Fallback $httpsUrl "Plex HTPC has no ClientID yet (never signed in?) - $script:HtpcIni" }

if ($DryRun) {
    # A dry run exits before the queue is built, so for a playlist it cannot know the start item yet.
    # Say so rather than print the playlist key, which is NOT what a real run sends to playMedia.
    $what = if ($link.kind -eq 'playlist') { "playlist $($link.playlistId) (a real run starts on the queue's first entry)" } else { "key=$($link.key)" }
    $start = if (Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue) { 'already running - no launch' }
             else { $l = Find-HtpcLaunchTarget $mediaClass; if ($l) { "launcher $l" } else { "exe $htpc (no launcher found)" } }
    Log ("dry run: would target Plex HTPC {0} ({1}); playMedia {2} as {3} via {4}; start: {5}" -f $htpcId, $htpc, $what, $mediaClass, $serverBase, $start)
    exit 0
}

# Gate on the local process, not only on /clients: the server keeps listing a client for a
# while after it exits, and a command relayed to a dead client just hangs.
$headers['X-Plex-Target-Client-Identifier'] = $htpcId
$xmlHeaders['X-Plex-Target-Client-Identifier'] = $htpcId
function Test-HtpcAnswers {
    # A relayed timeline poll comes back 200 only once HTPC's web client is up and listening.
    try {
        $r = Invoke-WebRequest -Uri "$serverBase/player/timeline/poll?wait=0&commandID=0" -Headers $xmlHeaders -TimeoutSec 4 -UseBasicParsing
        return ($r.StatusCode -eq 200 -and $r.Content -notmatch '<Response code="[45]')
    } catch { return $false }
}
$justStarted = $false
if (-not (Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue)) {
    $launch = Find-HtpcLaunchTarget $mediaClass
    if ($launch) {
        Log "starting Plex HTPC via launcher: $launch"
        Start-Process -FilePath $launch
    } elseif ($htpc) {
        Log "starting Plex HTPC directly (no launcher found): $htpc"
        Start-Process -FilePath $htpc
    } else {
        Fallback $httpsUrl "Plex HTPC executable not found (set PLEX_HTPC_EXE)"
    }
    $justStarted = $true
}
else {
    # Already running but only just started - e.g. PlexHDR.ps1 launched it a moment ago and handed us
    # a -Url. Treat that as fresh too, or playMedia lands before the UI is ready and gets a 400.
    $running = Get-Process -Name 'Plex HTPC' -ErrorAction SilentlyContinue | Select-Object -First 1
    try { if (((Get-Date) - $running.StartTime).TotalSeconds -lt 60) { $justStarted = $true } } catch {}
}
$deadline = (Get-Date).AddSeconds(75)
$up = $false
while ((Get-Date) -lt $deadline) {
    if ((Test-HtpcRegistered $htpcId) -and (Test-HtpcAnswers)) { $up = $true; break }
    Start-Sleep -Milliseconds 1500
}
if (-not $up) { Fallback $httpsUrl "Plex HTPC ($htpcId) is not answering Companion commands via $serverBase" }
# Right after launch the UI still needs a moment after it first answers (an immediate
# playMedia was refused 400 during testing).
if ($justStarted) { Start-Sleep -Seconds 3 }
Log "player ready: $htpcId"

# ---------------------------------------------------------------------------
# 6. Companion command, relayed by the server
# ---------------------------------------------------------------------------
$srvUri = [uri]$serverBase
function Send-Companion([string] $path, [string] $query) {
    $script:CommandId++
    # ${path} - a bare "$path?" would be read as a variable named "path?".
    $r = Invoke-WebRequest -Uri "${serverBase}${path}?${query}&commandID=$($script:CommandId)" -Headers $xmlHeaders -TimeoutSec 20 -UseBasicParsing
    # The server answers 200 with a <Response code="..."/> body carrying the player's verdict,
    # or 204 when the player accepted without a body.
    $code = $r.StatusCode
    if ($r.Content -match '<Response code="(\d+)"') { $code = [int]$Matches[1] }
    return $code
}

# $mediaClass and $pqType were worked out in step 4b, before the player was started.
try {
    # Plex HTPC's playMedia needs a server-side play queue. Verified 2026-09-08: a bare key is
    # answered 400; containerKey=/playQueues/<id> plays; appending "?window=100&own=1" (as
    # python-plexapi does) is mangled by HTPC into "/playQueues/=100&own=1" and fails, so keep
    # the container key plain.
    $pqTail = 'continuous=0&shuffle=0&repeat=0&includeChapters=1&includeRelated=0'
    if ($link.kind -eq 'playlist') {
        $pqQuery = "type=$pqType&playlistID=$($link.playlistId)&$pqTail"
    } else {
        $pqUri   = [uri]::EscapeDataString("server://$($link.serverId)/com.plexapp.plugins.library$($link.key)")
        $pqQuery = "type=$pqType&uri=$pqUri&$pqTail"
    }
    $pq = Invoke-WebRequest -Uri "$serverBase/playQueues?$pqQuery" -Headers $xmlHeaders -Method POST -TimeoutSec 15 -UseBasicParsing
    if ($pq.Content -notmatch 'playQueueID="(\d+)"') { Fallback $httpsUrl "server did not create a play queue for $($link.key)" }
    $pqId = $Matches[1]
    Log "play queue: $pqId"

    # playMedia's "key" is the item to START on. A playlist key is not itself playable, so start on
    # the queue's first entry (shuffle=0, so that is also the selected one). Verified 2026-09-10:
    # <Track ... key="/library/metadata/15095"> for audio, <Video ...> for video, smart lists alike.
    # Albums, artists, shows and seasons are containers too: start on their first entry the same way
    # (what Plex's own clients send). Added 2026-09-11; the album queue itself was verified (28 tracks),
    # playback from it not yet observed on the player.
    $playKey = $link.key
    if ($link.kind -eq 'playlist' -or $link.type -in 'album', 'artist', 'show', 'season') {
        if ($pq.Content -match '<(?:Track|Video|Photo)\s[^>]*?\bkey="([^"]+)"') { $playKey = $Matches[1] }
        else { Fallback $httpsUrl "$($link.type) $($link.key) produced an empty queue" }
        Log "starting on: $playKey"
    }

    $q = "providerIdentifier=com.plexapp.plugins.library&machineIdentifier=$($link.serverId)&protocol=$($srvUri.Scheme)&address=$($srvUri.Host)&port=$($srvUri.Port)" +
         "&key=$([uri]::EscapeDataString($playKey))&containerKey=$([uri]::EscapeDataString("/playQueues/$pqId"))&type=$mediaClass&offset=0&token=$token"
    $code = Send-Companion '/player/playback/playMedia' $q
    Log "companion playMedia -> $code"
    if ($code -lt 200 -or $code -ge 300) { Fallback $httpsUrl "player refused playMedia ($code)" }
} catch {
    Fallback $httpsUrl "companion command failed: $($_.Exception.Message)"
}
exit 0
