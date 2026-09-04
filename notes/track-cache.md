# Track cache: keep played tracks on disk and pre-download what's next

## Context

Every track is streamed from the server and nothing is kept. `AudioPlayer.loadItem` builds
`AVPlayerItem(url:)` from `PlexLibrary.streamURL(for:)`, which is the raw part file
(`/library/parts/1017/1746246593/file.flac?X-Plex-Token=…`), direct play, no transcode. Artwork
has a disk cache (`ImageLoader`, a `URLCache` under `Caches/Artwork`); audio has none, and
`AVPlayer` ignores `URLCache` entirely. So a replay downloads the whole file again, every track
start plays the `-1005` keep-alive roulette described in CLAUDE.md, and a flaky link stalls
mid-track. PLAN.md lists "offline caching" as out of scope; this note is the design for doing
it anyway, as M8.

Goals: a track that has been played is served from disk next time; the next few tracks in the
queue are downloaded before they're reached; a bounded amount of disk is used; nothing about
the existing player gets less reliable. Non-goals for v1: explicit "download this album",
resumable downloads, progress UI, a settings screen.

## Approach

**Whole-file downloads to disk. Play the local file when it exists, stream when it doesn't.
Pre-download the next few queue entries one at a time.** The player keeps every fallback it has
today; the cache only changes which URL goes into `AVPlayerItem`.

Alternatives considered and dropped:

- **`AVAssetResourceLoaderDelegate` write-through proxy.** A custom URL scheme, answering
  content-information requests, serving byte ranges from disk or network and writing them
  through. It's the only design that avoids fetching the currently playing track twice, and
  that's all it buys. It is famously fragile (AVFoundation's range pattern is odd, errors are
  opaque) and would be by far the largest piece of code in the app.
- **`AVAssetDownloadTask`.** HLS only. Plex serves plain files.
- **`URLCache`.** Works for artwork because `URLSession` fetches it; AVPlayer's media requests
  bypass it.
- **Background `URLSession`.** Needs a delegate, an identifier and relaunch handling, and the
  app has no `UIApplicationDelegate`. Not needed: the audio background mode keeps the process
  alive while playing, which is exactly when prefetch runs. Listed under follow-ups.

Byproducts worth knowing: cached tracks play with the server unreachable (timeline reports fail
silently, as they already do), and a local item never hits the `-1005` bug at all.

## Changes

### 1. `Sources/PlexKit/PlexLibraryModels.swift` — `TrackSource`

A value describing one downloadable file, so `TrackCache` knows nothing about Plex beyond it
and tests can build one by hand.

```swift
/// One part file the cache can fetch. `request` carries the token in a header,
/// so nothing secret ends up in a path or a URL on disk.
public struct TrackSource: Sendable, Hashable {
    public let server: String        // PlexServer.machineIdentifier
    public let part: PlexPart
    public let request: URLRequest
    public var expectedSize: Int? { part.size }
    /// "M/1017-1746246593.flac": the server id plus `part.cacheKey`; nil when
    /// the part isn't cacheable, in which case the track just streams.
    public var cachePath: String? { ... }
}

extension PlexPart {
    public var cacheKey: String? { ... }
}
```

`PlexPart.cacheKey` accepts only `/library/parts/<digits>/<digits>/<name>.<ext>` and produces
`<id>-<stamp>.<ext>`. The second segment is the file's modification stamp, so the key changes
when the file is replaced and the cache never has to revalidate (the same property
`ImageLoader` relies on for thumb URLs). Keeping the real extension matters: AVFoundation
sniffs the container by extension first. Strict parsing also settles path traversal and odd
keys. `PlexPart` gains nothing else; `size` and `container` are already decoded.

### 2. `Sources/PlexKit/PlexLibrary.swift` — `trackSource(for:)`

```swift
public nonisolated func trackSource(for track: PlexTrack) -> TrackSource?
```

Builds the URL from `part.key` like `streamURL(for:)` but without the query token, and gets the
request from `client.request(url:token:)` so the token and the identity headers ride in
headers. (`AVPlayer` can't do that; a `URLSession` download can, which is why the two paths
differ.) It has to be synchronous, since the player resolves it while choosing an item URL, so
`PlexClient.request` became `nonisolated`: it only reads the immutable identity, and every
existing call site just drops its `await`.

