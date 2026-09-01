# ctunes — weekend Plex music client for iOS

## Context

Plexamp is a Plex-authored client; nothing about the Plex Media Server API is private to it. PMS speaks plain HTTP with a token header, and the music surface (libraries, artists, albums, tracks, part files) is reachable by any authenticated client. The goal here is the smallest thing that is genuinely a music player rather than a demo: sign in, browse the library, play an album, and control it from the lock screen with the screen off.

Target is a real device on the same Wi-Fi as the server, from the first build, because background audio and remote-control behavior cannot be meaningfully validated in the simulator.

Toolchain confirmed present: Xcode 26.6, Swift 6.3, iOS 26.5 SDK.

## Decisions already made

- **Direct play only.** `AVPlayer(url: partURL)` against the original file. No transcode session lifecycle, no teardown bookkeeping, no restart-on-seek. MP3/AAC/ALAC/FLAC all decode natively on iOS 26. The transcode path gets added when a file actually fails to play or when listening off-LAN — the work is deferred, not wasted.
- **PIN link flow** for auth, not credential POST. Survives 2FA, and the token is the same either way.
- **Connect over the `plex.direct` HTTPS URI**, not the raw LAN IP. It resolves to the local address but carries a valid TLS cert, which sidesteps App Transport Security exceptions entirely.
- **Two-part project**: a `PlexKit` SPM package with no UIKit/SwiftUI dependency, and a thin app target. The package stays testable from the command line without booting a simulator.

## Layout

```
ctunes/
├── Package.swift                     PlexKit, iOS 26 platform
├── Sources/PlexKit/
│   ├── PlexClient.swift              actor: URLSession + header injection
│   ├── PlexAuth.swift                PIN flow, Keychain persistence
│   ├── PlexModels.swift              Codable DTOs for MediaContainer
│   ├── PlexServer.swift              resource discovery, connection ranking
│   └── PlexLibrary.swift             sections, artists, albums, tracks, URLs
├── Tests/PlexKitTests/
│   └── PlexModelsTests.swift         decode fixtures captured from the server
└── App/
    ├── ctunesApp.swift
    ├── AppModel.swift                @Observable root state
    ├── AudioPlayer.swift             AVQueuePlayer, session, remote commands
    └── Views/
        ├── AuthView.swift
        ├── LibraryView.swift         artists
        ├── ArtistView.swift          albums
        ├── AlbumView.swift           tracks
        └── NowPlayingView.swift
```

## Milestones

Roughly twelve working hours, ordered so each one ends somewhere you can stop.

### M0 — Scaffold and signing (~30m)

Create the SPM package and an iOS app target. Set `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER = com.colbyr.ctunes`, automatic signing. In Info.plist set `UIBackgroundModes = ["audio"]` and `NSLocalNetworkUsageDescription`. Build to the device and confirm a blank view launches — get provisioning pain out of the way before any real code exists.

### M1 — Auth (~2h)

Every plex.tv and PMS request carries identity headers. Build them once in `PlexClient` and never hand-roll them again:

```
X-Plex-Client-Identifier   stable UUID, generated once, stored in Keychain
X-Plex-Product             ctunes
X-Plex-Version             1.0
X-Plex-Device              iPhone
X-Plex-Platform            iOS
Accept                     application/json      ← without this you get XML
```

The `X-Plex-Client-Identifier` must be **stable across launches**. Regenerate it and the server treats every launch as a new device, littering your account with authorized-device entries.

Flow:
1. `POST https://plex.tv/api/v2/pins?strong=true` → `{ id, code }`
2. Open `https://app.plex.tv/auth#?clientID={uuid}&code={code}` via `ASWebAuthenticationSession`
3. Poll `GET https://plex.tv/api/v2/pins/{id}` every ~1s until `authToken` is non-null (give up after ~120s)
4. Store the token in Keychain, not `UserDefaults`

### M2 — Server discovery (~1h)

`GET https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1` with the token. Filter to entries whose `provides` contains `server`. Each carries a `connections[]` array; rank them:

1. `local == true && relay == false` — the plex.direct HTTPS URI on your LAN, the one you want
2. `relay == false` — remote direct
3. relay — last resort, bandwidth-capped

Probe the chosen URI with `GET /identity` before committing to it, and fall through the ranking on failure. Persist the winner so later launches skip the round trip, but re-resolve when a request fails — LAN addresses move.

