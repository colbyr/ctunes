# Transcoded downloads: the server's download queue

## Context

`StreamQuality` (`notes/always-transcode.md`) streams every track through the universal
transcoder as HLS/AAC at a chosen bitrate, but `TrackCache` and the pins keep the original
part file only, and the prefetch window is suspended while the setting is on. That note's
follow-up measured why a transcoded download looked impossible: **the server runs one live
music transcode per account**, so a `protocol=http` download killed the playback session
and a playback start killed the download mid-body.

The official apps and Plexamp download at reduced quality anyway. Plex's Downloads
feature is a *server-side queue*: the item is added to a queue on PMS, the server
transcodes it as a background job into its own download cache, and the client fetches the
finished file. PMS ≥ 1.41.9 exposes this as `/downloadQueue`. Measured 2026-10-02 against
the Mac Mini (PMS 1.43.4.10903, Apple silicon) with `scripts/plex-probe/download-queue.py`
(each measurement below is one of its subcommands), the app's identity shape, the dev
token in a header.

## The API, as measured

- `POST /downloadQueue` →
  `{"MediaContainer":{"DownloadQueue":[{"id":2,"owner":1,"clientIdentifier":"…","itemCount":0,"status":"done"}]}}`.
  One queue per `X-Plex-Client-Identifier`; a second POST returns the same queue. Queue
  statuses: `deciding, waiting, processing, done, error`. There is no `DELETE /downloadQueue/{q}` (404).
- `POST /downloadQueue/{q}/add?keys=/library/metadata/{rk}&protocol=http&directPlay=0&directStream=0&mediaIndex=0&partIndex=0&musicBitrate=128&X-Plex-Client-Profile-Extra=add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=mp3&audioCodec=mp3)`
  → `{"MediaContainer":{"AddedQueueItems":[{"key":"/library/metadata/564","id":6}]}}`. The
  decision parameters are the universal transcoder's (`musicBitrate`, `protocol`,
  `directPlay`, `directStream`, `mediaIndex`, `partIndex`, `peakBitrate`, `hasMDE`, …).
  The profile extra worked in the query; the header was only tried with the identity that
  fails anyway (below). Several `keys` per add is in the spec, untested.
- `GET /downloadQueue/{q}/items` and `GET /downloadQueue/{q}/items/{id}` →
  `DownloadQueueItem {id, queueId, key, status, error?, DecisionResult, transcode?}`.
  Item statuses: `deciding, waiting, processing, available, error, expired`.
  `DecisionResult` carries `generalDecisionCode/Text`, `directPlayDecisionCode/Text`,
  `transcodeDecisionCode/Text`. While processing, `transcode` is a session object:
  `{progress, speed, context: "static", container: "mp3", audioCodec: "mp3", complete}`.
