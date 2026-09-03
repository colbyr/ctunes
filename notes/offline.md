# Offline tunes: pinned albums and favorites, browse from a snapshot when the server is gone

## Context

`TrackCache` (`notes/track-cache.md`) keeps played and upcoming tracks under `Caches/Tracks`,
purgeable by iOS and LRU-evicted at 2 GB. It makes a replay cheap but promises nothing: the
system can sweep it, and nothing in the app knows which albums are on disk. Every browse
screen refetches in `.task` (`MusicView.swift:157`, `TracksView.swift:100`,
`MixBuilderView.swift:273`), `AppModel.connect()` (`AppModel.swift:153`) lands in
`.connectFailed` the moment discovery throws, and `ConnectFailedView`
(`ContentView.swift:37`) offers "Try again" or "Sign out". With the server unreachable the
app is a dead end even when the whole album you want is sitting in the cache. Both
`notes/track-cache.md` (follow-ups) and `notes/launch.md` (deferred, "would justify a Pro
IAP") already name this as the next step.

Decisions made up front:

- **Pins are albums and the favorites set.** A Download button on the album page; a "Keep
  favorites offline" toggle that follows the favorites set as it changes.
- **The full library browses offline.** The normal grid, search, sort and grouping work from
  a persisted snapshot; albums that aren't downloaded are dimmed and unplayable.
- **Foreground-only downloads.** No background `URLSession`, no app delegate. Downloads run
  while the app is open or playing audio, which is when the process is alive anyway.
- **Pinned files live in a separate, uncapped, non-purgeable store** under Application
  Support, excluded from backup, never touched by the LRU cache.

Goals: pin an album or the favorites and have it play with no server; browse, search, sort
and group offline; come back online in place without losing the navigation stack or the
queue; nothing about the existing player or cache gets less reliable. Non-goals for v1:
background downloads, resumable downloads, byte-level progress, offline heart toggles,
artist portraits offline, a settings screen.

## Approach

**One pump, two roots.** `TrackCache` grows a second directory, `pinnedDirectory`, and a pin
queue behind the existing window queue; the single sequential pump serves the window first,
then pins, so the next track is always ahead of a 40 MB album download. `localURL` checks
the pinned root, then the cache root, and stays synchronous, so `AudioPlayer.loadCurrentItem`
keeps its shape. A file that is already in the cache root gets renamed into the pinned root
when pinned, never fetched twice; unpin renames it back and lets LRU get to it.

**`OfflineStore` owns what the cache deliberately doesn't.** A new PlexKit actor holds the
manifest (pinned albums, favorites toggle), per-pinned-album track lists, the library
snapshot and album art. It never downloads audio itself; it hands `TrackSource`s to the
cache and reads the file system for status.

**Snapshot as the existing Codable DTOs.** The section's albums, artists, favorites and
sections are written as JSON of `PlexAlbum` and friends, which gain `Encodable`. Per-track
download state is never persisted: the file system is truth, as in the cache.

**One library type for views.** A `LibrarySource` protocol that `PlexLibrary` already
satisfies and a new `OfflineLibrary` (a value over the snapshot and the store) also
satisfies. `AppModel.library` and `AudioPlayer.library` become `(any LibrarySource)?` and
the ten fetch sites compile unchanged.

**`.offline` is a peer of `.signedIn`, rendered by the same view.** `ContentView` shows
`LibraryView` for both under one `case` label, so entering and leaving offline never
rebuilds the stack or stops playback.

Alternatives considered and dropped:

- **A separate download actor with its own session and pump.** Two pumps means two
  connections competing with the stream, or one shared session where a pinned FLAC blocks the
  next-track prefetch behind it. "Window first" has to be decided at pop time in one place,
  so it has to be one pump.
- **Pins as a flag inside the cache root that eviction skips.** Caches is purgeable by iOS
  regardless of what the app thinks. Application Support is the right home for content the
  user asked for.
- **Storing raw MediaContainer bytes for the snapshot.** No `Encodable` needed, but
  `PlexLibrary.fetch` would have to hand the bytes back and the files are roughly three times
  larger. `Encodable` costs one hand-written `encode(to:)` on `PlexAlbum` (genres go back to
  `Genre: [{tag}]`); everything else synthesizes, and `Hashable` makes round-trip tests one
  `#expect`.
- **A separate `AppModel.snapshot` read by views when offline.** Every fetch site grows an
  `if offline` branch; the protocol touches one property instead.
- **`NWPathMonitor`.** Reachability is not the question; the server answering is. Entering
  offline reacts to a failed request, leaving it reacts to a successful reconnect. A phone on
  a working Wi-Fi with the server powered off is the common case, and a path monitor says
  nothing about it.
- **Queued offline heart toggles.** Needs an outbox and conflict rules, and the favorites pin
  reconciles from the server on reconnect, which would un-pin a local-only heart anyway.
  Hearts are read-only offline.

## Changes

### 1. `Sources/PlexKit/PlexLibraryModels.swift` — Codable DTOs, `LibrarySnapshot`

`PlexSection`, `PlexArtist`, `PlexAlbum`, `PlexTrack`, `PlexMedia`, `PlexPart` and `PlexTag`
become `Codable`. Encoding synthesizes everywhere except `PlexAlbum`, whose `init(from:)`
flattens `Genre` tags into `genres: [String]`; add the mirror:

```swift
public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    // every stored field, then:
    try c.encode(genres.map(PlexTag.init), forKey: .genres)
}
```

New:

```swift
/// Everything the browse root needs with no server. Written after every
/// successful online load, read when discovery fails. Nothing secret in it:
/// `thumb` and `part.key` are server-relative paths.
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    public let server: String            // PlexServer.machineIdentifier
    public let serverName: String
    public let sections: [PlexSection]
    public let section: PlexSection
    public let albums: [PlexAlbum]
    public let artists: [PlexArtist]
    public let favorites: [PlexTrack]
    public let savedAt: Date
}
```

### 2. `Sources/PlexKit/LibrarySource.swift` — new protocol

```swift
public protocol LibrarySource: Sendable {
    var serverIdentifier: String { get }
    var isOffline: Bool { get }
    func musicSections() async throws -> [PlexSection]
    func artists(inSection section: String) async throws -> [PlexArtist]
    func albums(inSection section: String) async throws -> [PlexAlbum]
    func albums(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexAlbum]
    func tracks(inAlbum albumRatingKey: String) async throws -> [PlexTrack]
    func tracks(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexTrack]
    func favoriteTracks(inSection section: String) async throws -> [PlexTrack]
    func setFavorite(_ ratingKey: String, _ favorite: Bool) async throws
    func reportTimeline(_ track: PlexTrack, state: PlaybackState, time: Double, sessionIdentifier: String) async throws
    func streamURL(for track: PlexTrack) -> URL?
    func trackSource(for track: PlexTrack) -> TrackSource?
    func artworkURL(_ thumb: String?, size: Int) -> URL?
}
```

`PlexLibrary` conforms in an extension with `public nonisolated var isOffline: Bool { false }`.
Its `streamURL`, `trackSource`, `artworkURL` and `serverIdentifier` are already `nonisolated`,
which is what lets an actor satisfy the synchronous requirements. `PlexError` gains
`case offline`.

### 3. `Sources/PlexKit/TrackCache.swift` — pinned root, pin queue, events

```swift
public actor TrackCache {
    public nonisolated let directory: URL          // Caches/Tracks, LRU
    public nonisolated let pinnedDirectory: URL    // Application Support/…/Offline/Tracks, uncapped
    public init(directory: URL, pinnedDirectory: URL, limit: Int = 2 << 30, session: URLSession)

    /// Pinned root first, then the cache. Still synchronous, still stats the disk.
    public nonisolated func localURL(for source: TrackSource) -> URL?
    public nonisolated func localURL(server: String, part: PlexPart) -> URL?
    public nonisolated func isPinned(server: String, part: PlexPart) -> Bool
    public func touch(server: String, part: PlexPart)
    public func evict(server: String, part: PlexPart)

    /// Appends to the pin queue behind the window. A file already in the
    /// cache root is renamed into the pinned root, never fetched twice.
    public func pin(_ sources: [TrackSource])
    /// Drops the pin: cancels an in-flight fetch, or renames the file back
    /// into the cache root where LRU will reach it eventually.
    public func unpin(_ paths: [String])
    public func pinnedUsage() -> Int
    public func clearPinned()
    public func clear(keeping: String? = nil)          // cache root only, keyed by cachePath

    public enum Event: Sendable { case started(String), finished(String), failed(String) }
    public nonisolated var events: AsyncStream<Event>
}
```

Internals:

- `pinned: Set<String>` (wanted pinned paths) and `pinQueue: [TrackSource]` sit beside
  `window` and `pending`. The pump loop becomes `while let next = pending.first ?? pinQueue.first`,
  popping from whichever it came from. A `retain` arriving mid-pin just pushes the window
  ahead of the queue; nothing needs cancelling.
- **`retain(window:)` must stop cancelling pin fetches.** Today it cancels every in-flight
  task outside the window (`TrackCache.swift:64`). The predicate becomes
  `!window.contains(path) && !pinned.contains(path)`, or every cursor move would kill the
  album download in progress.
- `fetchOnce` picks the destination root: `pinned.contains(path) ? pinnedDirectory : directory`,
  so a track that is both in the window and pinned lands in the pinned root on its first
  fetch. `evictIfNeeded` keeps scanning `directory` only.
- `pin` for a source with a file already under `directory`: `moveItem` into the pinned root
  (same volume, a rename), then emit `.finished`. `unpin` is the reverse with the mtime left
  alone, so the file is the oldest LRU candidate.
- Events go through one `AsyncStream.Continuation` held by the actor with
  `bufferingPolicy: .unbounded`; a consumer that isn't listening yet loses nothing.
- `pinnedDirectory` is created with `isExcludedFromBackup = true` and files get the same
  `completeUntilFirstUserAuthentication` protection as the cache.
- `localURL(for: TrackSource)`, `touch(_:)` and `evict(_:)` become thin wrappers over the
  `(server:part:)` overloads, which is what the player uses when `trackSource` is nil offline.

### 4. `Sources/PlexKit/OfflineStore.swift` — new actor

Owns the manifest and the snapshot; drives the cache's pin queue.

```swift
public actor OfflineStore {
    public init(directory: URL, cache: TrackCache, session: URLSession = .shared)

    // Pins
    public func pinAlbum(_ album: PlexAlbum, tracks: [PlexTrack], art: URL?,
                         sources: @Sendable (PlexTrack) -> TrackSource?)
    public func unpinAlbum(_ ratingKey: String)
    public func setFavoritesPinned(_ enabled: Bool)
    /// Replaces the favorites group with `tracks`: new keys enqueue, dropped
    /// keys unpin unless a pinned album still references the file.
    public func setFavorites(_ tracks: [PlexTrack], sources: @Sendable (PlexTrack) -> TrackSource?)
    /// Re-enqueues every pinned track with no file yet. Called on connect and
    /// on foreground, since nothing survives the app being suspended.
    public func resume(sources: @Sendable (PlexTrack) -> TrackSource?)
    public func statuses() -> [String: AlbumStatus]          // by album ratingKey
    public func pinnedAlbumKeys() -> Set<String>
    public func favoritesPinned() -> Bool
    public func usage() -> Int                               // tracks + art

    // Snapshot
    public func save(_ snapshot: LibrarySnapshot) throws
    public func snapshot(server: String, section: String) -> LibrarySnapshot?
    public func tracks(inAlbum ratingKey: String) -> [PlexTrack]?
    public func favoriteTracks() -> [PlexTrack]
    public nonisolated func artURL(_ thumb: String?) -> URL?

    public func clear()
}

public enum AlbumStatus: Sendable, Equatable {
    case pending(done: Int, total: Int)
    case complete
    /// Every fetchable track is down; `undownloadable` have no `cacheKey`.
    case partial(undownloadable: Int)
}
```

Layout under `Application Support/ctunes/Offline/`:

```
Tracks/<server>/<partId>-<stamp>.<ext>      the cache's pinned root
<server>/manifest.json                      Manifest
<server>/<section>/library.json             LibrarySnapshot
<server>/<section>/albums/<ratingKey>.json  [PlexTrack] for each pinned album
<server>/<section>/art/<id>-<stamp>.jpg     album covers for pinned albums
```

```swift
struct Manifest: Codable {
    var albums: [String: PinnedAlbum]   // ratingKey → title, section, pinnedAt
    var favoritesPinned: Bool
    var favoriteKeys: [String]          // track ratingKeys in the favorites group
}
```

Reference counting is derived, not stored: a file is wanted while any album group or the
favorites group lists a track with that `cachePath`. `unpinAlbum` computes the set still
wanted after removal and unpins the difference. `statuses()` checks
`cache.localURL(server:part:)` per track; a track whose part has `cacheKey == nil` counts as
undownloadable and never blocks `.partial`.

`pinAlbum` also saves the cover. The app builds `artworkURL(thumb, size: 600)` (it carries
the token) and passes it as `art`; the store writes the bytes to `art/<id>-<stamp>.jpg`,
named from the thumb path's last two segments the way `cacheKey` is. This goes through the
store's own session, not the pump: one small request per album, nothing worth serialising.
`artURL(_:)` is `nonisolated` path math plus `fileExists`.

Sources for a pin are resolved by the app through `library.trackSource(for:)`, so the token
rides in a header and is never written down. `resume` rebuilds them from the stored
`[PlexTrack]` on the next connect. Offline, nothing needs a request.

### 5. `Sources/PlexKit/OfflineLibrary.swift` — new `LibrarySource`

```swift
public struct OfflineLibrary: LibrarySource {
    public init(snapshot: LibrarySnapshot, store: OfflineStore)
    public var isOffline: Bool { true }
    // albums / artists / sections / favoriteTracks: straight from the snapshot
    // tracks(inAlbum:): store.tracks(inAlbum:) ?? []
    // tracks(forArtist:): pinned albums' tracks plus favorites with that grandparentRatingKey
    // albums(forArtist:): snapshot.albums.filter { $0.parentRatingKey == key }
    // setFavorite: throws PlexError.offline
    // reportTimeline: no-op
    // streamURL: nil; trackSource: nil (the player resolves by server + part)
    // artworkURL: store.artURL(thumb)
}
```

Mixes therefore work offline over downloaded tracks only: the pool shows every artist and
album from the snapshot, and the existing "nothing to play" alert covers an empty union.
Listeners live in UserDefaults and need nothing.

### 6. `App/ctunes/ContentView.swift` — wire the stores, one branch for two states

Build the shared pieces once:

```swift
init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "ctunes/Offline")
    let cache = TrackCache(
        directory: caches.appending(path: "Tracks"),
        pinnedDirectory: support.appending(path: "Tracks"),
        session: AudioPlayer.downloadSession()   // the 1-connection config, moved out of init
    )
    let store = OfflineStore(directory: support, cache: cache)
    _player = State(initialValue: AudioPlayer(cache: cache))
    _model = State(initialValue: AppModel(offline: store))
}
```

`switch model.state` gets `case .signedIn, .offline: LibraryView(model: model)` under one
label; two labels would be two view identities and the stack would reset on every
transition. Add `@Environment(\.scenePhase)`: on `.active` while `.offline` call
`model.reconnect()`, while `.signedIn` call `model.resumeDownloads()`. The sign-out hook runs
`model.clearOffline()` after `player.signOut()`. `.onChange(of: model.libraryGeneration)`
calls `player.adopt(model.library)` so a queue that started offline reports timelines once
the server is back.

### 7. `App/ctunes/AppModel.swift` — `.offline`, snapshot, reconnect

```swift
enum State: Equatable { case loading, signedOut, linking(code:), connecting, connectFailed, signedIn, offline }
private(set) var library: (any LibrarySource)?
/// Bumped whenever `library` is replaced, so screens re-run their `.task`.
private(set) var libraryGeneration = 0
private(set) var reconnecting = false
let downloads: Downloads                      // §8
private let offline: OfflineStore
private static let serverDefaultsKey = "last-server-id"
private static let favoritesPinKey = "keep-favorites-offline"
```

- `connect()`: the happy path is unchanged, plus UserDefaults remembers
  `server.machineIdentifier`, and on success `Task { await offline.resume(sources: library.trackSource) }`
  and `syncFavoritesPin()`. On throw: if already `.offline`, stay there (the banner shows the
  error); else if `offline.snapshot(server: lastServer, section: savedSection)` exists,
  `enterOffline(snapshot)`; else `.connectFailed` as today. `#if DEBUG`
  `CTUNES_DEV_OFFLINE=1` skips discovery and goes straight to the snapshot branch.
- `enterOffline(_:)`: `library = OfflineLibrary(...)`, `sections`, `selectedSection` and
  `serverName` from the snapshot, `libraryGeneration += 1`, `state = .offline`.
- `reconnect()`: `connect()` without passing through `.connecting`, throttled to once per
  30 s unless tapped, `reconnecting` for the banner spinner. Success sets `.signedIn` in place.
- `connectionLost(_ error: Error)`: called by `MusicView` and `TracksView` when a fetch
  throws a `URLError` while `.signedIn`; enters offline if a snapshot exists, otherwise does
  nothing (today's behaviour).
- `snapshot(albums:favorites:)`: called by `MusicView` after its load when
  `library.isOffline == false`; fetches `artists(inSection:)` and saves a `LibrarySnapshot`,
  then `setFavorites` if the pin is on. Keyed by section, so switching libraries snapshots
  each on first browse.
- Favorites: `isFavoritesPinned` from UserDefaults; `setFavoritesPinned(_:)` writes it,
  tells the store, and on enable fetches favorites and pins them. `toggleFavorite` gains
  `guard let library, !library.isOffline`; after a successful server write, when pinned, a
  new favorite is added to the group and an un-hearted one removed. The full refetch-and-diff
  runs only on connect, which also catches hearts set from other clients.
- `signOut()` handles `.offline` (keychain only, works without a server) and calls
  `await offline.clear()`.

### 8. `App/ctunes/Downloads.swift` — new `@MainActor @Observable` mirror

```swift
@MainActor @Observable final class Downloads {
    private(set) var statuses: [String: AlbumStatus] = [:]
    private(set) var pinnedAlbums: Set<String> = []
    private(set) var usage = 0
    func status(_ album: PlexAlbum) -> AlbumStatus?
    func isDownloaded(_ album: PlexAlbum) -> Bool
    func isDownloaded(_ track: PlexTrack) -> Bool     // cache.isPinned(server:part:), sync
    func pin(_ album: PlexAlbum, tracks: [PlexTrack], library: any LibrarySource)
    func unpin(_ album: PlexAlbum)
    func removeAll()
}
```

Owned by `AppModel`, reads `cache.events` in one long-lived `Task` started at init and
refreshes `statuses` and `usage` from `store.statuses()` on each event and after every pin
or unpin. Views read `model.downloads`.

### 9. `App/ctunes/AudioPlayer.swift` — library indirection

- `init(cache: TrackCache)`; the session config moves to `static func downloadSession() -> URLSession`.
- `private var library: (any LibrarySource)?`; `play`, `playNext`, `addToQueue` and
  `enqueue` take `library: any LibrarySource`. Add `func adopt(_ library: (any LibrarySource)?)`.
- `loadCurrentItem` (`AudioPlayer.swift:312`):

```swift
guard let track = currentTrack, let library, let part = track.part else { return }
let local = cache.localURL(server: library.serverIdentifier, part: part)
guard let url = local ?? library.streamURL(for: track) else { return }
```

`touch` and `evict` (`:321`, `:363`) use the `(server:part:)` overloads. `itemFailedToLoad`
is otherwise unchanged: the stream retry and the `-1005` path only ever ran with a stream
URL, and offline there is none, so a bad pinned file evicts and advances. `clearCache()`
passes `keeping: cachePath` and never touches the pinned root. `prefetch()` still uses
`library.trackSource`, which is nil offline; an empty window is fine now that `retain`
leaves pins alone.

### 10. Views

**`App/ctunes/Views/TracksView.swift`.** A fifth circular button in `actions`
(`TracksView.swift:170`), leading position:

```swift
DownloadButton(status: model.downloads.status(album)) { toggleDownload() }
```

`arrow.down.circle` when not pinned; a ring from `done / total` while pending
(`Circle().trim(from: 0, to: fraction).stroke`, about ten lines); `checkmark.circle.fill`
when complete; a partial glyph plus a footnote "N tracks can't be downloaded" under the
header. Tapping a pinned album opens a confirmation dialog, "Remove download". Disabled
while offline. Rows show `arrow.down.circle.fill` in `.secondary` before the duration when
`model.downloads.isDownloaded(track)`. Offline, a row without a file is dimmed and its tap
does nothing. The `.task` becomes `.task(id: model.libraryGeneration)` and reports a
`URLError` to `model.connectionLost`. The heart swipe is hidden offline.

**`App/ctunes/Views/MusicView.swift`.** `OfflineBanner` as the first row when
`model.state == .offline`: `network.slash`, "Offline, playing downloaded music", trailing
"Try again" (spinner while `model.reconnecting`), card chrome like `ShuffleFavoritesCard`.
`AlbumTile` gets `.opacity(offline && !downloaded ? 0.35 : 1)` and, when downloaded, a small
`arrow.down.circle.fill` badge on the art corner. `@AppStorage("albumDownloadedOnly")` filters
`albums` before `AlbumBrowse.groups` and `search`, so the pure functions stay pure.
`shuffleFavorites` works offline because `favoriteTracks` reads the snapshot; filter to
`downloads.isDownloaded` when offline so an unplayable track never enters the queue. Menu:
`Toggle("Keep favorites offline")`, a disabled "Downloads: 1.2 GB" line, "Remove all
downloads" (destructive, confirmed), and the existing item renamed "Clear cached tracks (…)"
so the two are not confused. `.task` gains `id: model.libraryGeneration` and calls
`model.snapshot(albums:favorites:)`.

**`App/ctunes/Views/AlbumBrowserControls.swift`.** The arrange menu gains
`Toggle("Downloaded only", systemImage: "arrow.down.circle")` under the pickers.

**`NowPlayingView.swift`**: heart disabled when `model.library?.isOffline == true`.
**`MixBuilderView.swift`**: `.task(id: model.libraryGeneration)`; album tiles dim like
`AlbumTile` when offline.

### 11. `App/ctunes/ImageLoader.swift` — file URLs

`OfflineLibrary.artworkURL` returns `file://` URLs. `URLSession` can load those, but make it
explicit and skip the URLCache: `url.isFileURL ? try? Data(contentsOf: url) : session.data(from:)`.
`Artwork` is unchanged. The stored 600 px cover serves every size offline; `Artwork` already
crops with `.fill`.

### 12. Tests

`Tests/PlexKitTests/OfflineStoreTests.swift` (new), temp directories per test,
`MockURLProtocol.session`, the `Counter` and `source(id:)` helpers from `TrackCacheTests`
lifted into a shared `TrackCacheTestSupport.swift`:

- `PlexAlbum` round trip with genres; a `LibrarySnapshot` built from the `albums`, `artists`
  and `tracks` fixtures survives `save` → `snapshot(server:section:)` equal.
- The encoded snapshot and manifest contain no `X-Plex-Token` and no absolute URL.
- `pinAlbum` enqueues in track order; files land under the pinned root; `localURL` returns
  them; the cache root's `usage()` stays zero.
- A track already in the cache root is renamed on pin: handler count 0.
- Window before pins: `retain` after `pinAlbum` with a slow handler; the request log shows
  the window key next.
- `retain(window:)` does not cancel an in-flight pin.
- Eviction with `limit: 0` leaves the pinned root alone.
- `unpinAlbum` moves files back to the cache root; a track also in the favorites group stays.
- `setFavorites([a, b])` then `[b, c]`: `a` unpinned, `c` fetched, `b` untouched.
- `statuses()`: complete; partial with a nil-`cacheKey` part; pending counts.
- Failure memo: a 500 on one track leaves the album `.pending(done: n-1)`, and `resume`
  after the backoff re-requests it.
- `OfflineLibrary.tracks(inAlbum:)` and `tracks(forArtist:)` over two pinned albums plus
  favorites; `streamURL` nil; `setFavorite` throws `.offline`.
- `clear()` empties both the manifest and the pinned root.

`Tests/PlexKitTests/TrackCacheTests.swift`: `makeCache` takes the new init; existing cases
unchanged.

### 13. Debug hooks and docs

`CLAUDE.md` table:

| Variable | Effect |
|---|---|
| `CTUNES_DEV_OFFLINE` | `1` skips discovery and opens the last snapshot as if the server were unreachable |
| `CTUNES_DEV_PIN` | `1` pins the `CTUNES_DEV_ALBUM` album once its tracks load; `favorites` turns on "Keep favorites offline" |

Also: the Architecture paragraph on `TrackCache` (two roots, one pump, window first), the
`.offline` state in the Flow section, an M9 row in `PLAN.md`, and the deferred list in
`notes/launch.md`.

## Files

- `Sources/PlexKit/PlexLibraryModels.swift` — `Codable`, `PlexAlbum.encode(to:)`, `LibrarySnapshot`
- `Sources/PlexKit/LibrarySource.swift` — new protocol, `PlexLibrary` conformance
- `Sources/PlexKit/PlexError.swift` — `.offline`
- `Sources/PlexKit/TrackCache.swift` — pinned root, pin queue, `(server:part:)` overloads, events
- `Sources/PlexKit/OfflineStore.swift` — new
- `Sources/PlexKit/OfflineLibrary.swift` — new
- `App/ctunes/ContentView.swift` — construction, one branch for `.signedIn` / `.offline`, scene phase, sign-out
- `App/ctunes/AppModel.swift` — `.offline`, snapshot, reconnect, favorites pin
- `App/ctunes/Downloads.swift` — new mirror
- `App/ctunes/AudioPlayer.swift` — `any LibrarySource`, overloads, `adopt`
- `App/ctunes/ImageLoader.swift` — file URLs
- `App/ctunes/Views/TracksView.swift`, `MusicView.swift`, `AlbumBrowserControls.swift`, `NowPlayingView.swift`, `MixBuilderView.swift`
- `Tests/PlexKitTests/OfflineStoreTests.swift` — new; `TrackCacheTests.swift` — init
- `CLAUDE.md`, `PLAN.md`, `notes/launch.md`

## Phasing

Each step ends somewhere shippable.

1. **Pins while online** (PlexKit ~350 lines, app ~200, tests ~150). §3, §4 minus the
   snapshot, §8, the §9 overloads, the `TracksView` button and row glyphs, the menu lines,
   `CTUNES_DEV_PIN`. Shippable: a pinned album plays from disk and survives cache eviction
   and relaunch.
2. **Offline browse** (PlexKit ~250, app ~300, tests ~100). §1, §2, §5, the snapshot half of
   §4, §6, §7, the `MusicView` banner and dimming, `.task(id:)` on three screens, §11,
   `CTUNES_DEV_OFFLINE`. Shippable: kill the server, relaunch, browse and play pinned
   albums, reconnect in place.
3. **Favorites pin** (PlexKit ~80, app ~120, tests ~60). `setFavorites`, the toggle,
   reconcile on connect and on heart, offline Shuffle Favorites over pinned favorites,
   hearts read-only offline.
4. **Artwork and polish** (PlexKit ~60, app ~120). Cover at pin time, `artURL`, the
   "Downloaded only" filter, mix pool dimming, partial badge copy, docs.

## Verification

1. `make test` green with the new suite, still no network or simulator.
2. `make sim-run` with `CTUNES_DEV_TOKEN`, `CTUNES_DEV_ALBUM` and `CTUNES_DEV_PIN=1`: files
   appear under `Application Support/ctunes/Offline/Tracks/<server>/` in track order, the
   ring fills, and `Caches/Tracks` gains nothing for that album.
3. Start the pinned album with `CTUNES_DEV_AUTOPLAY=1`, then pin a second album: the server
   log shows the next-track prefetch request before the pin queue continues.
4. Play a long unpinned album past a debug-lowered limit: the pinned root is untouched.
5. Relaunch with `CTUNES_DEV_OFFLINE=1`: the grid, search and sort work; unpinned tiles dim;
   the pinned album plays; the mini player and the stack survive tapping "Try again" with
   the server back.
6. Stop the server mid-album while `.signedIn`: pinned tracks keep playing, the next screen
   load flips to the banner, the stack stays.
7. Turn on "Keep favorites offline", heart a track from Now Playing, un-heart another: one
   file appears and one moves back to `Caches/Tracks`; a track also in a pinned album stays.
8. Sign out while offline: both roots and the manifest are empty.

## Follow-ups

- Background `URLSession` so pins finish with the app suspended.
- Byte-level progress via a download delegate.
- Artist portraits and per-track art offline.
- A cellular switch for pins, once there is a settings screen.
- Snapshot refresh on a schedule rather than on each browse.
- Offline downloads as the Pro IAP tier `notes/launch.md` sketches.
