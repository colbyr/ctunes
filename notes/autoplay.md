# Autoplay: keep playing on-theme tracks when the queue runs out

Status: plan only, nothing built. Measured against the real server (PMS 1.43.3) on
2026-09-10; the probe responses are not checked in.

## Context

Today the queue is finite. `AudioPlayer.advance` fails at the last entry and calls
`finish()`: the player pauses, `hasEnded` flips, the Up Next header disappears and the
lock screen's play button restarts the queue from the top. Every way of starting playback
(album, favorites, mixes) builds a one-shot `PlayQueue` and hands it to `player.play`.

Goal: an Autoplay mode, Apple Music style. When the listener's own queue is about to run
out, the app appends tracks that fit what was playing, indefinitely, and Up Next shows
where the listener's picks end and Autoplay's begin. Off by default is fine; the point is
that an album can turn into an evening.

Non-goals for v1: sonic similarity (the server has none, see below), autoplay while
offline, any change to shuffle/repeat semantics, a "radio" entry point on the main screen.

## What Plex actually offers (measured)

The library is small enough to read whole: 54 artists, 108 albums, 1,200 tracks.

| Endpoint | Result | Use |
|---|---|---|
| `GET /library/metadata/{track}/nearest` | 200, `size: 0` | Sonic analysis is off (`/library/sections/3/prefs` → `musicAnalysis=false`). Plexamp's "sonically similar" is unavailable until it is enabled and run. |
| `GET /library/sections/3/stations` | 404 | Same reason. Plexamp's radios are gone with it. |
| `POST /playQueues?type=music&uri=…&continuous=1` | 200, one item | `continuous` does nothing for music. No server-side "keep going". |
| `GET /library/metadata/{artist}` | full record | `Genre`, `Style`, `Mood`, `Similar` (30 names from the metadata agent), `Country`. **The list endpoint `all?type=8` omits Style/Mood/Similar** and `includeFields` does not bring them back. |
| `GET /library/metadata/{album}` | full record | `Genre`, `Style`, `Mood` (Abbey Road carries 7 styles and 60 moods). `/albums` omits them too. |
| `GET /library/metadata/{k1},{k2},…` | one response | **Batching works.** All 54 artists in one 570 KB request, all 108 albums in one 377 KB request. |
| `GET /library/metadata/{artist}/related` | hubs | A `Similar Artists` hub (`artist.similar`) already narrowed to artists in the library: 2 for Antarctigo Vespucci. Album and track `related` are empty. |
| `all?type=10&artist.similar=A,B` | tracks | Tracks by library artists whose `Similar` list names A or B. Comma is OR; repeating the parameter is AND and returns nothing. |
| `all?type=10&artist.style=19`, `album.style=`, `album.mood=`, `mood=` | tracks | Tag filters work at track level through the parent. `sort=random` works. |
| Track records | | `ratingCount` (popularity, on 1,037 of 1,200 tracks), `skipCount`, `viewCount`, `lastViewedAt`, `userRating`. Tracks carry no `Mood` of their own despite `mood?type=10` listing 186. |

Coverage in this library: every artist has `Similar`, 51/54 have `Style` (105 distinct),
50/54 have `Mood`; 76/108 albums have `Style`, 73 have `Mood`. Genre is useless as a
signal: six values, 80% of the library is "Pop/Rock".

The `Similar` graph is sparse inside the library: 29 of 54 artists name at least one other
library artist, mean 0.9 edges per artist. Similar alone would run dry after two or three
artists, so style and mood overlap have to carry the rest.

Paging gotcha: `X-Plex-Container-Size` is ignored unless `X-Plex-Container-Start` is also
sent (a `sort=random` query "limited" to 5 returned all 1,200).

## Approach

**Rank artists client-side from a tag index built with two batched metadata requests,
then fill the queue in batches of 10 spread-shuffled tracks from the best-ranked artists.**
No server-side radio exists, and the one server-side similarity filter
(`artist.similar=`) is too sparse to stand alone. The index is a few hundred KB, two
requests, and makes ranking a pure function that `swift test` can cover. It also gives
future features (a "Similar artists" row on the artist page) for free.

Why not fetch per-artist `related` hubs: one request per seed artist, only the `Similar`
edge, no style/mood, and it still has to be merged and ranked on the client.

