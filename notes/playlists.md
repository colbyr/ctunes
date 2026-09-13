# Plex playlists: browse, play, edit, keep offline

## Context

`PLAN.md` lists playlists as out of scope. Everything the app plays today is derived
(an album, an artist, the favorites set, a one-shot mix); nothing the user assembles by
hand survives the session. Plex already keeps playlists per account, Plexamp and the web
app edit them, and the server API for them is plain `MediaContainer` reads and a handful
of `POST`/`PUT`/`DELETE`s, so the client side is the work.

What a Plex playlist is, for the design:

- **Per account, filterable by section.** `/playlists` lists the account's playlists
  across every library; `playlistType` (`audio`, `video`, `photo`) picks the kind and
  `sectionID` narrows to one library (measured, below). An audio playlist can in
  principle mix the music and audiobook sections.
- **Regular or smart.** A regular playlist is an ordered list of items, each with its own
  `playlistItemID`, which is what removal and reordering address. A smart playlist is a
  saved filter: its items are computed, in the server's order, and can't be added to,
  removed from or reordered. Both can be renamed and deleted.
- **Composite art.** `composite` is a path like `/playlists/{rk}/composite/{stamp}` that
  the photo transcoder renders as a 2×2 of covers, so `artworkURL(composite)` just works,
  and the path changes whenever the contents do.
- **Counts come with the list.** `leafCount` (tracks) and `duration` (ms) ride on the
  playlist entry, as `viewCount`, `lastViewedAt`, `addedAt` and `updatedAt` do.

Decisions made up front:

- **Playlists are a third browse subject**, beside Albums and Artists in the arrange chip,
  not a fourth hero card. The chip already answers "what to browse", the subject persists
  (`browseSubject`), and the grid, the list layout, search, the sorts and the Downloaded
  filter come for free. The hero row is at its width limit (three cards need 880pt) and a
  fourth card would push the browser down on every phone for a page most people open now
  and then. The CarPlay tab bar gets a Playlists tab, which is where reaching them fast
  matters most.
- **The playlist page is the Favorites page's shape**, not the album page's: a `List` of
  track rows under Play and Shuffle cards, rows with the `···`, the page's own `···` in the
  toolbar, a hidden line for vetoes. Same reason as Favorites: it is a list of tracks from
  many albums, and edit mode (reorder, swipe to remove) is a `List` feature.
- **Vetoes apply when a playlist plays, never when it is built.** Adding an album adds
  every track; playing the playlist skips what the active listeners hide, using every veto
  (`hides(track)`, `within: nil`): a playlist is opened on purpose but it is a mixed bag,
  and a vetoed artist inside it is exactly what a veto is for. The hidden line on the page
  says how many rows that is.
- **The list is the selected section's.** `/playlists?playlistType=audio&sectionID={key}`
  filters (measured: 8 playlists on the account, 7 under Music, the audiobook one under
  Audio Books), so an audiobook playlist never shows under Music and the snapshot, which
  is per section already, stores what it showed.
- **Rows are keyed by `playlistItemID` where there is one, else by position.** The id is
  the handle move and remove address, so a row has to know its own; and while the server
  drops a duplicate on append (measured), a playlist made elsewhere is not promised to be
  duplicate-free, and `PlexTrack.id` is the rating key. A smart playlist's items carry no
  `playlistItemID` at all (measured) and the server never repeats a track in one, so
  position is a stable key there. The queue handles duplicates by its own entry ids
  either way.
- **A smart playlist's counts on the list are not believed.** The list entry's
  `leafCount` and `duration` for a smart playlist are whatever the server last cached,
  and were wrong for every one measured (149 listed, 148 served; 816 listed, 1,221
  served; 47 listed, none served). The tile says "Smart playlist" and no count; the page
  counts what it fetched. A regular playlist's counts were exact and are shown.
- **Edits are online only, optimistic, reverted on error**, the way hearts are. Nothing
  is queued for later: an outbox for playlist edits has the same conflict problems the
  offline note rejected for hearts.
