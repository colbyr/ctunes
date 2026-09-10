# Always transcode: a setting that streams every track through the server's transcoder

## Context

Playback is direct play only. `PlexLibrary.streamURL(for:)` returns the raw part file
(`/library/parts/1017/1746246593/file.flac?X-Plex-Token=…`) and `AudioPlayer.loadItem` hands
it straight to `AVPlayerItem(url:)`. PLAN.md made that call from a codec census (every one of
the 2,252 tracks decodes natively on iOS) and explicitly deferred "transcode session
lifecycle, teardown bookkeeping, restart-on-seek". Its verification section says the
transcode path "moves up the list" if the census changes. It hasn't; what has changed is
where the app is used. A FLAC album is ~30 MB per track over a remote connection or a
cellular link, and the cache prefetches the next three of them.

`notes/track-cache.md` and `notes/offline.md` both assume the bytes on disk are the original
part file: the cache is keyed by part id and stamp, the download is checked against
`Content-Length`, and a pinned file is the same file the server holds.

Goal: a user-facing setting that makes every streamed track come from the server's
transcoder at a chosen bitrate, so listening away from the LAN costs a fraction of the data.
Non-goals for v1: transcoding what the cache and the pin store download (they keep the
original), a "cellular only" mode, per-network rules, and any change to what plays from disk.

## Approach

**A per-device `StreamQuality` setting in `UserDefaults`. When it is not `original`, the
player builds the item from the universal transcoder's HLS URL instead of the part URL,
still preferring a local file when one exists. The window prefetch is suspended while
transcoding, pins are untouched.** Everything else about the player stays as it is: the
`-1005` retry, the local-file eviction fallback, the timeline reports, the end-of-track
guard.

Why HLS and not a progressive `protocol=http` stream:

- AVPlayer treats an HLS playlist as seekable with a known duration. A progressive
  transcode has no `Content-Length` and no byte ranges, so a seek is a restart with an
  `offset=` parameter and a fresh item, which is the restart-on-seek bookkeeping PLAN.md
  wanted to avoid.
- The lock screen's scrubber and `changePlaybackPositionCommand` already go through
  `seek(to:)`; with HLS they keep working without a special case.
- The periodic observer's `currentTime >= duration` end guard needs a real duration. The
  observer only takes `item.duration` when it is finite, and `loadCurrentItem` seeds
  `duration` from the track's metadata, so an indefinite HLS duration would still be
  survivable, but a finite one is better.

Why not transcode the cache too: the cache's contract is "the file the server has", checked
by size and named by part stamp. A transcoded copy is a different file with a different
length every time, would need its own namespace and a different integrity check, and
would make the "pinned root first" rule ambiguous. The setting is about bandwidth, and a
local file costs none, so local wins and the cache simply stops filling itself while the
setting is on. Pinned albums are an explicit ask for the original, and stay one.

Why per device and not synced: like the active listener set, this is about the network the
device is on. The Mac at home should not inherit the phone's cellular choice.

Alternatives dropped:

- **Automatic: transcode when the chosen connection is not `local`.** Tempting, and
  probably the eventual default, but `local: true` is already known to lie about
  reachability and the app deliberately never consults `NWPathMonitor`. A manual switch is
  honest about what it does and can be verified. Automatic can be layered on later as a
  third value of the same setting.
- **Sniff the codec and only transcode FLAC.** The bandwidth problem is bitrate, not codec;
  a 320 kbps MP3 is also worth reducing on a slow link. Transcoding everything keeps the
  rule explainable.

## The transcoder endpoint, as measured

Measured 2026-09-10 against the Mac Mini server (PMS on the LAN, FLAC sources) with a
Python probe over `urllib`, then in the simulator. What the app sends:

```
GET {server}/music/:/transcode/universal/start.m3u8
    ?path=/library/metadata/{ratingKey}
    &mediaIndex=0&partIndex=0
    &protocol=hls
    &directPlay=0&directStream=0
    &fastSeek=1
    &musicBitrate=192
    &session={fresh UUID per item}
    &X-Plex-Client-Profile-Extra=add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)
    &X-Plex-Token={token}
    &X-Plex-Client-Identifier=…&X-Plex-Product=ctunes&X-Plex-Version=…&X-Plex-Device=…&X-Plex-Platform=iOS
```

Every value is strictly percent-encoded (`&`, `=`, `(`, `)` included); the server splits
on a bare `&` inside the profile extra. `URLComponents` leaves those bare, so the query
is built by hand.

1. **Shape.** The master is `application/vnd.apple.mpegurl`, one variant,
   `BANDWIDTH=182000` whatever the bitrate, pointing at the relative path
   `session/{id}/base/index.m3u8`. AVPlayer resolves that itself. The variant lists every
   segment up front (`#EXTINF:1` each, `#EXT-X-TARGETDURATION:1`, `#EXT-X-ALLOW-CACHE:NO`,
   no playlist type) and ends with `#EXT-X-ENDLIST`, so the duration is finite: AVPlayer
   reported 260.0s for a 260s track. Segments are `video/MP2T`, ~25–30 KB each at 192k.
   **The variant playlist and the segments need no token**; the session id is the
   credential.
2. **Parameters.** Without the profile extra, `start.m3u8` is a `400 Bad Request` for
   `X-Plex-Platform=iOS` (it works for `Chrome`, so the built-in iOS profile simply has no
   music transcode target). With it, `musicBitrate` is honoured: 64 → 83 kbps of TS,
   192 → ~230–240 kbps, 320 → 336 kbps (MPEG-TS overhead on top of the AAC). A
   `+add-limitation(scope=musicCodec&scopeName=aac&type=upperBound&name=audio.bitrate&value=N)`
   in the profile extra also works and wins when both are given; the app sends only
   `musicBitrate`. `audioCodec=mp3` in the target gives mp3. `directPlay=0&directStream=0`
   were sent throughout; not tested without.
   **The server reuses a finished transcode of the same track for a few minutes,
   regardless of the bitrate or codec asked for.** Every probe of track 1030 after the
   first came back byte-identical at 192k whatever was requested; fresh tracks honoured
   the request. Switching quality and replaying the same track right away serves the old
   bitrate; harmless.
3. **Identity.** `X-Plex-Token` alone is not enough (400); the identity has to be in the
   query. `PlexIdentity.queryItems` mirrors `headers` minus `Accept`.
4. **Sessions.** Starting a new `start.m3u8` under the same `session` for another track
   replaces the transcode in `/transcode/sessions` (one entry, new duration) and the
   variant answers at once from `curl`. **In the app it did not**: the next track under
   the key the previous one was still streaming from got `HTTP 404` on its segments for
   30s (AVFoundation retries with backoff) before playing. A fresh UUID per item made the
   transition 0.25s. Starting a session for the same client also killed the previous
   session's transcode outright (`e1` vanished the moment `e2` started), so there is
   nothing to stop. `/music/:/transcode/universal/stop?session=` works (200, entry gone)
   but is unused. An abandoned session that was fetched from disappears within a minute
   or two; one that was started but never fetched lingers as a zero-progress entry for
   ~5 minutes. **A paused session is reaped after ~4 minutes** even with paused
   `/:/timeline` reports every 20s under the same `X-Plex-Session-Identifier`. Resuming
   after that hits 404s; the existing item-failure retry rebuilds from the same URL, which
   starts the transcode again from zero. Not handled in v1, see follow-ups.
5. **Seeking.** Without `fastSeek`, a segment beyond what has been cut takes ~2.2s
   (the transcoder restarts at the offset) and AVFoundation logs
   `-12889 No response for media file in 1s`, then `-12880 Can not proceed after
   removing variants`, and the item sits in `waiting` forever with no `status` change,
   so the retry never fires. With `fastSeek=1` the same segment arrives in 0.18s and the
   near-end seek plays. The 1s budget seems to follow the 1s target duration. Transcode
   speed shows as ~3x while streaming and ~100x when cutting a jump, so the whole track is
   not done early; the server throttles.