Why not `artist.similar=A,B&sort=random`: cheapest possible v0 (one request, no index),
and worth keeping in mind as a fallback, but it has no notion of "how similar", cannot
fall back to style/mood, and for half the artists in this library returns nothing.

### Seed

The seed is the listener's intent, not the whole queue. Track which entries were added by
a person (`play`, `playNext`, `enqueue`) versus by Autoplay. The seed is the artists of
the last five person-added entries, most recent weighted highest, plus any Autoplay entry
the listener hearted during the session. Skips (`next()` before 30% of the track) demote
that artist for the rest of the session.

### Ranking

`AutoplayPicker` (PlexKit, pure, generator-injected) scores every library artist against
the seed:

- `Similar` edge either direction, name-matched against library artist titles: strong.
- Style Jaccard overlap with the seed artists' styles: medium.
- Mood Jaccard overlap: weak. Moods are numerous and generic ("Energetic").
- Genre: tie-break only.
- Listener vetoes (`roster.hiddenArtistKeys`) exclude outright. Seed artists themselves
  are allowed but penalised, so an evening of Jeff Rosenstock does not become only Jeff
  Rosenstock. Artists picked in the last N batches are penalised the same way.

Artist scoring, not album or track scoring, because the tags live on artists and albums
and the graph edge is artist-to-artist. Albums add a second pass: within a chosen artist,
prefer albums whose style/mood overlap the seed's albums, so a Beatles seed pulls
psychedelic-era albums from a catalogue artist rather than any album at random.

Track choice inside the chosen artists: weight by `ratingCount` (popularity), skip anything
with `skipCount > viewCount`, apply a cooldown on `lastViewedAt` within the last day and
on anything already in this queue. Then spread-shuffle the batch by artist then album
(`PlexTrack.shuffleGrouping`), same as every other shuffle in the app.

### Trigger

Batches of 10. Fetch the first batch when the cursor lands on the last two person-added
entries, so the tracks are already appended, visible in Up Next, and prefetching by the
time the queue would have ended; `finish()` is then never reached. Refill when
`upcoming.count < 5`. Repeat All wins over Autoplay (a looping queue never runs out);
Repeat One is unaffected. Turning Autoplay off drops the not-yet-played Autoplay entries
and restores the finite queue. Offline (`library.isOffline`) or when the picker returns
nothing, fall through to `finish()` exactly as today.

### UI

- Up Next in `NowPlayingView` gets an "Autoplay" divider between person-added and
  Autoplay entries, and an infinity toggle in the Up Next header, where Apple Music puts
  it. The setting is per device in `UserDefaults`, owned by `AudioPlayer` like
  `streamQuality`.
- Settings gets the same toggle under Playback, next to Streaming Quality, so it is
  discoverable without an open queue.
- Lock screen and CarPlay need nothing: the queue simply keeps having a next track.

## Changes

### 1. PlexKit: tags and batched metadata
`Sources/PlexKit/PlexLibraryModels.swift`
- `PlexTag` (`tag: String`) and `Genre`/`Style`/`Mood`/`Similar` arrays on `PlexArtist`
  and `PlexAlbum`, decoded as empty when absent so the list endpoints still decode.
- `ratingCount`, `skipCount`, `viewCount`, `lastViewedAt` on `PlexTrack`.

`Sources/PlexKit/PlexLibrary.swift` + `LibrarySource`
- `func metadata(ratingKeys: [String]) async throws -> [PlexArtist]` and the album
  equivalent, over `/library/metadata/{a,b,c}`, chunked at 100 keys per request so a big
  library does not build a 50 KB URL. `OfflineLibrary` returns whatever the snapshot holds.

Fixture: capture `/library/metadata/{a,b,c}` for three artists and three albums into
`Tests/PlexKitTests/Fixtures/artists-detail.json` / `albums-detail.json`, tokens redacted.

### 2. PlexKit: the picker
`Sources/PlexKit/Autoplay.swift`, new.
- `struct TagIndex` built from `[PlexArtist]` + `[PlexAlbum]`: name→artist map,
  per-artist style/mood/genre sets, similar edges resolved to rating keys.
- `struct AutoplaySeed` (weighted artist keys, hearted keys, demoted keys, exclusion set of
  track keys).
- `AutoplayPicker.rankArtists(seed:index:hiding:) -> [(key, score)]` and
  `pickBatch(from tracks:[PlexTrack], ranked:, count: 10, using: &generator)`.