- **Three phases**, each somewhere to stop: read and play; edit; keep offline. The store
  and snapshot changes in phase 1 are the small ones the later phases build on.

Goals: browse and play every playlist on the phone, in the car, and offline once browsed;
add anything to a playlist from the menu it already has; make, rename, reorder, prune and
delete regular playlists; pin a playlist the way favorites are pinned. Non-goals: smart
playlist editing (the filter builder), collaborative playlists, playlist folders, Plex
play queues (`/playQueues`), a "playing from" label in Now Playing, cover uploads.

## Measured: the reads

Captured against the real server (2026-09-13, the remote direct connection; the token
from `scripts/plex-token.sh`, the URL from the resources call the live test makes). The
same four `curl`s, with `Accept: application/json` and the token header, recapture the
fixtures for `Tests/PlexKitTests/Fixtures/playlists.json` and `playlist-items.json`:

```
$S/playlists?playlistType=audio                 # the account's audio playlists
$S/playlists?playlistType=audio&sectionID=3     # narrowed to a section
$S/playlists/1251/items                         # a regular playlist, 7 tracks
$S/playlists/437/items                          # a smart playlist
```

- **`sectionID` filters.** 8 audio playlists on the account; 7 with `sectionID=3`
  (Music), the 199-track audiobook one only under section 4. A bogus id returns an empty
  container, not an error. Every item carries `librarySectionID` too.
- **`smart` is a real JSON bool**, unlike `hasThumbnail`. `composite` and `duration` are
  absent for an empty playlist; `leafCount` is `0` then. `updatedAt` is sent.
- **The list entry's `duration` is milliseconds; the items container's is seconds**
  (`1669000` on the list, `1669` on `/items`). The app reads the list's.
- **A smart playlist's items have no `playlistItemID`**; a regular one's do, and their
  order is the playlist's, not the ids' (398, 399, 391, 396, …), so the ids are handles,
  not positions.
- **The list's counts are stale for smart playlists**: every one measured differed from
  what `/items` served (149 → 148, 129 → 132, 816 → 1,221, 134 → 301, 47 → 0). The
  single `GET /playlists/{rk}` recomputes (it said 0 for the one the list called 47), so
  a fresh count is one request per playlist if it is ever wanted. A regular playlist's
  list counts matched its items exactly.
- **Paging exists and isn't needed.** `X-Plex-Container-Start`/`-Size` headers page
  `/items` and add `totalSize` and `offset` to the container; unpaged, the 1,221-track
  "All Music" is 1.9 MB, the way a year of play history is. Fetch whole.
- **The composite renders through the photo transcoder** exactly as a `thumb` does:
  `/photo/:/transcode?width=400&height=400&minSize=1&url=/playlists/1251/composite/…`
  returned a 25 KB JPEG. `artworkURL(playlist.composite)` needs nothing new.
- Items decode as `PlexTrack` unchanged: `Media[0].Part[0].key`, `parentIndex`,
  `userRating`, `lastRatedAt`, `originalTitle` all present in the same shape as
  `/children`. Smart lists add `Genre` and `art`, which the DTO ignores.

## Measured: the writes

Run against a scratch playlist created for the purpose and deleted after (rating key
3542, gone; the account is back to its 8). Every call answered as hoped, with two
surprises worth designing around:

```
POST   /playlists?type=audio&smart=0&title=…&uri=server://{machineIdentifier}/com.plexapp.plugins.library/library/metadata/1212,609
PUT    /playlists/{rk}/items?uri=server://{machineIdentifier}/com.plexapp.plugins.library/library/metadata/580
PUT    /playlists/{rk}/items/{playlistItemID}/move?after={playlistItemID}
PUT    /playlists/{rk}/items/{playlistItemID}/move
PUT    /playlists/{rk}?title=…
DELETE /playlists/{rk}/items/{playlistItemID}
DELETE /playlists/{rk}
```

