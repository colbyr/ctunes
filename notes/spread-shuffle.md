# Spread shuffle (Spotify-style) for mixes, favorites and the shuffle toggle

## Context

Every shuffle in the app is a uniform Fisher–Yates: `shuffled()` at enqueue time in
`MixBuilderView.play`, `MusicView.shuffleFavorites` and `TracksView.shuffle`, and
`PlayQueue.shuffle(using:)` behind the Now Playing toggle. Uniform randomness is streaky by
nature — a three-artist mix has a 1-in-3 chance of repeating the artist on every step — which
is why artist and album mixes feel badly distributed.

Fix: implement the algorithm from Spotify's 2014 "How to shuffle songs?" post (Poláček,
building on Fiedler's balanced shuffle). Tracks are grouped by artist; each artist's n tracks
are spread evenly across the unit interval with a random offset and ±10% jitter; within an
artist the same is done by album; the queue is the sort by position. One grouping,
`[artist, album]`, serves every call site: for an album mix across artists it spreads albums,
for several albums by one artist it falls through to the album level.

## Changes

### 1. `Sources/PlexKit/PlexLibraryModels.swift` — album key on tracks
Add `public let parentRatingKey: String?` to `PlexTrack` (doc: the album's ratingKey; matches
`PlexAlbum.ratingKey`). The fixture already carries it on every row; `PlexTrack` is decoded only
(no memberwise call sites in the app), so this is a one-line DTO change. Assert it in the
existing `tracks(inAlbum:)` test in `Tests/PlexKitTests/PlexLibraryTests.swift`
(`first.parentRatingKey == "1029"`).

### 2. `Sources/PlexKit/SpreadShuffle.swift` — new, pure
```swift
extension Array {
    /// Spotify-style balanced shuffle. Items sharing the first key are spread evenly across
    /// the result with a random offset and ±10% jitter; within a group the remaining keys
    /// recurse; with no keys left the group is shuffled uniformly.
    public func spreadShuffled(
        by keys: [(Element) -> String],
        using generator: inout some RandomNumberGenerator
    ) -> [Element]
}
```
Implementation (~40 lines): if `keys` is empty return `shuffled(using:)`. Otherwise group by
`keys[0]` (dictionary keyed by string, groups in first-seen order so results are deterministic
for a seeded generator), recurse each group with `keys.dropFirst()` to get its inner order,
then assign position `offset + i * spacing + jitter` where `spacing = 1 / n`,
`offset ∈ [0, spacing)`, `jitter ∈ [-0.1, 0.1] * spacing`. Concatenate all `(position, item)`
pairs and sort by position. A convenience overload without `using:` uses
`SystemRandomNumberGenerator`.

Add on `PlexTrack`:
```swift
/// Artist, then album: the grouping every shuffle in the app spreads by.
public static let shuffleGrouping: [(PlexTrack) -> String] =
    [{ $0.grandparentRatingKey ?? "" }, { $0.parentRatingKey ?? "" }]
```
and `extension Array where Element == PlexTrack { public func spreadShuffled() -> [PlexTrack] }`
that bakes the grouping in, so view call sites stay one expression.

### 3. `Sources/PlexKit/PlayQueue.swift` — toggle uses it
Add `shuffle(groupedBy keys: [(Item) -> String], using:)`; the body is today's `shuffle(using:)`
with `rest.shuffle(using:)` replaced by `rest.spreadShuffled(by:using:)` where the key closures
are lifted through `Entry.item`. Existing `shuffle(using:)` / `shuffle()` forward with `[]`, so
current tests and behaviour are unchanged. Add `shuffle(groupedBy:)` without a generator.

### 4. Call sites
- `App/ctunes/AudioPlayer.swift:153` — `queue.shuffle(groupedBy: PlexTrack.shuffleGrouping)`.
- `App/ctunes/Views/MixBuilderView.swift:257`, `MusicView.swift:208`, `TracksView.swift:254` —
  `playable.spreadShuffled()` / `tracks.spreadShuffled()`. Update the three "shuffled once at
  enqueue time" doc comments to say "spread-shuffled".

### 5. Tests — `Tests/PlexKitTests/SpreadShuffleTests.swift` (new)
Reuse the `SeededGenerator` from `PlayQueueTests.swift` (move it to `Fixture.swift` or make it
internal in the test target). Tracks as small structs with `artist`/`album` strings.
- Multiset preserved, deterministic for a seed.
- 3 artists × 10 tracks: no run of the same artist longer than 2 anywhere; every artist appears
  in each third of the result.
- Unequal sizes (20 + 2): the two rare tracks land in different halves.
- One artist, 3 albums × 4 tracks: no run of the same album longer than 2.
- Empty keys degrades to a uniform shuffle (same multiset, length preserved).
- `PlayQueue.shuffle(groupedBy:)`: current item stays first and `unshuffle` round-trips.

### 6. Docs
- `CLAUDE.md` Architecture: one sentence under `AudioPlayer` noting every shuffle spreads by
  artist then album (`SpreadShuffle.swift`), so nobody reaches for `shuffled()` again.
- `PLAN.md` M6/M7 rows: "spread shuffle" wording; `notes/mixes.md` context line likewise.

## Files
- `Sources/PlexKit/SpreadShuffle.swift` — new
- `Sources/PlexKit/PlexLibraryModels.swift` — `parentRatingKey`, `shuffleGrouping`
- `Sources/PlexKit/PlayQueue.swift` — `shuffle(groupedBy:)`
- `App/ctunes/AudioPlayer.swift`, `Views/MixBuilderView.swift`, `Views/MusicView.swift`,
  `Views/TracksView.swift` — call sites
- `Tests/PlexKitTests/SpreadShuffleTests.swift` — new; `PlexLibraryTests.swift` — one assert
- `CLAUDE.md`, `PLAN.md`, `notes/mixes.md`

## Verification
1. `make test` — new suite plus existing `PlayQueueTests` pass.
2. `make sim-run` in a tmux pane with `SIMCTL_CHILD_CTUNES_DEV_TOKEN` and
   `SIMCTL_CHILD_CTUNES_DEV_MIX=artist:<key>,<key>,<key>` + `SIMCTL_CHILD_CTUNES_DEV_AUTOPLAY=1`
   (`CTUNES_DEV_NOWPLAYING=1` to open the sheet). Scroll Up Next and confirm artists
   interleave with no long runs; toggle shuffle off and on in Now Playing and confirm the
   same. Repeat with `CTUNES_DEV_MIX=album:...` for two albums by one artist.