Tests: ranking prefers a Similar edge over style overlap over mood; vetoed artists never
appear; a single-artist seed yields other artists first; a deterministic generator gives a
stable batch; a track already in the exclusion set is never picked.

### 3. Index lifecycle
`App/ctunes/AppModel.swift`: after a `PlexLibrary` opens, build the index off the main
actor in a `Task` and hold it as `tagIndex: TagIndex?`. Rebuild when
`libraryGeneration` changes. Cache the two batched responses under
`Application Support/ctunes/Offline/<server>/tags.json` so a cold launch does not need
the network to have an index; refresh in the background. This is what an offline v2
would read.

### 4. AudioPlayer
`App/ctunes/AudioPlayer.swift`
- `autoplay: Bool` in `UserDefaults`, same pattern as `streamQuality`.
- `PlayQueue.Entry` gains an `origin: .person | .autoplay` (or `AudioPlayer` keeps a
  `Set<Entry.ID>` of Autoplay ids; the set is less invasive to `PlayQueue`).
- `maybeTopUp()` called from `loadCurrentItem` and after `remove`: if `autoplay`, not
  `repeatMode == .all`, online, and `upcoming.count < 5`, ask `AppModel` for a batch
  (through a closure injected at construction, so the player does not depend on
  `AppModel`) and `enqueue` it tagged as Autoplay. Guard against overlapping fetches with
  a single in-flight `Task`.
- `advance`: unchanged; by the time it would fail the batch is already there. If the fetch
  is slower than the last track, `finish()` runs and the batch, when it arrives, appends
  and resumes only if the queue ended within the last few seconds; otherwise it appends
  silently for the lock screen's play button to pick up.
- Skips feed the seed's demotion set; hearts on Autoplay entries feed its hearted set.
- Turning Autoplay off removes upcoming Autoplay entries.

### 5. Views
- `App/ctunes/Views/NowPlayingView.swift`: Autoplay divider row in Up Next, infinity
  toggle in the header, and the "ended" state still shown when Autoplay is off.
- `App/ctunes/Views/SettingsView.swift`: toggle next to Streaming Quality.

### 6. Debug hook and docs
- `CTUNES_DEV_AUTOPLAY=last` already starts on the final track three seconds from its end;
  pair it with a new `CTUNES_DEV_AUTOPLAY_ON=1` that flips the setting, so the top-up can
  be watched in the simulator in one launch.
- CLAUDE.md: the hook row, the batched-metadata and paging findings under Plex API
  constraints. PLAN.md: a milestone line.

## Cost and risk

- Index build: two requests, about 1 MB here; a 2,000-artist library would be ~40
  requests and 20 MB, which is why it is cached on disk and built in the background.
- Batch fill: one `tracks(forArtist:)` per chosen artist, typically three to five, then
  the picker runs locally. Under 200 ms on a LAN.
- Transcoding: each Autoplay item gets a fresh `session` like any other, and the no-stop
  rule on track-to-track moves already holds.
- Quality risk: a library where most artists share one style ("Indie Rock" here) will
  rank nearly everything the same. The `Similar` edge and the recent-pick penalty are
  what keep it from feeling like Shuffle All; tune weights against real listening.
- If sonic analysis is ever enabled on the server, `nearest` becomes a track-level
  signal that slots in ahead of the artist ranking without changing the queue mechanics.

## Verification

1. `make test`: picker and decoding tests pass with the fixtures.
2. `make live-test`: add one test that batch-fetches three artists and asserts `Similar`
   and `Style` decode non-empty.
3. `make sim-run` with `CTUNES_DEV_TOKEN`, `CTUNES_DEV_ALBUM`, `CTUNES_DEV_AUTOPLAY=last`,
   `CTUNES_DEV_AUTOPLAY_ON=1`, `CTUNES_DEV_NOWPLAYING=1`: the queue does not end; Up Next
   shows the divider and ten tracks from other artists; none is vetoed by a seeded
   listener (`CTUNES_DEV_LISTENERS=<artistKey>`); toggling Autoplay off in the header
   empties the Autoplay section and the ended state returns at the last track.
4. On the phone: play an album, lock it, let it run past the end; the lock screen keeps
   advancing with correct metadata, and CarPlay's Up Next shows the appended tracks.
