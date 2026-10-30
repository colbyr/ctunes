# One library: local-first reads, the connection as a property

## Context

`notes/offline-degraded.md` (Oct 2026) found that a weak link counts as online
and that online never reads disk, and patched two screens to seed from the
saved copies. The structural problem it names is still there: online versus
offline is a **global mode decided by one probe**, while the real condition is
per request and continuous (fast, slow, dead). Everything downstream inherits
the mode:

- **Two libraries swapped whole.** `OfflineLibrary` reads only disk and
  `PlexLibrary` reads only the server; `AppModel` picks one on discovery and
  flips on failure. A degraded link gets the server-only one, so a downloaded
  album spins on the 10s timeout. Only `TracksView` and `FavoritesView` seed
  from disk, by hand.
- **Failure handling is the screens' job.** 24 call sites of
  `model.connectionLost` across the views, CarPlay, Siri and `LibraryFetches`;
  13 tasks keyed on `libraryGeneration` to run again after a swap; 26 reads of
  `library.isOffline` and 16 of `state == .offline`. Every new screen has to
  get the dance right.
- **Saved metadata is written as a side effect.** `LibrarySnapshot` is one blob
  written only when the browse root's whole load succeeds (`AppModel.snapshot`),
  track lists are saved by screens calling `rememberTracks`, and the pinned
  favorites group (`favorites.json`) and `snapshot.favorites` are two lists
  that can disagree, which is how the empty-favorites bug happened.

What holds up and stays: the two cache roots with one pump and the
window-before-pins rule (`notes/track-cache.md`, `notes/offline.md`), the
player's local-or-stream choice in `loadCurrentItem`, the stream fallback, the
`-1005` retry, the stall and silent-pause watchdogs, `waitForServer` and
`resumeOnReconnect`, and reachability decided by the server answering rather
than a path monitor. This note changes what is read and who handles a failure,
not how bytes reach `AVPlayer`.

Decisions made up front (discussed Oct 2026):

- Phases 1 and 2 below are planned together: the local-first library, and the
  connection monitor with the state collapse. The one-answer `availability(of:)`
  and the thin-pipe policy are follow-ups.
- **Writes stay refused with no server attached.** Hearts, playlist edits and
  the timeline go to the connection or throw `.offline`; queuing is a follow-up.
- **`.offline` and `.reconnecting` leave `AppModel.State`** as long as nothing
  the user can do today is lost. The checklist is in §9.
- **Revalidation floor: 60s** per key, the one knob to revisit (§2).

## Approach

**One `CachedLibrary` for the whole signed-in life**: a PlexKit actor over
`OfflineStore` (the saved copies) plus an optional `PlexLibrary` connection that
discovery attaches and detaches. There is no offline library and no swap; the
object `AppModel.library` holds changes only when the account, server or
section changes. Every read hands back the saved copy and revalidates behind
it; a failed revalidation changes nothing on screen and is reported to one
place. Screens read and re-render on a revision; they never seed from disk,
never catch a transport error, never call `connectionLost`.

```swift
public actor CachedLibrary: LibrarySource {
    public nonisolated let id: LibraryID                 // server + section
    public nonisolated var connection: PlexLibrary? { get }   // nil while nothing answers
    public nonisolated var isConnected: Bool { get }
    /// Every key whose saved copy changed, in order; the app mirrors it
    /// onto the main actor as `AppModel.libraryRevision`.
    public nonisolated let changes: AsyncStream<Key>
    /// A revalidation that failed on the transport, for the monitor.
    public var connectionFailed: (@Sendable (Error, PlexLibrary) async -> Void)?

    public func attach(_ connection: PlexLibrary)        // discovery found the server
    public func detach()                                 // nothing answers
    public func refresh(_ keys: [Key]) async             // pull to refresh, connect, a write

    public enum Key: Hashable, Sendable {
        case albums, artists, favorites, history, playlists
        case albumTracks(String), artistAlbums(String), artistTracks(String), playlistItems(String)
    }
}
```

The `LibrarySource` protocol stays as the views' type, so the fetch sites
compile unchanged; `isOffline` becomes `isConnected` on it. `PlexLibrary` keeps
conforming (the live tests and `LibraryCatalog.load` cost nothing to leave),
but nothing in the app holds one as a library again: it is the connection.