### M3 — Browse (~3h)

```
GET /library/sections                          → filter type == "artist"
GET /library/sections/{key}/all?type=8         → artists
GET /library/metadata/{ratingKey}/children     → albums of an artist
GET /library/metadata/{albumKey}/children      → tracks of an album
```

Everything comes back wrapped in a `MediaContainer`. Artwork is a relative `thumb` path — build a display URL through the photo transcoder so you aren't pulling full-size covers into list cells:

```
{server}/photo/:/transcode?width=200&height=200&url={thumb}&X-Plex-Token={token}
```

Three `NavigationStack` screens: artists → albums → tracks. `AsyncImage` is adequate at this scope.

### M4 — Playback and lock screen (~3h)

This is the milestone that requires the device, and the ordering inside it matters — a wrong `AVAudioSession` category fails silently by playing fine in the foreground and dying on lock.

1. `AVAudioSession.sharedInstance().setCategory(.playback)` then `setActive(true)`. Do this **before** the first `play()`.
2. Stream URL is the part key against the server, token appended:
   `{server}{media[0].part[0].key}?X-Plex-Token={token}`
3. `MPNowPlayingInfoCenter.default().nowPlayingInfo` — title, artist, album, artwork, `MPMediaItemPropertyPlaybackDuration`, and `MPNowPlayingInfoPropertyElapsedPlaybackTime`. Refresh elapsed time on a periodic time observer, not a `Timer`.
4. `MPRemoteCommandCenter` — `playCommand`, `pauseCommand`, `nextTrackCommand`, `previousTrackCommand`, and `changePlaybackPositionCommand` for lock-screen scrubbing. Each handler returns `.success`.

Verify by locking the phone and confirming metadata, artwork, and working transport controls.

### M5 — Queue and Now Playing (~3h)

`AVQueuePlayer` built from the album's tracks, entering at the tapped index. Wire `AVPlayerItemDidPlayToEndTime` to advance now-playing metadata as items roll over. Previous-track behavior should follow the platform convention: restart the current track if past ~3 seconds, otherwise step back.

`NowPlayingView` — large artwork, title/artist/album, a scrubber bound to the same periodic observer feeding the lock screen, transport controls, and the upcoming queue below.

## Gotchas

- **Local network permission.** iOS prompts on first connection to a LAN address, and `plex.direct` still resolves to one. Denied, it fails as a generic connection error with nothing pointing at permissions. Check Settings → Privacy → Local Network first when the server is unreachable on device but fine from `curl`.
- **`Accept: application/json`.** Omit it and PMS returns XML, and your `JSONDecoder` throws something unhelpful.
- **Token in query vs. header.** `AVPlayer` won't attach custom headers to media requests, so the stream URL needs `?X-Plex-Token=`. Everything else uses the header.
- **Swift 6 strict concurrency.** `PlexClient` as an actor; UI state `@MainActor`. Sort the isolation out while the code is small rather than retrofitting.
- **Loose `MediaContainer` typing.** Numeric fields arrive as strings in places. Write the DTOs against real captured responses, not assumptions — hence the fixture tests.

## Verification

- `swift test` in the package — model decoding against fixtures captured from the live server via `curl`.
- Build and run on device each milestone; `xcodebuild -scheme ctunes -destination 'platform=iOS,name=<device>'`.
- **M4 acceptance, done manually on the device:** start an album, lock the phone, confirm audio continues, artwork and metadata appear on the lock screen, and play/pause/next/previous/scrub all work from there.
- **M5 acceptance:** play an album end to end without touching the phone; tracks advance and lock-screen metadata follows.
- Codec sanity check against the real library, confirming the direct-play decision:
  ```
  curl -s "{server}/library/sections/{id}/all?type=10&X-Plex-Token={token}" \
    | grep -o 'audioCodec="[^"]*"' | sort | uniq -c | sort -rn
  ```
  Anything outside mp3/aac/alac/flac in meaningful quantity means the transcode fallback moves up the list.

## Explicitly out of scope

Search, offline caching, gapless and crossfade, sonic-analysis radio, loudness leveling, waveform scrubbing, CarPlay, playlists. Gapless in particular is not a weekend item — `AVQueuePlayer` handles it poorly and doing it properly means a custom `AVAudioEngine` pipeline, which is the single largest piece of work in a Plexamp-class client.
