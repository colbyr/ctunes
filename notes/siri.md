# Siri on iOS 27

Written 2026-09-16, before any of it was built. Everything below about
iOS 27 was checked against Apple's App Intents docs and the WWDC26 sample
project, not remembered; the "Verify" section lists what the docs did not
settle.

## Where the app stands

Siri reaches ctunes through one door: `MPRemoteCommandCenter`, wired in
`AudioPlayer.configureRemoteCommands()`. So "pause", "skip this", "turn on
shuffle" work on whatever is already playing, from the lock screen, a car
and Siri alike. Nothing else does. "Play the Velvet Underground in Tunes"
gets a shrug, "I like this song" does nothing, and Shortcuts sees no
actions at all. There is no App Intents code, no `NSUserActivity`, no
Spotlight index and no intents extension.

That was the right amount of Siri to have. The old way to do more was
SiriKit's media domain (`INPlayMediaIntent` in an Intents extension,
`INMediaUserContext`, `application(_:handlerFor:)`), a lot of ceremony for
a search-and-play handoff. Apple deprecated SiriKit at WWDC26 and App
Intents is now the only way Siri calls into an app, so building on the
old path today would be building on a two-year clock.

## What iOS 27 offers

App Intents grew **app schemas**: predefined intent, entity and enum shapes
that Siri already understands, adopted with `@AppIntent(schema:)`,
`@AppEntity(schema:)` and `@AppEnum(schema:)`. The `.audio` domain is the
one for a music player. From
[the domain page](https://developer.apple.com/documentation/appintents/app-schema-domain-audio):

| Schema | Siri phrases it answers | ctunes |
|---|---|---|
| `playAudio` | "Play music." "Play Loveless by My Bloody Valentine." "Shuffle my favorites." | yes |
| `updateAudioAffinity` | "I like this song." "I don't like this song." | yes: the heart |
| `addToPlaylist` | "Add this song to my running playlist." | yes |
| `warmupAudioQueue` | none; Siri calls it to set the queue before it says "Playing…" | later |
| `addToLibrary` | "Add this song to my library." | no: a Plex library has no add |
| `createStation` | "Play more like this." | maybe: an artist mix |
| `recognizeAudio` | "What song is this?" | no |

Entity schemas: `song`, `album`, `artist`, `playlist`, `songCollection`
and a dozen podcast, radio and audiobook shapes we do not need. Enum
schemas: `playbackAttributes` (`shuffle`, `repeat`), `queueInsertionLocation`
(`next`, `tail`), `affinityState` (`like`, `dislike`, `unset`).

What the sample project
([Integrating your music app with Apple Intelligence](https://developer.apple.com/documentation/appintents/integrating-your-music-app-with-apple-intelligence),
the CosmoTunes zip linked from that page, WWDC26 session 343) settles:

- **Intents run in the app process**, on the main actor if marked so,
  and reach the app's objects through `@Dependency`, registered with
  `AppDependencyManager.shared.add(dependency:)` at launch. No extension,
  no XPC to our own code.
- **No entitlement.** The sample's `.entitlements` is an empty dict and
  its `Info.plist` has only `UIBackgroundModes: audio`, which we have.
- **Resolution is a search we run.** Siri hands the app an `AudioSearch`
  (from the new `MediaIntents` framework) through an `IntentValueQuery`
  whose `values(for:)` switches on `input.criteria`: `.searchQuery(String)`
  for a named thing, `.unspecified` for "play music", `.url`. The query
  returns `[AudioEntity]`, a `@UnionValue` enum over the entity structs,
  and Siri picks from what came back. Nothing has to be indexed ahead of
  time for "play X" to work; the semantic index is a separate,
  optional layer.
- **"This song" comes from Now Playing.** The sample drives the lock
  screen with the new `NowPlaying` framework: a `MediaSession<T>` wrapping
  a `MediaSessionRepresentable` model whose `content` is a `MusicContent`
  carrying `appEntityIdentifiers` (song, album, artist, playlist), whose
  `commands` are `[MediaCommand]` closures, and whose `playbackSnapshot`
  is state plus elapsed plus timestamp, the rate model we already follow.
  The session becomes primary through
  `requestToBecomeApplicationPrimary()` on first play. There is no
  `MPNowPlayingInfoCenter` or `MPRemoteCommandCenter` in the sample.
- **Spotlight is opt-in per entity**: `IndexedEntity` on the struct,
  `IndexedEntityQuery` on its query for reindex requests, and
  `CSSearchableIndex(name:).indexAppEntities(_:)` to push. Indexed
  entities join the semantic index, which is what lets Siri answer over
  content ("that album I played last week") rather than only match text.
- **Donations** are `IntentDonationManager.shared.donate(intent:)` of a
  filled `PlayAudioIntent` on each play from the UI, so Siri suggestions
  and "resume" style requests learn what the person does.
- **Testing** is `AppIntentsTesting` (session 295) from a UI test target:
  `playAudioDefinition.makeIntent(audioEntity: song).run()` drives the
  intent across the real system path.
- The sample's deployment target is 27.0 and the schema types have no
  availability annotations of their own. Xcode 27's SDK ships
  `NowPlaying.framework` and `MediaIntents.framework`.

Two things it does not settle, both in "Verify" below: whether the new
`NowPlaying` session can coexist with our `MPNowPlayingInfoCenter` writes
and the CarPlay Now Playing template, and whether a schema intent is
reachable on a phone without Apple Intelligence.

## What it would take

### 0. Deployment target

`IPHONEOS_DEPLOYMENT_TARGET` is 26.0. Every schema type is iOS 27, so
either bump the target to 27 or wrap the whole `Siri/` directory in
`@available(iOS 27, *)` and register the dependencies under the same
check. The bump is simpler and the phones this runs on are on 27; the
Mac build is "Designed for iPad" and follows. Decide this first, because
it decides whether milestone 1 below is worth doing on its own.

### 1. App Shortcuts (works on iOS 26, and without Apple Intelligence)

**Built 2026-09-17** (`App/ctunes/Siri/`), as written below plus a
Shuffle Playlist intent, since a phrase can only bind an entity
parameter and "Shuffle Driving in Tunes" wanted its own. What the
build settled:

- `AppModel.ready()` polls `isSettled` every 100ms rather than racing an
  `Observations` stream against a sleep in a task group: that pattern
  trips a Swift 6 region-isolation checker bug ("pattern that the
  region-based isolation checker does not understand"). Only an intent
  waits there, for seconds.
- `IntentPlayback` reads the library through the model on every call,
  not from a copy taken at `ready()`: a fetch that fails runs
  `connectionLost`, which may swap the library in place, and the retry
  has to see the new one.
- The intents don't use `LibraryActions`: it needs a
  `NowPlayingPresentation` and a `LibraryNavigator`, which a view owns.
  The paths are the same as `CarPlayController`'s.
- "Play On Rotation" is the top ten albums by the root's rotation
  score, each front to back, in that order; the dialog names the first.
- `INAlternativeAppNames` = ["Tunes"] in `Info.plist`, so "in Tunes"
  matches as well as "in Tunes for Plex".
- The App Intents metadata is extracted by the build with no project
  change (`Metadata.appintents` in the bundle lists the five actions).
- Verified in the simulator through `CTUNES_DEV_INTENT`: every intent
  online, `rotation` and `favorites` offline from the snapshot and the
  pinned files, `favorites` signed out (spoken "Sign in to Tunes
  first."), `resume` on an empty queue. Not yet spoken to Siri on a
  phone: that, and Shortcuts listing the actions, are the remaining
  hand checks.

Plain `AppIntent`s conforming to `AudioPlaybackIntent` (iOS 16) behind an
`AppShortcutsProvider`, phrases registered at install:

- "Shuffle my favorites in Tunes" → `favoriteTracks` minus vetoes,
  spread shuffle, the Favorites page's Shuffle card.
- "Play On Rotation in Tunes" → the top of `Rotation`, the browse root's
  hero.
- "Play \(.$playlist) in Tunes" → a `PlaylistEntity` parameter whose
  query's `suggestedEntities()` is `model.playlists`, so Siri learns the
  playlist names at registration.
- "Resume in Tunes" → `player.resume()`, useful in a car.

These are the fallback that works on every phone, with no schema and no
Apple Intelligence, and they are a day. They also force the one piece of
plumbing everything else needs: an intent can fire with the phone locked
and no window, so it must wait for `AppRuntime.shared` to bootstrap. Add
an `await model.ready()` that returns once the state leaves `loading` and
`connecting`, with a timeout, and a spoken error (`AppIntentError` wrapping
a `CustomLocalizedStringResourceConvertible`) for `signedOut` and
`connectFailed`. `.offline` is fine: whatever is on disk plays.

### 2. Entities and the search Siri calls (the payoff)

`App/ctunes/Siri/`, picked up by the synchronized group:

- `ArtistEntity`, `AlbumEntity`, `SongEntity`, `PlaylistEntity`, each a
  thin wrapper over the Plex DTO under `@AppEntity(schema: .audio.…)`.
  The schema fixes the property names (`title`, `artistName`, `artists`,
  `album`, `albumTitle`, `owner`…); ours are `title`, `parentTitle`,
  `grandparentTitle`, so each entity is a mapping, not the DTO itself.
  `id` is `"\(serverIdentifier)/\(ratingKey)"`: rating keys are per
  server, and an id Siri saved in a donation or the index must not
  resolve to the wrong thing after a server swap.
- `AudioEntity`, the `@UnionValue` over the four.
- `EntityQuery.entities(for:)` per type resolves ids Siri hands back:
  artist and album from the catalog, playlist from `model.playlists`, a
  song by fetching its album's tracks (`tracks(inAlbum:)`), which is also
  how it will play.
- `AudioEntity.SiriQuery: IntentValueQuery` over `AudioSearch`:
  - `.searchQuery(q)` → `LibrarySearch.hits` with the catalog's artists
    and albums, `searchTracks(inSection:query:)` from the server, the
    playlists, and `roster.hidden`, the same ranking the search page
    shows; return the top few of each kind as the union. Offline, the
    same function over the snapshot and the tracks on disk, as the
    search page already does.
  - `.unspecified` ("play music", "play something") → the On Rotation
    top albums, so Siri has a pick.
  - `.url` → nothing.

The catch is the catalog. `LibraryCatalog` is `@State` on `LibraryView`,
so with no window there is none. Move it to `AppRuntime` next to the
model and player (`LibraryView` reads it from there; nothing else
changes), and let the query fill it when it is empty with the browse
root's own fetches, `albums(inSection:)` and `artists(inSection:)`, which
the snapshot answers offline. That is also what item 5 indexes from.

### 3. Play

`PlayAudioIntent` under `@AppIntent(schema: .audio.playAudio)`,
`AudioPlaybackIntent`, `@MainActor perform()`:

| `audioEntity` | queue |
|---|---|
| artist | the artist page's Play: `tracks(forArtist:)` minus `hides(track, within: .artist)`, in release order |
| album | `tracks(inAlbum:)` minus `hides(track, within: .album)` |
| song | its album from that song, as a search result plays |
| playlist | `items(inPlaylist:)` minus `hides(track)`, as the page plays |

`playbackAttributes` `.shuffle` → the spread shuffle before `play`,
`.repeat` → `repeatMode`. `queueLocation` `.next` → `playNext`, `.tail` →
`addToQueue`, none → `play(_:startingAt:library:)`. All of it is existing
`AudioPlayer` and `LibrarySource` calls; the intent is the glue and the
veto rules from `notes/listeners.md`. Nothing to play is a spoken error,
the same text `LibraryNavigator.notice` alerts.

`warmupAudioQueue` is the same resolution without the `play`, returning
a `WarmupAudioQueueResult` whose id names the prepared queue. Siri uses
it to cut the gap between the answer and the audio. Second pass.

### 4. Heart, playlist, search

- `UpdateAudioAffinityIntent` (`.audio.updateAudioAffinity`): song only,
  `.like` → `setFavorite(key, true)`, `.unset` → `false`, `.dislike` →
  refused with a line saying Plex has no dislike (or treat as unset;
  pick unset). Album, artist and playlist targets throw. Offline throws:
  hearts are read-only there. Returns `ProvidesDialog` ("Hearted Sunday
  Morning") and a `ShowsSnippetView` with the row, since Siri renders it.
- `AddToPlaylistIntent` (`.audio.addToPlaylist`): song into a regular
  playlist through `model.add(_:to:)`; a smart playlist or offline throws;
  zero added means "already there", say so.
- `.system.search` intent: seeds the search pill with `criteria.term` and
  opens the page, through `LibraryNavigator`, the way `CTUNES_DEV_SEARCH`
  seeds it today. Cheap, and it is how "search Tunes for Nico" lands in
  the app instead of a Siri sheet.

The "this song" form of every one of these needs item 6.

### 5. Spotlight and donations

`IndexedEntity` on artist, album and playlist, indexed from the catalog
when the browse root's fetch lands and the list changed, and
`IndexedEntityQuery` reindex hooks on their queries. Tracks stay out of
the index except favorites: a library is tens of thousands of songs and
Siri finds a song through the value query anyway. Index per server and
drop it on sign-out and on a server swap. Then
`IntentDonationManager.shared.donate(intent:)` of a `PlayAudioIntent` at
the player's `play(_:startingAt:library:)` for a whole album, artist or
playlist, so "play what I had on this morning" has something to find.

### 6. Now Playing on the new framework

The only way Siri knows what "this song" is, is the
`appEntityIdentifiers` on `MusicContent` in a `NowPlaying.MediaSession`.
`MPNowPlayingInfoCenter` has no slot for it. So the affinity, playlist
and "more like this" phrases in their natural form mean replacing the
lock screen plumbing in `AudioPlayer`:

- a `MediaSessionRepresentable` model beside the player: `content` built
  from `currentTrack` plus the entity ids, `commands` mapped onto
  `resume`, `pause`, `next`, `previous`, `seek`, shuffle and repeat, and
  `playbackSnapshot` published where `updateNowPlayingRate` writes today;
- `requestToBecomeApplicationPrimary()` on first play;
- `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` removed, not kept
  beside it.

This is the risky one. Every rule in `CLAUDE.md` about now-playing was
paid for on a car head unit: rate follows `timeControlStatus`, the
dictionary is written on state changes only, artwork is built off the
main actor. Each has to be re-proven on the new API, and CarPlay's
`CPNowPlayingTemplate` and the lock screen both have to be checked on
hardware. Do it as its own milestone after 2 to 4 ship with entity
phrasing only ("heart Sunday Morning" works before "heart this" does).

## Order

| Milestone | Gets | Size |
|---|---|---|
| S1 App Shortcuts, `model.ready()` | favorites, On Rotation, playlists by name, resume; works on 26. **Done 2026-09-17**, simulator-verified; Siri on a phone still to check | a day |
| S2 entities, value query, catalog to `AppRuntime` | "Play Loveless", "Play the Velvet Underground", "Shuffle Sunday Morning" | two to three days |
| S3 heart, add to playlist, search | "Heart Sunday Morning", "Add Femme Fatale to Driving", "Search Tunes for Nico" | a day |
| S4 `NowPlaying` session | "this song" forms, "play more like this" | two days plus hardware checks |
| S5 Spotlight, donations, warmup | Siri over history, faster starts | a day |

S1 is worth shipping on its own even if the rest waits. S2 is where
Siri becomes a way to use the app rather than a remote for it.

## Testing

- A UI test target with `AppIntentsTesting`, the first test target the
  app has (PlexKit's tests do not launch the app). Drive
  `playAudioDefinition.makeIntent(audioEntity:)`,
  `updateAudioAffinityDefinition`, the value query with a search string,
  and assert on the player through a debug intent that reports the queue,
  the way `CTUNES_DEV_*` hooks drive the simulator today.
- Add `CTUNES_DEV_INTENT` as a hook: `play:album:<rk>` or `search:<q>`
  runs the intent on launch and logs the result, so a simulator run shows
  the path without Siri.
- Siri itself on the phone, locked, and once in the car.

## Verify before building

1. **Coexistence.** Whether a `NowPlaying.MediaSession` that becomes
   primary and `MPNowPlayingInfoCenter` writes fight, and whether
   `CPNowPlayingTemplate` reads the new session. The sample has neither
   the old API nor CarPlay. If the template does not, S4 is blocked on
   Apple.
2. **Reach without Apple Intelligence.** Schema intents are presented as
   Apple Intelligence features. Check on an older phone whether "Play X
   in Tunes" hits the value query, or only the App Shortcut phrases do.
   That decides how much S1 has to cover.
3. **Rating key ids.** Whether `EntityIdentifier` and the index accept a
   slash in `id`, else use another separator.
4. **Query latency.** Siri times the value query out; the server track
   search is one request and the catalog is local, so it should be
   fine, but measure it on cellular against the remote address.

## Sources

- [Audio domain](https://developer.apple.com/documentation/appintents/app-schema-domain-audio),
  [`playAudio`](https://developer.apple.com/documentation/appintents/appschema/audiointent/playaudio),
  [`song`](https://developer.apple.com/documentation/appintents/appschema/audioentity/song),
  [`IntentValueQuery`](https://developer.apple.com/documentation/appintents/intentvaluequery),
  [`IndexedEntity`](https://developer.apple.com/documentation/appintents/indexedentity),
  [`AudioPlaybackIntent`](https://developer.apple.com/documentation/appintents/audioplaybackintent)
- [Integrating your music app with Apple Intelligence](https://developer.apple.com/documentation/appintents/integrating-your-music-app-with-apple-intelligence),
  the CosmoTunes sample; its `AppIntents/Audio/`, `Managers/CosmoTunesMediaSession.swift`
  and `CosmoTunesApp.swift` are the reference for items 2, 3 and 6
- WWDC26 sessions [240 Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/),
  [343 Explore advanced App Intents features for Siri and Apple Intelligence](https://developer.apple.com/videos/play/wwdc2026/343/),
  295 Validate your App Intents adoption with AppIntentsTesting
- [WWDC26 Apple Intelligence guide](https://developer.apple.com/wwdc26/guides/apple-intelligence/)