### 3. `Sources/PlexKit/TrackCache.swift` — new actor

Foundation only, so `make test` exercises it natively on macOS through `MockURLProtocol`.

```swift
public actor TrackCache {
    public init(directory: URL, limit: Int = 2 << 30, session: URLSession)

    /// Synchronous so the player can decide the item URL without a hop.
    /// Checks the file system every time: Caches can be purged between launches.
    public nonisolated func localURL(for source: TrackSource) -> URL?
    /// Bumps the mtime so LRU sees the play. Fire and forget from the player.
    public func touch(_ source: TrackSource)
    /// Fetches unless cached or already in flight; joins the in-flight task.
    public func download(_ source: TrackSource) async throws -> URL
    /// The set worth having on disk right now, in priority order. Cancels
    /// downloads outside it and starts the missing ones one at a time.
    public func retain(window: [TrackSource])
    public func evict(_ source: TrackSource)
    public func usage() -> Int
    public func clear(keeping: TrackSource?)
}
```

Files live at `<directory>/<server>/<cacheKey>`; the app passes `Caches/Tracks`. Caches is
right: excluded from backup for free, purgeable by iOS under pressure so the app is never blamed
for 2 GB it can't shed, and every file is re-downloadable by construction. Consequence: there is
no in-memory index treated as truth. The budget is global across servers; `usage()` and
eviction scan the root.

**Download.** `URLSession.download(for:)`: streams to disk with no per-byte loop, honours task
cancellation, and goes through the `URLProtocol` stack so the mock works. The temp URL it
returns has no lifetime guarantee, so it is moved in the same actor turn, with no `await`
between the return and `moveItem`. In order:

1. Require HTTP 200 (no `Range` header is sent, so 206 is wrong and anything else is an
   error page).
2. Compare the temp file's byte count with `expectedSize`; fall back to
   `expectedContentLength` only when `part.size` is nil. Mismatch (truncated body, HTML error
   page) deletes the temp file and throws.
3. `Task.checkCancellation()`: the actor was re-entered during the await, and `retain` or
   `clear` may have cancelled this download. The temp file is deleted on every exit.
4. Create the server directory, remove any stale destination, `moveItem` (same volume, so a
   rename, atomic), set `.completeUntilFirstUserAuthentication` protection explicitly so a
   future `.complete` entitlement can't make a lock-screen skip open an unreadable file.
5. `evictIfNeeded()`.

Join-in-flight is `ImageLoader.inFlight` on an actor: `[String: Task<URL, Error>]` keyed by
cache key. Cancellation is explicit from `retain`, never implicit from a caller giving up, the
same rule `ImageLoader` follows. One retry on `URLError.networkConnectionLost` (`-1005`),
mirroring the player, since the cache session's own idle connection is just as likely to be
dropped by the server.

**Session config**, built by the app:

```swift
config.httpMaximumConnectionsPerHost = 1
config.waitsForConnectivity = false
```

One connection because the current track is streaming through AVPlayer's own pool at the same
time and must not be starved; prefetching three tracks concurrently triples contention when
only the next one matters soon. `waitsForConnectivity` off so a phone with no route fails fast
instead of parking the pump on the first download forever. Cellular downloads are allowed:
the whole point is the next track being ready, wherever you are. Turning them off is two
lines (`allowsExpensiveNetworkAccess`, `allowsConstrainedNetworkAccess`) plus a setting, if
data use ever becomes a complaint.

**Pump.** `retain(window:)` replaces the window set, cancels in-flight tasks outside it,
rebuilds `pending` from the window minus cached and recently failed keys, and starts a single
sequential pump task if none is running. The pump pops `pending` until empty. Failures land in
`failed: [String: Date]` and are skipped for five minutes, so a dead server, a full disk or a
cellular-only phone doesn't retry on every cursor move. The pump `Task {}` is created inside the
actor and inherits its isolation; not `Task.detached`.