**The synchronous surface.** `streamURL`, `trackSource`, `artworkURL`,
`serverIdentifier` and `isConnected` have to answer without an actor hop (the
player picks an item URL synchronously; a hop lets the cursor move under it).
The connection is held in a `Mutex<PlexLibrary?>` (`Synchronization`, fine at
the package's platforms) read through `nonisolated` accessors, so a swap from
the monitor is one lock and every synchronous answer is the current
connection's or the disconnected fallback (the saved cover, the server URL
from `server.json` with the kept token, nil for a stream).

Alternatives considered and dropped:

- **Keep two libraries and make `OfflineLibrary` fall through to the server.**
  Halves the problem: the swap and the generation dance stay, and the online
  library still never reads disk.
- **Per-screen seeding, extended to every screen.** What the October fixes
  started. Each screen carries the disk read, the "failure leaves the list
  standing" rule and `connectionLost`; CarPlay and Siri would need the same
  three times over. The library is the one place the rule can live once.
- **Reads as `AsyncStream`s.** The fetch sites would all change shape, and
  `.task(id:)` already is the "run again when something changed" mechanism.
  A revision counter keeps the 13 sites to a one-token edit.
- **Revalidate on every read when connected.** Today's traffic, but it loops:
  the root reads five keys, the albums land and bump the revision, the root's
  task runs again and asks for the five keys again. The floor is what makes a
  re-run disk only.
- **One `library.json` kept as the store.** A single blob can only be written
  when every part landed, which is the degraded-link failure mode.

## Changes

### 1. `Sources/PlexKit/OfflineStore.swift` — per-key files