- **Create is a 200 whose body is the new playlist's entry** (`ratingKey`, `leafCount`,
  `duration`, `composite`, `updatedAt`), so the app has the tile without a second
  request. `machineIdentifier` is the one `/identity` reports, not the hash in the
  `plex.direct` hostname. A title of `ctunes scratch & test+1`, sent through the strict
  encoder (`%20`, `%26`, `%2B`), came back exactly.
- **Append is a 200 with `leafCountAdded` and `leafCountRequested` on the container**,
  not on the entry. **A track already in the playlist is silently dropped**: appending it
  again left the count alone and the response's `leafCountAdded` says so. The app's
  "Added N tracks" notice reads that number, and says "Already in Road Trip" when it is 0.
  Duplicates can't be made by appending, so `playlistItemID` matters as the handle for
  move and remove rather than for telling rows apart, though it still keys them.
- **An album key in the `uri` expands to its tracks** (the 12-track album added 11, the
  one already present dropped), and the `library://x/item/%2Flibrary%2Fmetadata%2F589`
  form works too. The app still sends explicit track keys (below), but one request per
  album is there if a menu ever wants it.
- **Every content change bumps `updatedAt` and the composite path's stamp**, rename
  included, so the tile's art is re-fetched by path with no cache invalidation of its
  own, and `AlbumView.recentlyAdded` over `updatedAt` reads as "recently edited".
- **Move works both ways**: `after={id}` puts the item after that one, and no `after`
  puts it at the top. Both 200, the ids unchanged.
- **Remove is a 200; an unknown item id is a 404. Delete is a 204**, and the playlist
  is a 404 afterwards. The list entry of a regular playlist reported fresh counts after
  every edit.

Not measured, because it would touch a real smart playlist: what a `PUT …/items` on one
returns. The app never sends it; smart playlists show no edit affordance at all.

## Approach

**PlexKit knows playlists as two DTOs and eight library calls.** `PlexPlaylist` is the
list entry; `PlaylistItem` is a track plus its `playlistItemID`, decoded from the same
JSON object. `LibrarySource` grows the reads and the writes the way it holds
`favoriteTracks` and `setFavorite`; `OfflineLibrary` answers the reads from the snapshot
and saved item lists and throws `PlexError.offline` on the writes, as `setFavorite` does.

**The model holds the list; pages hold their items.** `AppModel.playlists` is fetched
with the browse root's other requests and refetched after every write, so the "Add to
Playlist" submenu is synchronous and every screen agrees on the names. A
`playlistGeneration` counter, bumped on every write, is what the page's `.task(id:)` keys
on, so an add from an album's menu shows up on the playlist page behind it.

**The page edits through the model, the model through the library.** `PlaylistView`
keeps `items`, applies a remove or a move at once, calls the model, and reloads on error.
The model's mutators are the one place the list and the generation are updated.

**Offline is read-only and follows what was browsed**, like albums: the snapshot carries
the playlist list, the store saves each playlist's items when its page loads, and the page
offline lists them and plays what is on disk. Phase 3 adds a pin, which is a group like
the favorites group, not a node in the artist/album/track tree: a playlist crosses that
tree, so "wanted" is the union of the tree, the favorites group and the pinned playlists.

Alternatives considered and dropped:

- **A Playlists hero card on the root.** Discoverable, but the hero row can't take a
  fourth card at any phone width, and the card would open a page that is the browse grid
  again with a different subject. The subject is that page.
- **A `PlaylistEditing` protocol only `PlexLibrary` adopts**, with the app casting
  `model.library as? PlaylistEditing` to decide whether to show edits. Tidier for
  `OfflineLibrary`, but every existing write lives on `LibrarySource` and throws offline,
  and the screens already hide writes on `library.isOffline`. One pattern.
- **`playlistItemID` as an optional field on `PlexTrack`.** Fewer types, but every
  `PlexTrack` in the app would carry a field that is meaningful in one list, `Hashable`
  would start telling the same track apart by where it was seen, and the queue, hearts and
  downloads compare tracks by value. A wrapper keeps the track a track.
