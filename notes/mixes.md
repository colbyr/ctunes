# Artist & Album Mixes

## Context

Plexamp-style mixes, per the "Mix Builders" mockup (`Mix Builders.dc.html`, options 1b/1c/1d).
A mix is a set of artists (or a set of albums); Play spread-shuffles every track in the union
(by artist, then album) into a one-shot queue. Nothing is saved. Listener vetoes apply: builders only offer artists that survive
the active listeners' vetoes. No sonic analysis, no Plex playQueues; this is the same
"fetch, filter, shuffle once, `player.play`" pattern `shuffleFavorites` already uses
(`App/ctunes/Views/MusicView.swift:185-205`).

Mockup, distilled:
- **Main screen (1b):** Shuffle Favorites stays the hero card. Beneath it, two half-width tiles:
  Artist Mix (indigo, people icon) and Album Mix (orange, album icon). Everything else unchanged.
- **Builder (1c/1d):** inline nav title "Artist Mix"/"Album Mix", back button, trailing **Clear**
  (dimmed when nothing selected). Scroll content: a **Play Mix** card (same card style as Shuffle
  Favorites; play icon in a black circle when a selection exists, grey when empty; title
  "Play Mix" or "Build a mix"; subtitle = selected names joined with ", " or "Tap artists below to
  build a mix"; trailing shuffle glyph in the accent color). Then the **selected grid**
  (3 columns, accent ring + black ⨉ badge, tap removes), a divider, the **hidden line**
  ("N artists hidden for Laura", eye.slash) when vetoes apply, then the **pool grid** (tap adds).
  Artists are circles with a name; albums are squares with title + artist line. Search is the
  existing bottom-right pill and filters the pool.

## Changes

### 1. PlexKit: tracks for an artist
`Sources/PlexKit/PlexLibrary.swift` — add next to `favoriteTracks`:
```swift
public func tracks(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexTrack]
// path: "/library/sections/\(section)/all?type=10&artist.id=\(artistRatingKey)"
```
Section-filtered like `albums(forArtist:)`, for the same under-reporting reason (don't walk
`/children` twice). Album mixes reuse `tracks(inAlbum:)`.

Test in `Tests/PlexKitTests/PlexLibraryTests.swift`, following the existing `albums(forArtist:)`
pair: decode `Fixture.string("tracks")` through the new call, and assert the captured URL
contains `type=10` and `artist.id=1028` (use the `Locked` box pattern already in that file).

### 2. Navigation value
New `App/ctunes/Views/MixBuilderView.swift` declares:
```swift
enum MixKind: String, Hashable { case artist, album }   // title, accent Color, systemImage, noun
```
`App/ctunes/Views/LibraryView.swift`: add
`.navigationDestination(for: MixKind.self) { MixBuilderView(model:, section:, kind:, query: $query) }`
next to the album destination (`:22`). Section comes from `model.selectedSection`.

Search coupling: today `onChange(of: searching)` pops to root (`LibraryView.swift:35-37`). Add
`@State private var buildingMix = false`, set by the builder via a binding (`onAppear` true /
`onDisappear` false), and only pop when `!buildingMix`. The builder clears `query` on appear so
a root filter doesn't leak in, and the existing `onChange(of: path.isEmpty)` already closes the
pill on pop.

### 3. Main screen tiles
`App/ctunes/Views/MusicView.swift`: after `ShuffleFavoritesCard` (`:70-72`), one list row with
an `HStack(spacing: 12)` of two `MixTile`s (`Button { path.append(MixKind.artist) }`), row insets
`(top: 0, leading: 16, bottom: 12, trailing: 16)`, separator hidden. `MixTile` is a private view
mirroring `ShuffleFavoritesCard`'s chrome (`:312-315`: padding 14, `secondarySystemGroupedBackground`,
corner 18, shadow) with a 36pt tinted icon circle and a `.headline` label. Icons:
`person.2.fill` / indigo, `square.stack.fill` / orange.

### 4. MixBuilderView
`App/ctunes/Views/MixBuilderView.swift`. `List(.plain)` like `MusicView`, `.navigationTitle(kind.title)`,
`.navigationBarTitleDisplayMode(.inline)`, `.contentMargins(.bottom, 72, for: .scrollContent)`,
toolbar trailing `Button("Clear") { selected = [] }.disabled(selected.isEmpty)`.

State: `pool` loaded in `.task` (`library.artists(inSection:)` for `.artist`,
`library.albums(inSection:)` for `.album`), `selected: [String]` (ratingKeys, insertion order),
`loadingMix`, `showingNowPlaying`, `@AppStorage("albumSort")` reused so the album pool matches
the main screen order.