**Eviction.** After each completed download, list the root recursively with modification dates,
sort oldest first, delete until under `limit`, never touching a key in the window. About
fifteen lines and the most testable part of the design, so it stays in v1.

**Partial files.** `download(for:)` writes to NSURLSession's own temp directory and the OS
sweeps it; nothing is ever written under the final name until it's complete, so a file that
exists is whole. No startup sweep needed.

### 4. `App/ctunes/AudioPlayer.swift` — use it

The player owns the cache: it's the only consumer, and both live for the app (`@State` in
`ContentView`) while `PlexLibrary` is rebuilt on every connect. It exposes `clearCache()` and
`cacheUsage()` for the menu.

```swift
private let cache = TrackCache(
    directory: caches.appendingPathComponent("Tracks"),
    session: URLSession(configuration: config)
)
private let prefetchDepth = 3
```

`loadCurrentItem` resolves `library.trackSource(for:)`... except that's async, and the item
URL has to be chosen synchronously or the cursor can drift during the hop (the drift the file's
header comment exists to prevent). So the synchronous path uses only what's synchronous:
`track.part?.cacheKey` plus the server id gives `localURL`; `streamURL(for:)` is the fallback;
`trackSource` is resolved inside the fire-and-forget `prefetch()` task. Concretely:

- `loadCurrentItem`: `let url = cache.localURL(for: key) ?? library.streamURL(for: track)`,
  remember whether it was local, `touch` it in a `Task` if so, then `loadItem` as today, then
  `prefetch()`.
- `itemFailedToLoad`: when the failed item was local, `Task { await cache.evict(...) }` and
  `loadItem(url: streamURL, ...)` without counting against `maxItemLoadRetries`, so the stream
  still gets its two `-1005` retries. The existing retry and advance logic is unchanged.
- `prefetch()`: window is `upcoming.prefix(prefetchDepth)`, topped up from the head of the
  queue when `repeatMode == .all`, **then the current track last**. Current goes last, not
  first: it's already streaming, and a second transfer of the same bytes competes with the
  stream at the moment it needs headroom. It's only useful for the first track of a `play`
  call (every later track was prefetched before it started) and for repeat. Resolve sources
  with `trackSource(for:)` inside `Task { await cache.retain(window:) }`.
- Never swap a streaming item to the local file mid-play, even when the download finishes
  early. Next play is the hit.
- `clearCache()` passes the current track's source as `keeping:` so a file isn't unlinked
  under a playing item. `clear` also cancels every in-flight task and empties `pending`
  before removing files.

Call sites for `prefetch()`, explicit rather than a `didSet` on `queue`: `@Observable`
preserves `didSet` for assignment, but the in-place mutations (`queue.advance()`,
`queue.remove(at:)`, `mutate(&queue)`) go through the macro's `_modify` accessor, and whether
the observer runs after a coroutine yield is exactly the kind of thing CLAUDE.md warns compiles
fine and misbehaves. Every cursor move already funnels into `loadCurrentItem` (`play`,
`restart`, `advance`, `previous`, `jump`, `remove` of the current entry, the failure path), so
one call there covers those. Four more change the window without moving the cursor:
`enqueue`'s mutate branch, `toggleShuffle`, `remove` of a non-current entry, and `cycleRepeat`
(`.all` changes the wrap). Five sites in one file; the doc comment on `prefetch()` names them.

### 5. `App/ctunes/ContentView.swift` — sign-out clears the cache

`AppModel.signOut` doesn't know the player, so `ContentView` watches
`model.state` and, on `.signedIn → .signedOut`, calls `player.signOut()`: stop playback,
empty the queue, clear the lock screen, then `cache.clear()` with nothing kept. Nothing of the
account stays on the device.

### 6. `App/ctunes/Views/MusicView.swift` — one menu item

The overflow menu already holds Listeners, Change library and Sign out. Add
"Clear downloaded tracks (1.2 GB)" above Sign out, usage fetched in `.task` from
`player.cacheUsage()` and refreshed after clearing. Hidden when usage is zero.

### 7. Tests — `Tests/PlexKitTests/TrackCacheTests.swift` (new)