- **Plex play queues (`/playQueues`) for playback**, which is what Plexamp does so the
  server can report "playing from playlist X". The app's queue is its own, every other
  source bypasses the server's, and nothing here needs the server to know the source.
- **Adding an album by its key in the `uri`** and letting the server expand it. Measured
  to work, and to drop what is already there, so it is one request instead of a fetch and
  a request. Still not the default: the menus already fetch an album's tracks for Play,
  an artist key's expansion is unmeasured, and one code path for a track, an album and an
  artist is simpler than two. Worth switching to for albums if the fetch ever shows up as
  latency in the menu.
- **A playlist pin as a fourth kind in the pin tree.** The tree is disjoint by
  construction (an artist absorbs their albums); a playlist can't be absorbed by or absorb
  anything. It is a group, like favorites, and shares that code path.

## Phase 1: browse and play

### 1. `Sources/PlexKit/PlexLibraryModels.swift` — DTOs, snapshot

```swift
/// One entry of `/playlists?playlistType=audio`. `composite` is a
/// server path the photo transcoder renders as a grid of covers.
public struct PlexPlaylist: Codable, Sendable, Identifiable, Hashable {
    public let ratingKey: String
    public let title: String
    public let summary: String?
    /// A saved filter: items are the server's and can't be edited.
    public let smart: Bool
    public let composite: String?
    /// Milliseconds, the whole playlist.
    public let duration: Int?
    public let leafCount: Int?
    public let addedAt: Int?
    public let updatedAt: Int?
    public let lastViewedAt: Int?
    public let viewCount: Int?
    public var id: String { ratingKey }
}

/// A track's place in a playlist. `playlistItemID` is what removal and
/// reordering address on a regular playlist, and the row identity there.
/// A smart playlist's items have none (measured), and the page keys
/// those rows by position.
public struct PlaylistItem: Codable, Sendable, Hashable {
    public let playlistItemID: Int?
    public let track: PlexTrack
    // init(from:) decodes playlistItemID from the container and the track
    // from the same decoder: `track = try PlexTrack(from: decoder)`.
    // encode(to:) writes the track's keys then playlistItemID, so a saved
    // item list round-trips through the same shape.
}
```

`smart` decodes as a plain `Bool`; it is one on the wire. `LibrarySnapshot` gains
`playlists: [PlexPlaylist]` with `decodeIfPresent … ?? []` in `init(from:)`, like
`history`, so existing snapshots still load.

### 2. `Sources/PlexKit/PlexLibrary.swift` and `LibrarySource.swift` — the calls

```swift
public func playlists(inSection section: String) async throws -> [PlexPlaylist]
// GET /playlists?playlistType=audio&sectionID={section}
public func items(inPlaylist ratingKey: String) async throws -> [PlaylistItem]
// GET /playlists/{rk}/items   whole, unpaged: 1,221 tracks measured at 1.9 MB
```

The writes, all through `client.request(method, url:token:)` like `setFavorite`, titles
percent-encoded with the strict encoder the transcoder URL uses:

```swift
public func createPlaylist(title: String, trackKeys: [String]) async throws -> PlexPlaylist
// POST /playlists?type=audio&smart=0&title=…&uri=server://{machineIdentifier}/com.plexapp.plugins.library/library/metadata/{k1,k2}
public func add(trackKeys: [String], toPlaylist ratingKey: String) async throws -> Int
// PUT /playlists/{rk}/items?uri=…   returns the container's leafCountAdded:
// the server drops tracks already in the playlist, and 0 is "already there"
public func remove(item playlistItemID: Int, fromPlaylist ratingKey: String) async throws
// DELETE /playlists/{rk}/items/{id}
public func move(item playlistItemID: Int, after: Int?, inPlaylist ratingKey: String) async throws
// PUT /playlists/{rk}/items/{id}/move[?after={id}]   no `after`: to the top
public func renamePlaylist(_ ratingKey: String, title: String) async throws
// PUT /playlists/{rk}?title=…
public func deletePlaylist(_ ratingKey: String) async throws
// DELETE /playlists/{rk}
```