Derived:
- `hidden = model.roster.hiddenArtistKeys`. Artist pool = artists not in `hidden`, filtered by
  `query` with `localizedCaseInsensitiveContains` on title. Album pool =
  `AlbumBrowse.search(albums, query:, sort:, hiding: hidden)` when the query is non-empty, else
  `AlbumBrowse.groups(albums, sort:, grouping: .none, hiding: hidden).first?.albums ?? []`.
- `hiddenCount` = pool items whose artist key is in `hidden`; hidden line text copies the
  subtitle wording in `MusicView.swift:111-113`.
- Selected items = `selected` mapped through the pool by ratingKey (so a vetoed artist toggled
  on from the root drops out of the mix automatically).

Rows, top to bottom:
1. `PlayMixCard` (private): same chrome as `ShuffleFavoritesCard`; `ProgressView` in the trailing
   slot while `loadingMix`; disabled when no selection.
2. If selection non-empty: `LazyVGrid(.adaptive(minimum: 100), spacing: 12)` of selected tiles,
   then a `Divider`.
3. If `hiddenCount > 0`: `Label(..., systemImage: "eye.slash")` footnote secondary.
4. Pool grid, same `LazyVGrid`. Overlay `ContentUnavailableView.search(text:)` when a query
   yields nothing, `ProgressView` until loaded.

Tiles: `Artwork(url: model.library?.artworkURL(thumb), size: nil, corner: 8)`; artist tiles add
`.clipShape(.circle)` and a centered caption. Selected tiles wrap the art in
`.overlay(shape.stroke(kind.accent, lineWidth: 2.5).padding(-4))` and a 24pt black circle with a
white `xmark` at the top-trailing corner. Every tile is a `Button` toggling membership in
`selected` inside `withAnimation(.snappy)`; `.buttonStyle(.plain)` and `.contentShape(.rect)` as in
`AlbumTile`.

Play:
```swift
guard let library = model.library, !selectedItems.isEmpty, !loadingMix else { return }
loadingMix = true
Task {
    defer { loadingMix = false }
    let tracks = await withTaskGroup(of: [PlexTrack].self) { group in
        for key in selected { group.addTask { (try? await fetch(key)) ?? [] } }   // tracks(forArtist:) or tracks(inAlbum:)
        return await group.reduce(into: []) { $0 += $1 }
    }
    let playable = tracks.filter { !hidden.contains($0.grandparentRatingKey ?? "") }
    guard !playable.isEmpty else { nothingToPlay = true; return }
    player.play(playable.shuffled(), startingAt: 0, library: library)
    showingNowPlaying = true
}
```
`.sheet(isPresented: $showingNowPlaying) { NowPlayingView(model: model) }` and an alert for the
empty case, matching `TracksView.play` / `MusicView.shuffleFavorites`.

### 5. Debug hook + docs
- `CTUNES_DEV_MIX`: `artist` or `album` pushes that builder on launch; an optional
  `:key1,key2` suffix pre-selects. Read in `LibraryView`'s `.task` next to `CTUNES_DEV_ALBUM`,
  pre-selection handed to the builder via a static like `TracksView.autoPlay`.
- Add the row to the CLAUDE.md debug-hook table. Add an M7 "Mixes" line to `PLAN.md` status and
  note that "sonic-analysis radio" stays out of scope; these mixes are plain unions.

## Files
- `Sources/PlexKit/PlexLibrary.swift` — `tracks(forArtist:inSection:)`
- `Tests/PlexKitTests/PlexLibraryTests.swift` — two tests
- `App/ctunes/Views/MixBuilderView.swift` — new: `MixKind`, `MixBuilderView`, `PlayMixCard`, tiles
- `App/ctunes/Views/LibraryView.swift` — destination, search coupling, dev hook
- `App/ctunes/Views/MusicView.swift` — `MixTile` row under the hero card
- `CLAUDE.md`, `PLAN.md` — docs

## Verification
1. `make test` — new PlexLibrary tests pass alongside the suite.
2. `make sim-run` in a tmux pane with `SIMCTL_CHILD_CTUNES_DEV_TOKEN` from `make token` /
   `scripts/plex-token.sh`, plus `SIMCTL_CHILD_CTUNES_DEV_LISTENERS=<artistKey>` so a veto is
   active. Confirm: tiles render under Shuffle Favorites; tapping opens the builder; the vetoed
   artist (and its albums) is absent and the hidden line shows; toggling tiles moves them between
   grids with the ring/⨉ badge; Clear empties; the search pill filters the pool without popping
   to root; Play Mix fetches, shuffles, starts playback and opens Now Playing with tracks from
   every selected artist/album.
3. `SIMCTL_CHILD_CTUNES_DEV_MIX=album:<key>,<key>` lands on the album builder pre-selected.
4. `make live-test` optionally, to confirm `type=10&artist.id=` returns tracks on the real server.