Temp directory per test, sources built by hand, `MockURLProtocol.session(handler:)` as the
cache session with the handler returning `Data(count: part.size)`. (It hardcodes
`Content-Type: application/json` and never sets `Content-Length`; neither matters since the
check is against `part.size`.)

- `PlexPart.cacheKey`: the fixture key → `1017-1746246593.flac`; `/library/parts/1017/file.flac`,
  a transcode path and a key with `..` → nil.
- Miss → `download` → file exists, `localURL` hits, bytes match.
- Two concurrent `download`s for one key hit the handler once.
- Body shorter than `part.size` → throws, no file left behind.
- Non-200 → throws, no file.
- `retain` with a window that drops an in-flight key cancels it and leaves no file.
- LRU: limit fits two files, three downloaded with mtimes set by hand, oldest gone; a
  window key older than the others survives.
- `clear(keeping:)` removes everything except the kept file and cancels in-flight work.
- Failure memo: a failed key isn't re-requested by a second `retain` inside the backoff.

### 8. Docs

- `CLAUDE.md` Architecture: a paragraph after the `AudioPlayer` one. Local file first, stream
  fallback, prefetch window, no cellular writes; keep the stream fallback and the `-1005` retry.
- `PLAN.md`: M8 row in the status table; drop "offline caching" from the out-of-scope list.
- `notes/launch.md`: the deferred list.

## Files

- `Sources/PlexKit/TrackCache.swift` — new
- `Sources/PlexKit/PlexLibraryModels.swift` — `TrackSource`, `PlexPart.cacheKey`
- `Sources/PlexKit/PlexLibrary.swift` — `trackSource(for:)`
- `App/ctunes/AudioPlayer.swift` — cache ownership, `loadCurrentItem`, `itemFailedToLoad`,
  `prefetch()` and its five call sites, `clearCache()` / `cacheUsage()`
- `App/ctunes/ContentView.swift` — sign-out hook
- `App/ctunes/Views/MusicView.swift` — menu item
- `Tests/PlexKitTests/TrackCacheTests.swift` — new
- `CLAUDE.md`, `PLAN.md`, `notes/launch.md`

## Verification

1. `make test`: the new suite passes alongside the rest, still no network or simulator.
2. `make sim-run` in a tmux pane with `SIMCTL_CHILD_CTUNES_DEV_TOKEN`, `CTUNES_DEV_ALBUM`
   and `CTUNES_DEV_AUTOPLAY=1`. Watch `Caches/Tracks/<server>/` in the simulator container:
   the next three tracks appear one at a time, then the first. `CTUNES_DEV_AUTOPLAY=end`
   confirms the transition lands on a local file (no range requests in the server log for
   that track).
3. Restart the app, play the same album: no `/library/parts/` requests for cached tracks.
4. Set the limit to a few files in a debug build and play through a long album: the
   directory stays bounded and the current and next tracks are never the ones removed.
5. Clear from the menu while playing: playback continues, the directory empties except for
   the current file, usage reads zero after the track ends and is evicted later.
6. Delete a cached file by hand while it's queued next: the player falls through to the
   stream URL without a stall.

## Decisions made at implementation

- **Sign-out clears the cache**, via the `ContentView` hook above.
- **Cellular downloads are on.** Options can come later.
- **The limit stays a constant.** 2 GB is roughly 70 FLAC tracks or 500 MP3s. A user-facing
  limit needs a settings screen, which the app doesn't have.

## Verified

`make test` (92 tests) green. In the simulator with `CTUNES_DEV_AUTOPLAY=1` the next three
tracks appeared in `Caches/Tracks/<server>/` one at a time in queue order, then the current
one. A second launch with `CTUNES_DEV_AUTOPLAY=end` rolled onto the cached second track with
the system log showing exactly one part request for the whole run: the new tail of the
prefetch window.

## Follow-ups

- ~~Per-album "download" pins~~ — done as a second root and a pin queue, `notes/offline.md`.
- Background `URLSession` so pins finish with the app suspended.
- Transcoded, smaller cache variants for cellular.