`PlexLibrary` needs the machine identifier for the `uri`; it has `server`. The eight
methods go on `LibrarySource`; `OfflineLibrary` returns `snapshot.playlists`, the store's
saved items, and throws `PlexError.offline` from each write.

Tests in `Tests/PlexKitTests/PlexLibraryTests.swift`, following the existing pairs: decode
the new `playlists.json` fixture (a regular and a smart entry, and the empty one with no
`composite` or `duration`), decode `playlist-items.json` (`playlistItemID` and the
track's part, and a smart item with no id), assert the list URL carries
`playlistType=audio` and `sectionID=3`, and one URL assertion per write with the `Locked`
box, including that a title with a space and an ampersand reaches the URL encoded.

### 3. `Sources/PlexKit/AlbumBrowse.swift` — subject, scope, sorts

`BrowseSubject` gains `case playlists` ("Playlists", `music.note.list`) and `BrowseScope`
gains `case playlists`. The four `AlbumView`s over playlists, flat, no groups (as
`.discography` is): `.artist` is "A to Z" by title, `.recentlyAdded` is "Recently
Updated" by `updatedAt`, `.mostPlayed` is "Most Played" by `viewCount` (there is no
per-playlist play history, so no rotation score), `.backCatalog` keeps its name and is
`lastViewedAt` ascending with never-played first. `title(in:)` grows the three cases;
`sorted(_ playlists:)` and `search(_ playlists:query:view:)` reuse the album ranking
(`prefix`, `wordPrefix`, `inside`). Tests in `AlbumBrowseTests` for the sorts and the nil
ordering.

### 4. `App/ctunes/AppModel.swift` — the list

```swift
private(set) var playlists: [PlexPlaylist] = []
private(set) var playlistGeneration = 0
func loadPlaylists() async            // library.playlists(inSection:); a failure keeps the old list
func rememberItems(_ items: [PlaylistItem], inPlaylist: PlexPlaylist) async  // offline.saveItems
```

`snapshot(albums:favorites:history:)` gains `playlists:`; `MusicView.load()` fetches the
list beside artists and favorites (optional, like them) and passes it on. `enterOffline`
sets `playlists` from the snapshot.

### 5. `Sources/PlexKit/OfflineStore.swift` — saved items

`<server>/playlists/<ratingKey>.json` holds `[PlaylistItem]` per playlist browsed, written
by `saveItems(_:inPlaylist:server:)` when the page loads online and read by
`items(inPlaylist:server:)`, exactly `saveTracks`/`tracks(inAlbum:)`. `availableAlbums`
is untouched: a playlist's tracks are on disk or not by their own paths. Offline the page
dims rows with no file the way Favorites does. One `OfflineStoreTests` case for the
round trip.

### 6. `App/ctunes/Views/BrowseItems.swift`, `MusicView.swift` — the grid

`PlaylistTile` and `PlaylistRow`: square art from `composite` (a `music.note.list` glyph
on the parchment when there is none), the title, "12 tracks · 48 min" under it from the
list's `leafCount` and `duration` for a regular playlist, and "Smart playlist" alone for a
smart one, whose list counts are stale (measured, above). `MusicView` gets `playlists` from `model.playlists`,
`playlistResults` through the new search, the `.playlists` case in `sections` (one
unnamed section), `hiddenCount` of zero (playlists are not veto targets), and Downloaded
only keeps playlists with any saved item on disk, which means a never-browsed playlist
hides under the filter; the "No downloads" line covers it. Each tile pushes
`path.append(playlist)` and carries `PlaylistMenu` as its context menu. The
`ContentUnavailableView` for an empty subject reads "No playlists" with a line that they
are made from any track, album or artist's menu (phase 2).

