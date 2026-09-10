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

## The transcoder endpoint

None of this has been measured yet. Verify with `curl` against the real server before
writing Swift, the way every other endpoint in CLAUDE.md was. Expected shape, from
python-plexapi's `getStreamURL` and Plex Web's requests:

```
GET {server}/music/:/transcode/universal/start.m3u8
    ?path=/library/metadata/{ratingKey}
    &mediaIndex=0&partIndex=0
    &protocol=hls
    &directPlay=0&directStream=0
    &musicBitrate=192
    &session={sessionIdentifier}
    &X-Plex-Token={token}
    &X-Plex-Client-Identifier={clientIdentifier}
    &X-Plex-Product=ctunes&X-Plex-Platform=iOS
```

Things to establish with curl, and to record in this note once known:

1. The master playlist comes back as `application/vnd.apple.mpegurl` and points at a
   variant playlist with a full segment list and `#EXT-X-ENDLIST`, so the duration is
   finite. If the playlist is `EVENT` type with no end list, AVPlayer reports an indefinite
   duration and live-style seeking; the metadata duration seed then does the work and the
   note must say so.
2. Which query parameters are actually honoured: `musicBitrate` (kbps), `audioCodec`
   (`aac` or `mp3`), and whether `directStream=0` is required to stop the server passing a
   FLAC through untouched. `X-Plex-Client-Profile-Extra=add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)`
   is the escape hatch if the default profile refuses.
3. Whether the identity headers are needed in the query. AVPlayer sends none, so every
   `X-Plex-*` value the transcoder wants has to ride the URL like the token already does.
   This is the one place the app would build identity outside `PlexClient`; keep it in
   `PlexIdentity` as a `queryItems` twin of `headers` so the values still come from one
   spot.
4. Session behaviour: whether starting a new `start.m3u8` under the same `session` kills
   the previous transcode (Plex Web relies on this), or whether the app must call
   `/music/:/transcode/universal/stop?session=` on every track change. The app already has
   a `sessionIdentifier` per player for the timeline; reuse it. Measure how long an
   abandoned transcode lingers in `/status/sessions` and in `top` on the server.
5. Seeking far ahead in the playlist: does the server jump the transcoder, and how long
   does the segment take to arrive. Audio transcodes run well above real time, so the whole
   track is probably done before the first seek; confirm.
6. What the `/:/timeline` report looks like for a transcoded item. The `key` and
   `ratingKey` are unchanged, so it should be identical; check that play history still
   records the play, or On Rotation goes blind for transcoded listening.

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

### 5. Teardown, if step 4 of the measurements says it's needed

`PlexLibrary.stopTranscode(sessionIdentifier:)` calling `/music/:/transcode/universal/stop`,
fire-and-forget from `loadCurrentItem` before the new item is built and from `signOut`,
in the same style as `reportTimeline`. Skip it entirely if a new start under the same
session supersedes the old one.

## Verification

- `make test`: the URL test above, and the existing `streamURL` and cache tests unchanged.
- `make live-test`: extend the live stream test to fetch the `.m3u8` at `kbps192` and check
  the response is a playlist, not JSON or an error page.
- Simulator, `CTUNES_DEV_ALBUM` + `CTUNES_DEV_AUTOPLAY=1` with the setting on: the
  `AudioPlayer` log shows `stream(192k)`, the item reaches `readyToPlay`, the duration is
  finite, and `Caches/Tracks` does not grow. Scrub to the last ten seconds and confirm the
  next-track transition (`CTUNES_DEV_AUTOPLAY=end` after the setting persists).
- Device on cellular with Wi-Fi off: play an album, watch Settings → Cellular's counter
  for the app against a known track length. This is the number the setting exists for.
- Device with a pinned album and the setting on: the pinned tracks play `local`, the rest
  `stream(192k)`; the lock-screen scrubber works on a transcoded track.
- On the server, `/status/sessions` after skipping through five tracks: at most one
  transcode session for this client.

## Follow-ups, not in v1

- `case automatic`: transcode unless the chosen connection is local and answered the probe.
- A separate quality for the window prefetch, which would need a transcoded namespace in
  `TrackCache` and an integrity check that isn't `Content-Length`.
- Codec choice (`aac` vs `mp3`) if the server's AAC encoder turns out to be the poor one.