6. **Timeline.** The report is the same call, but **a `stopped` report kills a transcode
   that started just before it.** The server keys its "Streaming Resource" session by
   client: `start.m3u8` adds one, tagged with the last `X-Plex-Session-Identifier` seen
   from that client, and a `/:/timeline?state=stopped` from the same client terminates
   whatever that session currently is, "Client stopped playback". The app fired `stopped`
   for the old track and loaded the new item in the same turn, so the report landed a few
   milliseconds after the new start and terminated it; every segment then came back as a
   200 with an empty body (`ERROR - Session 0x… terminated` per request in the server
   log), AVFoundation reported -1005 on its own backoff for 30s, and the item failed. On
   the phone that was every mid-album skip; the simulator only ever transitioned at the
   end of finished tracks, where the order happened to be right. Sending the transcode
   its own `X-Plex-Session-Identifier` did not help. Fix: no `stopped` report on any
   track-to-track move; the next track's `playing` report carries the session on, and
   `finish`, an emptied queue and sign-out still send it. Diagnosed from the server's
   own log, `GET /diagnostics/logs` with the token returns the zip. A full
   uninterrupted play of a transcoded track in the simulator showed up in
   `/status/sessions/history` at once, so On Rotation sees transcoded listening. A seek
   to 3s from the end followed by the play-out did **not** record a play, for direct play
   or transcoded alike; the dev hook is not a substitute for a real listen here.

## Steps

### 1. `StreamQuality` in PlexKit

```swift
public enum StreamQuality: String, CaseIterable, Sendable {
    case original
    case kbps320, kbps192, kbps128
    public var bitrate: Int? { ... }   // nil for original
    public var label: String { ... }   // "Original", "320 kbps", …
}
```

One type, in `PlexLibraryModels.swift` next to `TrackSource`. The raw value is what
`UserDefaults` stores; adding `case automatic` later is a new raw value, not a migration.

### 2. `streamURL(for:quality:)`

`LibrarySource` gains `func streamURL(for track: PlexTrack, quality: StreamQuality) -> URL?`
and the old one-argument form becomes a protocol-extension default that passes `.original`,
so the tests and `LiveServerTests` keep compiling. `PlexLibrary` builds the transcoder URL
with `URLComponents` (the token and identity values must be percent-encoded, unlike the
string concatenation the part URL gets away with). `OfflineLibrary` returns nil either way.

The session id has to reach the URL. `reportTimeline` already takes
`sessionIdentifier:` as a parameter, so do the same here rather than storing it on the
library. The function stays `nonisolated` and synchronous; `loadCurrentItem` needs it that
way so the cursor can't move under an await.

Test in `PlexLibraryTests`: the query carries `path`, `protocol=hls`, the bitrate, the
session, the token and the client identifier, and `.original` still yields the part URL.

### 3. The setting

`AudioPlayer` owns it: `var streamQuality: StreamQuality`, read from `UserDefaults` at init
and written on set. The player is where the URL is chosen and where the prefetch decision
is made, and `AppModel` has no business with it. A change while a track is playing takes
effect on the next item; don't rebuild the current one, it would restart the track.

Where `loadCurrentItem` picks the URL:

```swift
let local = cache.localURL(server: server, part: part)
guard let url = local ?? library.streamURL(for: track, quality: streamQuality, sessionIdentifier: sessionIdentifier) else { return }
```

Local still wins. `itemFailedToLoad`'s eviction path re-streams and must use the same call,
so route both through one small `remoteURL(for:)` helper on the player.

`prefetch()`: when `streamQuality != .original`, hand the cache an empty window. `retain`
already treats an empty window as "cancel every unpinned fetch, leave pins alone", which is
exactly the wanted behaviour. The current track is also left out of the window, so it is
not downloaded at original size behind the transcode.

Log the choice in the existing `load item` line: `stream(192k)` next to `local`/`stream`,
so `log show --predicate 'category == "AudioPlayer"'` tells the two apart.