- `GET /downloadQueue/{q}/item/{id}/media` (singular `item`) → the file.
  `application/octet-stream`, `Content-Length`, `Accept-Ranges: bytes`, `206` on a
  `Range`. The server reads it from
  `~/Library/Caches/PlexMediaServer/Transcode/Downloads/{id}/{id}.mp3` (server pref
  `DownloadsTempDirectory`: "where transcoded downloads are stored until the client
  downloads them"). 6.9 MB came back in well under a second on the LAN.
- `GET /downloadQueue/{q}/item/{id}/decision` answered `null` for an errored item;
  untested on a good one. `POST /downloadQueue/{q}/items/{id}/restart` exists, untested.
- `DELETE /downloadQueue/{q}/items/{id}` → 204.
- Everything accepted the token and the identity as **headers**: this is a `URLSession`
  path, not AVPlayer, so nothing has to ride the query.

### Findings

1. **The identity has to have a client profile.** The dev CLI identity (`X-Plex-Platform:
   macOS`, `X-Plex-Device: CLI`, product `ctunes-dev`) failed every add at once with
   `status: error, error: decisionError`, `DecisionResult 2004 "Could not construct
   decision request"`, whatever the parameters (profile extra in header or query, HLS or
   http target, `directPlay=1`, a `path`/`session` pair). The app's own identity
   (`iOS` / `ctunes` / `iPhone`, which is what `PlexIdentity` defaults to) with the same
   profile extra the streaming path sends went `processing → available`. Any live test or
   probe of this needs an iOS-shaped identity, not the CLI's.
2. **It never touches the live transcoder.** The job runs with `context: "static"` and
   never appears in `/transcode/sessions`. A queued 416 s track finished in 5.4 s while a
   live HLS session for another track was serving segments, and that session's segments
   kept coming (`200`, ~28 KB each, no empty bodies) during and after the job. Starting the
   HLS session *while* the job was processing: same. **This is the way around the
   one-live-transcode rule.**
3. **The queue is sequential.** Three items added together went
   `processing / waiting / waiting`, one at a time, never two processing. About 5 s each
   for a 7-minute 320 kbps MP3 source, so roughly 80× real time on this server; a
   12-track album is about a minute of server time, with the first track ready in seconds.
4. **MP3 only.** `container=mp4|m4a&audioCodec=aac` targets came back byte-identical to
   the MP3 ask, the same as `protocol=http` on the live transcoder (always-transcode.md).
   ID3v2.4 with a single `TSSE Lavf60.16.100` frame, no title or artist tags. CoreAudio
   decodes it (`afinfo`: 22.31 s, 854 packets, VBR).
5. **`musicBitrate` is a bandwidth cap and the MP3 is VBR under it.** Server log:
   "Calculated bandwidth of 320kbps exceeds bandwidth limit. Changing decision parameters
   provided by client to fit bandwidth limit of 128kbps". A sparse 22 s FLAC: cap 128 →
   81 kbps average (most frames 80), cap 192 → 100, cap 320 → 144. A dense 416 s 320 kbps
   MP3 source: cap 128 → 6.87 MB (132 kbps), cap 320 → 13.1 MB (253 kbps). The label
   should say "up to".
6. **The server's own decision can hand back the original.** `directPlay=1&directStream=1`
   with no `musicBitrate` → `"Direct play OK."` and `/media` serves the original bytes
   (16.7 MB `ID3\x03` for the MP3, `fLaC` for the FLAC) in 0.1 s, no transcode. With a cap
   it compares the source's bitrate to the cap: the 320 kbps MP3 "requires 321kbps and
   only 320kbps is available" and is re-encoded at cap 320; the FLAC "requires 430kbps".
   So one add can mean "the original if it fits under the cap, else MP3 under it", but a
   cap meant to keep 320 kbps MP3s as they are has to sit a little above 320.
7. **Retention.** An `available` item was still served 45 s later, the longest wait tried; how long it lasts is in
   `Open questions`. `expired` is a status, so the client has to handle it either way.
8. Clean-up is explicit: items stay listed until deleted. Nothing in the probes was left
   behind; the queue itself (`itemCount: 0`) persists under the client identifier.

### Open questions

- **Plex Pass.** The official Downloads feature requires a Plex Pass on the *downloading*
  account. Whether the raw API refuses a token without one is unmeasured (this account has
  one). A TestFlight tester without a Pass may get an error on add, which is one reason to
  keep the original-file fetch as the fallback.
- How long `available` lasts; what `expired` looks like on `/media`.
- Several `keys` in one add; whether an album key expands to its tracks; `restart`.
- The remote and relay connections (same API, not measured).
- Whether a queue item survives a server restart (the queue did).

## Ideas

### 1. The server's download queue (recommended)

A `DownloadQuality` setting beside `StreamQuality`: `original` or a cap. When it is a cap,
every cache and pin fetch goes through the queue (add → poll → fetch `/media` → delete)
instead of `GET /library/parts/…`, and the server does the transcoding on its own clock.

Where it lands:

- `TrackSource` grows the quality, and the cache path a suffix for anything but the
  original: `<server>/<id>-<stamp>-q128.mp3`. The extension is the container the item's
  `transcode` reported, or the part's own when the decision was direct play (finding 6),
  since AVFoundation sniffs by extension. `PlexPart.cacheKey` stays as it is for originals.
- `TrackCache.localURL(server:part:)` accepts any variant of the part, pinned root first,
  the asked quality first and anything else after: a file on disk at 128 is still a file
  on disk, and offline it is the only one there is.
- Integrity: `/media` sends `Content-Length`, so `fetchOnce`'s check works unchanged, but
  the `part.size` fallback must not apply to a transcoded file; only
  `expectedContentLength` counts for it.
- The pump: `fetchOnce` for a transcoded source becomes add → poll (`waiting`,
  `processing`; 1 s; a ceiling of ~60 s before it counts as failed) → download → delete.
  One item in flight matches the server's own sequencing. Adding the whole window or pin
  queue up front would let the server work ahead while the phone downloads, at the cost
  of `retain` having to delete the queue items it drops; start with one, measure.
- `error` is a failed fetch (the existing backoff), `expired` re-adds, a refusal that looks
  like a Plex Pass gate falls back to the original fetch once and says so.
- The prefetch window while streaming transcoded can come back on, at the download
  quality: the reason it was suspended was original-size downloads behind a transcode.
  Then the second play of a track on cellular is local too.
- Stream quality and download quality stay separate settings: downloads mostly happen at
  home. Pins default to `original` to match today; a pinned album at 128 that is wanted at
  original is Remove + Download, no in-place upgrade.
- `OfflineStore.inventory` already counts files, not sizes, so partial/complete is right;
  the Storage page's byte figures are whatever is on disk.

Costs: PMS ≥ 1.41.9 (older servers fall back to the original), the Plex Pass question,
MP3 rather than AAC, and a few hundred lines in `TrackCache` plus the setting.

### 2. Progressive transcode download, serialized with playback

`universal/start?protocol=http` with the MP3 target, as measured in always-transcode.md,
plus a scheduling rule: the pump runs transcoded downloads only while nothing is streaming
transcoded, and the player cancels an in-flight one before it starts a transcoded stream.
Works on any PMS version and dodges the Plex Pass question. Costs: downloads pause while
listening on cellular; a chunked body with no `Content-Length`, so integrity has to be
"closed cleanly and decodes" (open it with `AVAudioFile` before keeping it); the race the
note saw once, where a download started beside a live transcode came back with the wrong
bytes. The fallback if idea 1 turns out to be Pass-gated.

### 3. Capture while streaming

An `AVAssetResourceLoaderDelegate` proxy over the HLS stream: the segments already being
fetched for playback are written to disk, and after a full play they are stitched (TS
concatenation is valid) and served back through the same custom scheme as a local
playlist, since AVFoundation plays TS only inside HLS. Zero extra bytes and zero extra
server work. Costs: the fragile design `notes/track-cache.md` already rejected once; it
only helps tracks played to the end and does nothing for pins; and the stall, end-of-item
and reload logic that today watches AVPlayer's own loading would all route through the
proxy. At most a later optimisation of the play cache on top of idea 1.

## Recommendation

Idea 1, with idea 2 held as the fallback if the Plex Pass gate turns out to apply to the
raw API. The two share the cache-side work (the quality suffix, `localURL` over variants,
the integrity rule), so starting on that side commits to neither.