### 7. `App/ctunes/Views/PlaylistView.swift` — the page

New file, modeled on `FavoritesView`. `List(.plain)`, `.parchment()`, Play and Shuffle
`MixActionCard`s that become toolbar icons once scrolled past, the divider, the
`HiddenLine`, then one row per item keyed by `playlistItemID`, or by position on a smart
playlist. Rows draw the track's art,
title, "artist — album" and duration exactly as Favorites does, the `···` opening
`TrackMenu` with the new placement (below). The page's ground comes from the composite
through `artworkBackground(_:)` as the album page's does from the cover.

State: `items: [PlaylistItem]`, `loaded`, `actionsVisible`. Derived: `tracks` (items'
tracks, in order), `rows` (items whose track no veto hides), `playable` (offline, rows
with a file). Play and Shuffle hand `playable`'s tracks to `player.play`, shuffle being
the spread shuffle. Title is the playlist's, `navigationSubtitle` is "N tracks · 1 hr 12
min" from the rows. Fetch in `.task(id: model.playlistGeneration)` and on pull to
refresh; online, hand the items to `model.rememberItems`. A `URLError` goes to
`model.connectionLost`.

Toolbar `···`: nothing in phase 1 beyond what phase 2 and 3 add; declare it now so the
layout doesn't move.

`TrackPlacement` gains `case playlistItem(PlaylistItem, in: PlexPlaylist, siblings: [PlexTrack])`:
Play and Shuffle behave as `.list` does (play the list from this row, this row kept
whatever hides it); phase 2 adds Remove from Playlist under it when the item has an id.

### 8. `App/ctunes/Views/ItemMenus.swift` — `PlaylistMenu`