### 4. UI

The browse root's ellipsis menu already holds the device-level switches (`MusicView`,
the `Downloads` section). Add a `Section("Streaming")` above it with a `Picker` bound to
`player.streamQuality`, the `StreamQuality` cases as rows, rendered as an inline menu
picker so it reads as a submenu. Disabled offline, like the favorites toggle, since nothing
streams there anyway. No new screen.

### 5. Teardown

Not needed: a new session for the client kills the previous transcode, and an
abandoned one is reaped in minutes (measurement 4). No `stop` call.

### What shipped differs from the plan in two places

- `sessionIdentifier` is **not** reused for the transcode: `remoteURL(for:)` mints a UUID
  per item (measurement 4). The parameter stays on `streamURL(for:quality:sessionIdentifier:)`
  so the library has no state.
- `fastSeek=1` is in the URL (measurement 5).

## Verification

Done 2026-09-10:

- `make test`: the URL test, the identity query-items test, everything else unchanged.
- `make live-test`: the live walk fetches the `.m3u8` at `kbps192` and gets
  `application/vnd.apple.mpegurl` starting `#EXTM3U`.
- Simulator, Abbey Road (not pinned) with `streamQuality` set to `kbps192` via
  `simctl spawn booted defaults write com.colbyr.ctunes streamQuality kbps192`:
  `load item stream(192k)`, ready in 0.6s, duration 260.0s, `Caches/Tracks` never
  created, one AAC session in `/transcode/sessions`. The pinned Soulmate Stuff still
  plays `local`. `CTUNES_DEV_AUTOPLAY=end`: the near-end seek plays and the next track
  is ready 0.25s after the transition. A full play of Come Together landed in history.
  `CTUNES_DEV_AUTOPLAY=skip` (added for measurement 6) reproduced the phone's mid-track
  stall on demand and, after the fix, lands on the next track in 0.3s.

Still to do on a device:

- On cellular with Wi-Fi off: play an album, watch Settings → Cellular's counter for the
  app against a known track length. This is the number the setting exists for.
- The lock-screen scrubber on a transcoded track.
- Pause for five minutes, resume: expect the 404 stall described in measurement 4.

## Follow-ups, not in v1

- **Resume after a long pause.** The transcode session dies ~4 minutes into a pause and
  the item 404s on resume. Options: rebuild the item on the first `-12938` error-log entry
  and seek back to `currentTime`, or a periodic `/music/:/transcode/universal/ping?session=`
  while paused, if the server honours it (unmeasured). Worth doing before this is the
  default on cellular.
- `case automatic`: transcode unless the chosen connection is local and answered the probe.
- A separate download quality. Measured 2026-09-10 and deliberately left at Original:
  - A transcoded download is `start?protocol=http` with a
    `container=mp3&audioCodec=mp3` target: `audio/mpeg`, chunked, no `Content-Length`,
    `Accept-Ranges: none`, and MP3 whatever container is asked for (`mp4`/`aac` targets
    still came back as MP3). The token works in a header. The bitrate is honoured.
  - **The server runs one music transcode per account at a time.** Starting a playback
    transcode killed an in-flight download mid-body (`IncompleteRead`), and starting a
    download killed the playback session. A second client identifier, product and device
    name changed nothing. A download started while another transcode was live once came
    back with the wrong bytes: 1.5 MB for a 23s track that alone is 486 KB.
  - So it would need: a transcoded namespace in `TrackCache` (`<id>-<stamp>-q192.mp3`),
    an integrity check that is "completed cleanly and non-empty" rather than a length,
    `localURL` accepting any variant, and a rule that the pump runs transcoded downloads
    only while the player is not streaming a transcoded item, with the player cancelling
    an in-flight transcoded download before it starts one. Reduced-quality downloads
    would then happen at home on Wi-Fi with streaming at Original, and pause while
    streaming transcoded.
- Codec choice (`aac` vs `mp3`) if the server's AAC encoder turns out to be the poor one.