The snapshot splits into one file per request, each written only from its own
successful response. The layout grows:

    <server>/server.json                     ServerRecord: name, sections, baseURL (no token)
    <server>/<section>/albums.json           [PlexAlbum]
    <server>/<section>/artists.json          [PlexArtist]
    <server>/<section>/favorites.json        [PlexTrack]   the one favorites list (was the pin group's)
    <server>/<section>/history.json          [PlayHistoryEntry]
    <server>/<section>/playlists.json        [PlexPlaylist]
    <server>/albums/<rk>.json                [PlexTrack]   as today
    <server>/artists/<rk>.json               [PlexAlbum]   as today, now for every artist page opened
    <server>/artists/<rk>-tracks.json        [PlexTrack]   tracks(forArtist:)
    <server>/playlists/<rk>.json             [PlaylistItem] as today

Freshness is the file's modification date; no sidecar. The store gains
`save(_:for key:)`, `load(for key:)` and `savedAt(key:)` over the keys above,
with the in-memory dictionaries it already keeps for album tracks, artist
albums and playlist items extended to the section lists. Nothing per track is
persisted; the file system stays the truth for files.

**The favorites list is one list.** `favorites.json` was the pin group, written
by `setFavorites` only while the pin is on. It becomes the saved copy of
`favoriteTracks(inSection:)` whether or not the pin is on; `setFavorites`
keeps its reconcile role (which files the pinned root wants) but reads the
list from the same file. `savedFavorites()` in the model goes away.

**Migration.** The first `load` under `<server>/<section>` that finds
`library.json` and no `albums.json` splits it into the five files (dated now,
so the first read revalidates) and writes `server.json`, then removes it.
`LibrarySnapshot` stays `Decodable` for that read alone; its `Encodable` half
and `OfflineStore.save(_ snapshot:)` go. ~25 lines, one test.

`tracks(inSection:)` (every track, for a mix with nothing picked) is not
saved: a few megabytes for one rarely used page. Disconnected it answers the
pinned tracks as today. `track(ratingKey:)` is the connection's, else a search
of the saved track lists. `searchTracks` is the connection's, else
`LibrarySearch.matches` over every saved track list rather than pinned tracks
alone, which is strictly more than today.

### 2. `Sources/PlexKit/CachedLibrary.swift` — new actor

One private generic behind every list read:

```swift
private func read<T: Codable & Sendable>(_ key: Key, _ fetch: @Sendable (PlexLibrary) async throws -> T) async throws -> T {
    if let saved: T = await store.load(for: key, server: id.server) {
        if connection != nil, isStale(key) { revalidate(key, fetch) }     // detached, coalesced
        return saved
    }
    guard connection != nil else { throw PlexError.offline }
    return try await revalidate(key, fetch).value                      // a miss waits, as today
}
```

- **Stale** is `savedAt(key)` older than `revalidateAfter` (60s). A key that
  landed within the floor is disk only, which is what makes the revision
  re-run cheap and a pop back to the root free. `refresh(_:)` ignores the
  floor; it is pull to refresh, the connect, and the key a write touched.
- **Revalidate** is coalesced per key in `inFlight: [Key: Task]`, the
  `ImageLoader` rule: a caller giving up (a cancelled `.task`) never cancels
  the fetch. It uses the connection it started on; a swap mid-flight leaves
  the result valid, since it is the same server. On success it saves, bumps
  `revision` and yields the key on `changes`. On a transport failure
  (`URLError` other than `.cancelled`, `PlexError.noServerReachable`) it calls
  `connectionFailed(error, connection)` and leaves the saved copy alone. A
  decoding or HTTP error is logged and not reported: the server answered.
- **A miss with a connection awaits the fetch**, so a page never browsed
  behaves as today, including the failure: the error propagates to the
  screen, which shows what it shows now (nothing), and the monitor is told
  once. A miss with no connection throws `.offline`.
- **Writes** take the connection or throw `.offline`. `setFavorite` edits the
  saved favorites list in place first (the optimistic update
  `favoriteOverrides` does in the model today moves here), then writes, then
  `refresh([.favorites])`; a failure restores the saved list. The playlist
  writes `refresh([.playlists, .playlistItems(rk)])` after, which is what
  `playlistsChanged` does by hand now.
- `attach` swaps the connection and revalidates whatever is loaded in
  memory (the keys a screen has asked for this session) that is older
  than the floor, forgetting any failure memo, so the first seconds after
  a connect bring the screens up to date without a pull while a relaunch
  inside the floor asks for nothing: on a cold start the root reads from
  disk before discovery finishes, and forcing every loaded key there made
  every launch refetch the lot. `detach` clears the connection; nothing
  else changes, which is the point.
- `musicSections()` is the connection's, else `server.json`'s. `artworkURL`
  is the saved cover first, then the connection's URL, then the server URL
  from `server.json` with the kept token, as `OfflineLibrary.artworkURL` does.
  `reportTimeline` is a no-op without a connection. `trackSource` is nil
  without one, so the prefetch window empties offline as today.

`OfflineLibrary.swift` is deleted. The protocol's `isOffline` becomes
`isConnected`; the 26 sites flip their sense.

### 3. `App/ctunes/AppModel.swift` — open once, attach the server

- `library` is a `CachedLibrary?` behind the same `(any LibrarySource)?`
  property. It is opened by `openLibrary(server:section:)` when the account,
  server or section is known, from `server.json` with no network, and
  replaced only when one of those changes. `libraryGeneration` keeps meaning
  "a different library object"; a new `libraryRevision` bumps on every key
  landing (mirrored from `changes`) and on every generation bump, and is what
  the screens key on.
- `connect()`: with a `server.json` for the last server and a saved section,
  open the library at once and go to `.signedIn` with the connection
  `.searching`; discovery attaches. Without one, `.connecting` as today, then
  `.signedIn` or `.connectFailed`.
- `attemptConnect` on success writes `server.json`, attaches, then runs
  `resumeDownloads`, `syncFavoritesPin`, `syncPlaylistPins` as now.
- `enterOffline`, `lastSnapshot`, `snapshot(albums:favorites:history:)`,
  `savedFavorites`, `rememberTracks`, `rememberItems` and `favoriteOverrides`
  go. `loadPlaylists` reads `library.playlists()`; `playlistsChanged` is a
  `refresh`.
- A `followLibraryChanges()` loop replaces the side-effect saves: on
  `.favorites`, reconcile the pin group when it is on (today's
  `syncFavoritesPin`); on `.playlistItems(rk)` of a pinned playlist, the same
  through `setPlaylistItems`; on `.albums`, `downloads.setAlbums`. This keeps
  download policy (the quality, the sources closure) in the app.
- `connectionLost(_:)` stays as the entry the player and the monitor share
  until §7 moves it; in phase 1 the library's `connectionFailed` points at it.

### 4. Screens, CarPlay, Siri, `LibraryFetches`

Mechanical, and mostly deletions:

- `.task(id: model.libraryGeneration)` → `.task(id: model.libraryRevision)`
  (13 sites). The body is the read it already does; the seed blocks in
  `TracksView.load` and `FavoritesView.load` go, and so does every
  `do { … } catch { await model.connectionLost(error) }`: a thrown read is
  a miss that failed, and the screen keeps what it has, which is the rule
  the four screens had to add by hand in October.
- `MusicView.load` drops the `model.snapshot` call and the "keep the previous
  count" comments; `catalog` fills as before.
- `LibraryFetches` (the card, menu and intent fetches) lose their `catch`
  blocks and the favorites fallback: `tracks(of: .favorites)` is one read.
- `CarPlayController.reload` and the per-tab loads, `IntentPlayback.fetch`
  and `LibraryCatalog.load`: the same deletion. `IntentPlayback.fetch`
  becomes the bare request.
- `isOffline` → `!isConnected` across `ItemMenus`, `TracksView`,
  `FavoritesView`, `ArtistView`, `PlaylistView`, `PlaylistsView`,
  `SearchView`, `NowPlayingView`, `CarPlayController`, `IntentPlayback`,
  `Downloads` (26 sites). What they gate (writes, Download items, hearts,
  the dim of rows with no file) is unchanged.

### 5. `App/ctunes/AudioPlayer.swift`

- The five `isOffline` reads become `!library.isConnected`. The quality rule
  in `loadCurrentItem` is unchanged in substance: a local file at or above
  the streaming quality plays; a lesser copy plays when no server is
  attached; otherwise stream.
- `adopt(_:)` splits. `adopt` is for a new library object (sign-in, section
  switch) and keeps stopping or reloading as now. A new `connectionChanged()`
  is called when the monitor attaches, moves or detaches the connection: it
  does what `adopt` of an online library does today (drop the cache's failure
  backoff, `resumeOnReconnect`, reload a stalled item from the new address)
  without a library swap. `itemBaseURL` compares against
  `library.connection?.baseURL`.
- The `connectionLost` hook keeps its contract (returns whether a server
  answered) and points at the monitor in §7.

### 6. `App/ctunes/Downloads.swift`

`attach(server:offline:)` becomes `attach(server:)` plus `connected: Bool`
set from the monitor. `available` and `availablePlaylists` are computed when
disconnected as now. `settled` reads `connected`.

### 7. `App/ctunes/ConnectionMonitor.swift` — new (phase 2)

Everything in `AppModel` between `connectionLost` and `isConnectionError`
moves here, plus `discover(patience:)`, `scheduleOfflineRetry`,
`cancelOfflineRetry`, `checkConnection` and `reconnect`:

```swift
@MainActor @Observable final class ConnectionMonitor {
    enum Connection: Equatable { case connected(PlexServer), searching, unreachable }
    private(set) var connection: Connection = .searching
    var errorMessage: String?

    func start(client:token:serverID:library:)   // the library to attach to
    func failed(_ error: Error) async -> Bool    // the library's and the player's entry: probe, attach or detach
    func reconnect(force: Bool) async            // banner, offline timer, activation
    func activated() async                       // scene activation: the 3s ping on a local address
    func stop()                                  // sign out
}
```

The rules move with the code and are not changed: the stale-address check on
`failingURL`, the 15s probe throttle, the 25s patience, the 1s grace for
better-ranked probes, the 10s→60s offline retry while the process lives,
`CTUNES_DEV_OFFLINE`. `failed` ends in `library.attach(fresh)` (returns true)
or `library.detach()` and `.unreachable` (false); the same address answering
is `refresh` of the loaded keys, not a swap. `AppModel.connection` forwards
the monitor's, and `AppRuntime`'s activation hook calls `activated()`.

### 8. `AppModel.State` collapses (phase 2)

`.offline` and `.reconnecting` go; `.signedIn` plus `model.connection` is the
whole story. Site by site:

- `ContentView`: the one `case` label becomes `.signedIn` alone. The stack and
  the queue survive every connection change by construction now.
- `MusicView`: the banner shows for `.searching` (spinner, "Looking for your
  server…", no Try again, no dimming: today's `reconnecting` look, which
  finding 5 of the degraded note said showed nothing) and for `.unreachable`
  (today's banner with Try again, tiles dimmed). `model.reconnecting` goes.
- `BrowseItems`, `MixBuilderView`, `MusicView.visible…`: the dim is
  `connection == .unreachable && !hasDownloads`. Searching does not dim, as
  reconnecting does not today.
- `SettingsView`, `StorageView`: `offline` is `connection != .connected`.
- `AppRuntime.followSceneActivation`: `.offline → reconnect`, `.signedIn →
  checkConnection` becomes `monitor.activated()`, which does both by the
  connection. The `followModel` tuple carries `connection` in place of the
  two states.
- `CarPlayController`: the three-state `case` becomes `.signedIn`; its
  `offline` reads `!library.isConnected`.
- `IntentPlayback.ready()` / `AppModel.isSettled`: unsettled while
  `connection == .searching`, with the same 12s bound, so an intent fired at
  launch still waits for the server rather than playing from disk.
- `AppModel.signOut`: `monitor.stop()`, library nil, as now.

### 9. Functionality checklist for the collapse

Each is something a user can do today; each has a home after:

| Today | After |
|---|---|
| Cold start shows the snapshot at once while discovery runs | `openLibrary` from `server.json`, `.signedIn` + `.searching` |
| Banner + Try again when nothing answers | `.unreachable` banner, `monitor.reconnect(force:)` |
| Offline retries 10s→60s while audio plays | moved whole into the monitor |
| Tiles dim offline, not while reconnecting | dim on `.unreachable` only |
| Hearts, writes, Download items hidden offline | gated on `isConnected` |
| Pinned and cached files play offline | `loadCurrentItem` unchanged |
| Queue pauses in place offline, resumes on reconnect | `waitForServer`, `resumeOnReconnect`, `connectionChanged()` |
| Siri waits up to 12s at launch for the server | `isSettled` reads `.searching` |
| Foreground ping on a local address | `monitor.activated()` |
| Wi-Fi→cellular swaps the address in place | `failed` → `attach(fresh)`, same rules |
| A failure on an address already left never probes | `failingURL` check kept in `failed` |
| Sign out clears everything | `stop()` + `offline.clear()` |
| `CTUNES_DEV_OFFLINE=1` | monitor goes `.unreachable` without probing; Try again probes |

### 10. Tests

`Tests/PlexKitTests/CachedLibraryTests.swift`, `MockURLProtocol` per session,
a temp store:

- a miss with a connection fetches, saves, returns, bumps the revision;
- a fresh hit makes no request;
- a stale hit returns the saved list, makes one request, yields the key; the
  next read returns the new list with no request;
- a stale hit whose request fails returns the saved list, reports once
  through `connectionFailed`, and the saved file is unchanged;
- a miss with no connection throws `.offline`; `setFavorite` too;
- two concurrent reads of one key make one request;
- `detach` mid-flight: the result still saves;
- `setFavorite` edits the saved list before the request and restores it on
  failure;
- migration: a `library.json` becomes the five files plus `server.json`.

`OfflineStoreTests`: per-key save and load, `savedAt`, the favorites list
shared with `setFavorites`. The monitor is app code and is checked by hand
(§Verification), as `AppModel`'s version is today.

### 11. Docs and hooks

`CLAUDE.md`'s Flow paragraph is rewritten around the library and the monitor
(it currently describes the swap in detail); the Architecture line for
`OfflineStore` gains the per-key layout. `PLAN.md` gets a row. The follow-up
line in `notes/offline.md` and the "If it is still a problem" section of
`notes/offline-degraded.md` point here. No new debug hook; `CTUNES_DEV_OFFLINE`
keeps its meaning.

## Files

- `Sources/PlexKit/CachedLibrary.swift` — new
- `Sources/PlexKit/OfflineStore.swift` — per-key files, `server.json`, migration, the one favorites list
- `Sources/PlexKit/OfflineLibrary.swift` — deleted
- `Sources/PlexKit/LibrarySource.swift` — `isConnected`
- `Sources/PlexKit/PlexLibraryModels.swift` — `ServerRecord`; `LibrarySnapshot` decode-only
- `App/ctunes/AppModel.swift` — open once, attach, `libraryRevision`, `followLibraryChanges`; the connection code out
- `App/ctunes/ConnectionMonitor.swift` — new
- `App/ctunes/AppRuntime.swift`, `ContentView.swift`, `AudioPlayer.swift`, `Downloads.swift`, `LibraryFetches.swift`, `LibraryCatalog.swift`
- `App/ctunes/Views/`: `MusicView`, `TracksView`, `FavoritesView`, `ArtistView`, `PlaylistView`, `PlaylistsView`, `SearchView`, `MixBuilderView`, `BrowseItems`, `ItemMenus`, `SettingsView`, `StorageView`, `NowPlayingView`
- `App/ctunes/CarPlay/CarPlayController.swift`, `App/ctunes/Siri/IntentPlayback.swift`
- `Tests/PlexKitTests/CachedLibraryTests.swift` — new; `OfflineStoreTests.swift`
- `CLAUDE.md`, `PLAN.md`, `notes/offline.md`, `notes/offline-degraded.md`

## Phasing

Each step builds and is shippable on its own.

1. **Store split** (PlexKit ~150 changed, tests ~60). §1: per-key files,
   `server.json`, migration, the favorites list. `OfflineLibrary` reads the
   new files through the store so nothing above changes yet.
2. **The library, unwired** (PlexKit ~350 new, tests ~200). §2 and its tests.
3. **Wire it** (app, net deletions across ~20 files). §3–§6: the model opens
   a `CachedLibrary`, `OfflineLibrary` is deleted, `isOffline` → `isConnected`,
   the screens' seeds and catches go, the revision replaces the generation in
   the task keys. The `State` enum is untouched; the three cases hold the same
   library object. The reported bugs are fixed here.
4. **The monitor and the collapse** (app ~300 moved, ~100 changed). §7–§9.
5. **Docs.** §11.

Steps 1–3 are two to three days; 4 and 5 a day.

## Verification

1. `make test` green with the new suite, no network or simulator.
2. `make sim-run` with a token: the browse root lands, `albums.json` and
   its four siblings appear under `Application Support/ctunes/Offline/<server>/<section>/`
   and `library.json` is gone from a container that had one.
3. Relaunch within a minute: the root shows with no request in the server
   log; pull to refresh makes the five requests.
4. Block the server address with the pf rule (memory: sim network block)
   while browsing: the album page of a browsed album opens at once from the
   saved list, the banner turns to Try again after the probe, the favorites
   card keeps its count, Shuffle Favorites plays what is on disk. Unblock:
   the banner clears on the offline timer, the lists refresh in place, the
   stack and the queue stand.
5. `CTUNES_DEV_OFFLINE=1`: the root from disk, tiles dimmed, a pinned album
   plays; Try again connects and the dim lifts without the stack moving.
6. Start a stream, block the address mid-track: the player asks the monitor,
   goes to the next entry if it is on disk and otherwise pauses in place;
   unblock, and it plays on from there.
7. Siri: `CTUNES_DEV_INTENT=favorites` on a cold start waits for the server
   (log under `Siri`), and with `CTUNES_DEV_OFFLINE=1` plays the pinned
   favorites.
8. Section switch and sign out: a new library object, every page reloads,
   `Offline/` is empty after sign out.

## Follow-ups

- Queued hearts, replayed on attach.
- A longer floor on cellular, if the revalidation shows up in data use.
- The slow line on the search page and Quick Mix, which load
  without a `loaded` placeholder today.

## As built (Oct 2026)

Phases 1 and 2 landed on `colbyr/unified-library` in five commits (the
store split, the library unwired, the wiring, the attach fix, the monitor
and collapse). Where the build departs from the plan above:

- **`LibraryKey` and `ServerRecord`** live in `Sources/PlexKit/LibraryKey.swift`;
  the artist's tracks are `artists/<rk>-tracks.json` beside
  `artists/<rk>.json`. `Package.swift` moved to macOS 15 for `Mutex`.
- **`OfflineStore.server(_:)` finds a legacy `library.json` itself** when
  no `server.json` exists, so an install from before the split still
  opens from disk on its first launch after updating, before any section
  key is known.
- **Attach revalidates only the stale loaded keys** (§2 said every loaded
  key): on a cold start the root reads from disk before discovery
  finishes, and forcing every loaded key made every launch refetch the
  five lists. The failure memo is cleared on attach instead.
- **A failed revalidation is reported first, then retried** once on
  whatever connection is current after the report, so a miss that died on
  the address the phone just left lands from the one the probe found.
- **`favoriteOverrides` stays on the model**: `LibrarySource.setFavorite`
  takes a rating key, so the library can't add a track to the saved list
  optimistically; it refreshes the favorites after the write instead, and
  the pinned group follows through `libraryDidSave`.
- **`LibrarySource` gained `serverURL`** (the attached server's address,
  nil with none) so the player compares an item's address without casting
  to `PlexLibrary`.
- **The monitor declares `connected` only after the section list lands**,
  and the model opens the library before that, so the connection attaches
  once; a server that answers the probe and nothing else is a failed
  connect, not a connect that goes unreachable a second later.
- **The offline retry timer clears its handle before it runs the
  attempt.** A connect that lands cancels the timer, and cancelling the
  task the attempt was running in failed the sections request with
  `-999` on every retry. The old `AppModel` had the same cancel after its
  critical path, where it only cut the pin syncs short.
- **`.searching` earns the banner after 4s** (`searchingSlow`), not at
  once: a LAN answers within a second or two and the banner only flashed.
- **`sceneActivated`** on the model is the one activation entry: the
  monitor tries again or pings, then the downloads resume when connected.
- `CTUNES_DEV_OFFLINE` keeps its meaning; the timer's retry is forced and
  connects for real, as a tap does.

Verified on the iPhone Duo simulator against the Mac Mini: a legacy
snapshot split into the per-list files and `server.json` on first launch;
a relaunch 15s later made no request; a launch 3 minutes later refetched
the five lists; the forced-offline launch opened from disk, pushed a
saved album, and the timer reconnected at 10s. The pf network-block run
and the visual checks are for a hand pass (the Duo's displays screenshot
black from the terminal).

## Phase 3: one availability answer (built Oct 2026)

`LibrarySource.availability(of:quality:)` returns `.local(URL)`, `.stream`
or `.none`: a file on disk as good as the quality asked (a pinned one as
it is, and with no server anything on disk), else the server's stream,
else nothing (no part, or no file and no server). `canPlay(_:)` is the
yes or no, with the quality beside the point. `CachedLibrary` answers it
through `OfflineStore.localURL`, a synchronous passthrough to the cache's
two-root lookup; `PlexLibrary` knows no files and answers `.stream`.
`AudioPlayer.loadCurrentItem` switches on it (the old `wanted` quality
rule moved inside), `nextEntryIsOnDisk` asks for `.local`, and
`Downloads.canPlay` reads it under the inventory generation so a row
re-renders when a file lands or the connection changes. The seventeen
copies of `!offline || isAvailable` across the rows, filters, CarPlay
and Siri are that one call.

## Phase 4: the thin pipe (built Oct 2026)

A read with nothing saved is a **miss a screen is waiting on**, and the
library counts them (`misses`). While any is out: a stale hit's
revalidation is held (`deferred`) and started when the last miss lands,
and the cache's pin queue waits (`TrackCache.setPinsDeferred`, through
the store), so the one request the user is watching has the pipe. The
window prefetch is never held; the next track matters more than either.
A miss out past `slowAfter` (3s) yields true on `CachedLibrary.slow`,
false when every miss has landed; the model mirrors it as
`slowConnection`, `LoadingPlaceholder` writes "Slow connection" under
the spinner on the five screens that wait on a first read, and the root's
banner gains a `.slow` mode ("Slow connection · Showing your saved
library", a spinner, no button) beside `.searching` and `.offline`.

Not done here: pull to refresh and a write's refresh are foreground and
never held; a miss still waits the client's 10s request timeout before
it fails. The test for the held revalidation never awaits the library
while the mock's gate is held, since the mock answers on URLSession's one
loader thread and a held gate starves every other test's request.