The tile's long-press menu: Play, Shuffle, Play Next, Add to Queue, each fetching
`library.items(inPlaylist:)` in the action and passing the tracks through
`actions.playable(_, within: nil)`; nothing to play is the usual notice. `LibraryRoute`
gains `.playlist(PlexPlaylist)` and `LibraryView` a `navigationDestination(for:
PlexPlaylist.self)`, so a menu elsewhere (phase 2's "Go to Playlist" after a create) can
open one.

### 9. `App/ctunes/CarPlay/CarPlayController.swift` — a tab

A fifth `CPListTemplate(title: "Playlists")`, `music.note.list`, filled from
`model.playlists` in `render()` (sorted A to Z; the car has no arrange chip), each row
drilling into the items under Play and Shuffle like `showAlbum`, vetoes dropped, the
composite loaded as the row image. `CPTabBarTemplate.maximumTabCount` is what decides
whether five tabs fit; if it reports four, Playlists takes Recently Added's slot rather
than being left out, since On Rotation already covers "what's new to me". Verify in
DeviceHub before assuming five.

### 10. Debug hook, docs

`CTUNES_DEV_PLAYLIST`: `ratingKey|title` pushes that playlist's page; `list` switches the
root's subject to Playlists. Read in `LibraryView`'s `.task` beside `CTUNES_DEV_ARTIST`.
Rows in the `CLAUDE.md` table and the Architecture section (subject, page, placement,
offline read-only); an M11 line in `PLAN.md` and "playlists" out of the out-of-scope
sentence.

Phase 1 verification: `make test`; `make sim-run` with `CTUNES_DEV_PLAYLIST=list` shows
the seven Music playlists and not the audiobook one, composites on all but the empty
smart one, counts on the two regular ones, the four sorts reorder it, search filters it,
a tap opens the page (the 1,221-track "All Music" included, to see the fetch and the
list hold up), Play and Shuffle start the queue and open Now Playing, a veto seeded
with `CTUNES_DEV_LISTENERS=<artistKey>` produces the hidden line and skips those rows;
relaunch with `CTUNES_DEV_OFFLINE=1` after browsing one playlist and it lists, dims what
has no file, and plays the rest; the CarPlay tab appears in DeviceHub.

## Phase 2: edit

### 11. `AppModel` — mutators

```swift
func createPlaylist(title: String, tracks: [PlexTrack]) async -> PlexPlaylist?
func add(_ tracks: [PlexTrack], to playlist: PlexPlaylist) async -> Bool
func remove(_ item: PlaylistItem, from playlist: PlexPlaylist) async -> Bool
func move(_ item: PlaylistItem, after: PlaylistItem?, in playlist: PlexPlaylist) async -> Bool
func rename(_ playlist: PlexPlaylist, to title: String) async -> Bool
func delete(_ playlist: PlexPlaylist) async -> Bool
```

Each calls the library, then `loadPlaylists()` and bumps `playlistGeneration`; a failure
runs `connectionLost` for a `URLError` and returns false so the caller reverts. All bail
on `library.isOffline`. `add` posts the server's `leafCountAdded` to `navigator.notice`
("Added 12 tracks to Road Trip", or "Already in Road Trip" when it is 0, which the
server's duplicate-dropping makes common) since a menu action otherwise gives no sign it
did anything; the existing alert host shows it.

### 12. `ItemMenus.swift` — Add to Playlist, Remove, the page menu

`AddToPlaylistMenu(model:, tracks: @escaping () async -> [PlexTrack])`: a `Menu` labeled
"Add to Playlist" with one button per regular playlist in `model.playlists` (smart ones
left out) and "New Playlist…" last. Hidden offline, like Download. `ArtistMenu`,
`AlbumMenu` and `TrackMenu` each add it after the queue section, the artist's and album's
fetching tracks in the action the way Play does, vetoes not applied (they apply at play
time). The track menu on the `.playlistItem` placement adds a destructive "Remove from
Playlist" when the playlist is regular and the library online; the item's own playlist is
left out of its "Add to Playlist" list.

"New Playlist…" needs a name. `LibraryNavigator` gains `composing: [PlexTrack]?`;
`LibraryView` presents an alert with a `TextField` ("New Playlist", placeholder "Name",
Create disabled while empty) and calls `model.createPlaylist`, then opens the new
playlist's page. On the root's Playlists subject the empty state's button and a toolbar
"New Playlist" (`plus`) post the same request with no tracks.

`PlaylistMenu` and the page's `···` gain Rename (an alert with a `TextField` seeded with
the title, through the same navigator request with a playlist attached) and a destructive
Delete (confirmation dialog, since it is the one irreversible action in the app so far),
both hidden offline; the page pops after a delete.

### 13. `PlaylistView` — reorder and prune

Regular playlist, online: an Edit button in the toolbar toggles `editMode`; `.onMove`
reorders `items` at once and calls `model.move(item, after:)` with the item now above it
(nil at the top); `.onDelete` and a trailing swipe "Remove" drop the row and call
`model.remove`. A false return reloads the page. Smart playlists show neither; the
subtitle reads "Smart playlist · N tracks" so the absence is explained.

Phase 2 verification: `make test` with the write URL tests; in the simulator, an album's
menu → Add to Playlist → New Playlist… creates and opens it; adding the same album again
from another screen shows the "Already in" notice and the page is unchanged; adding one
new track shows "Added 1 track" and the tile's composite changes; swipe removes a row;
Edit reorders and a pull to refresh confirms the server agrees; Rename changes the title
in the grid; Delete pops and the grid loses it; every edit is absent offline.

## Phase 3: keep offline

### 14. `OfflineStore` — the playlist group

`Manifest.pinnedPlaylists: [String: PinnedPlaylist]` (`title`, `composite`, `pinnedAt`),
decoded as empty from older manifests. `setPlaylistPinned(_:enabled:server:)` and
`setPlaylistItems(_:inPlaylist:server:sources:)` mirror `setFavoritesPinned` and
`setFavorites`: the saved item list from phase 1 is the wanted list, `wantedPaths` adds
every pinned playlist's tracks, and the composite is saved under `art/` at pin time. A
file is now wanted while any pin, the favorites group or a pinned playlist lists it; the
tree stays untouched. `inventory(server:)` reports each pinned playlist's done/total and
bytes, and `AppModel.syncPlaylistPins()` runs beside `syncFavoritesPin` on connect so a
playlist edited elsewhere is reconciled. `OfflineStoreTests`: pin, wanted-set union with
an album pin sharing a track, unpin narrows nothing else, an older manifest decodes.

### 15. App — Keep Offline, badges, the manager

`Downloads` mirrors `isPinned(playlist:)` and `state(playlist:)`; `PlaylistMenu` and the
page's `···` get the same Download / Stop / Retry / Remove Download items as an album
through `actions.downloadItems`; `PlaylistTile` wears the `DownloadBadge`; `StorageView`
lists pinned playlists as a section between favorites and the artist pins, removable by
swipe. `OfflineLibrary.artworkURL` already falls back to the store's art for the
composite.

Phase 3 verification: pin a playlist in the simulator (`CTUNES_DEV_PIN=playlist` beside
`CTUNES_DEV_PLAYLIST=rk|title`), watch the files land in the pinned root and the badge
fill, relaunch with `CTUNES_DEV_OFFLINE=1` and play it end to end; remove the pin and
confirm a track also under an album pin stays.

## Files

Phase 1
- `Sources/PlexKit/PlexLibraryModels.swift` — `PlexPlaylist`, `PlaylistItem`, snapshot field
- `Sources/PlexKit/PlexLibrary.swift`, `LibrarySource.swift`, `OfflineLibrary.swift` — the calls
- `Sources/PlexKit/AlbumBrowse.swift` — subject, scope, sorts, search
- `Sources/PlexKit/OfflineStore.swift` — saved items
- `App/ctunes/AppModel.swift` — `playlists`, `playlistGeneration`, `loadPlaylists`, `rememberItems`
- `App/ctunes/Views/BrowseItems.swift`, `AlbumBrowserControls.swift`, `MusicView.swift` — the grid
- `App/ctunes/Views/PlaylistView.swift` — new
- `App/ctunes/Views/ItemMenus.swift` — `PlaylistMenu`, placement, route
- `App/ctunes/Views/LibraryView.swift` — destination, dev hook
- `App/ctunes/CarPlay/CarPlayController.swift` — the tab
- `Tests/PlexKitTests/Fixtures/playlists.json`, `playlist-items.json`; `PlexLibraryTests`, `AlbumBrowseTests`, `OfflineStoreTests`
- `CLAUDE.md`, `PLAN.md`

Phase 2
- `App/ctunes/AppModel.swift` — mutators
- `App/ctunes/Views/ItemMenus.swift` — `AddToPlaylistMenu`, Remove, Rename, Delete
- `App/ctunes/Views/LibraryView.swift` — the name and rename alerts, the delete confirmation
- `App/ctunes/Views/PlaylistView.swift` — edit mode
- `Tests/PlexKitTests/PlexLibraryTests.swift` — write URLs

Phase 3
- `Sources/PlexKit/OfflineStore.swift`, `DownloadInventory.swift` — the group
- `App/ctunes/AppModel.swift`, `Downloads.swift`, `Views/StorageView.swift`, `ItemMenus.swift`, `BrowseItems.swift`
- `Tests/PlexKitTests/OfflineStoreTests.swift`
- `notes/downloads.md` — the wanted-set sentence

## Follow-ups, not in any phase

- **Save the queue as a playlist** from Now Playing: `createPlaylist(title:tracks:)` over
  `player.queue`, a one-line addition once phase 2 exists, but Now Playing has no page
  menu today and deserves one designed on purpose.
- **Smart playlists' filters** as a builder: the mix builders are close, but Plex's filter
  grammar is its own and the payoff is small next to a mix.
- **Following a pinned playlist's changes while offline** is impossible by construction;
  the reconcile on connect is the whole story.
