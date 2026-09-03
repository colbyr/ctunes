# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ctunes is an iOS Plex music client — sign in, browse a music library, play an
album with lock screen controls. `PLAN.md` holds the milestone status and the
reasoning behind the design decisions below.

## Commands

```
make test        # PlexKit tests, native on macOS, ~40ms, no network or simulator
make live-test   # adds 2 tests against the real server (token from 1Password)
make token       # PIN flow → stores a dev token in 1Password
make sim         # build for simulator
make sim-run     # build, install, launch in simulator
make run         # build, install, launch on the attached iPhone
make devices     # list attached devices
```

Run one test by name: `swift test --filter <TestName>`. The suite-name filter
(`--filter "Live server"`) does **not** match swift-testing suites — gate live
tests with the `PLEX_LIVE` environment variable instead, which `make live-test`
sets.

Device targets auto-detect the first connected iPhone; override with
`make run DEVICE=<udid>`. Device builds need Developer Mode on the phone
(Settings → Privacy & Security) and a valid signing identity.

## Architecture

Two pieces, split so the interesting logic is testable without a simulator:

- **`Sources/PlexKit/`** — an SPM package with no UIKit or SwiftUI dependency.
  It also declares a macOS platform purely so `swift test` runs natively in
  seconds rather than booting a simulator.
- **`App/ctunes/`** — the SwiftUI app. `App/ctunes.xcodeproj` is hand-written
  using file-system synchronized groups, so **new source files need no project
  edits** — they are picked up from the directory automatically.

Swift 6 language mode with `SWIFT_STRICT_CONCURRENCY = complete`, deployment
target iOS 26.

### Flow

`AppModel` (`@MainActor @Observable`) owns the state machine:
`loading → signedOut → linking → connecting → signedIn`, plus `connectFailed`.
On launch it restores a keychain token, discovers a server, and opens a
`PlexLibrary`. Views read `model.library` and fetch in `.task`.

`PlexClient` is an actor that injects the Plex identity headers in one place;
no call site should build them by hand. `PlexAuth`, `PlexServerDirectory` and
`PlexLibrary` are actors layered on it.

`AudioPlayer` (`@MainActor @Observable`, in the app target) wraps a single
`AVPlayer` and advances the queue by hand on `AVPlayerItemDidPlayToEndTime`.
AVQueuePlayer's implicit advancement lets the index, now-playing metadata and
UI drift apart. Gapless playback is out of scope and would need a different
design. **`AVPlayerItemDidPlayToEndTime` is not reliable after a seek near the
end of a track**: the clock runs past the item's duration at rate 1 and the
notification never posts, so the periodic time observer also treats
`currentTime >= duration` as the end, guarded by a per-item flag.

## Plex API constraints

These were measured against a real server; several contradict what the API
appears to offer.

- **Albums for an artist come from
  `/library/sections/{key}/all?type=9&artist.id={ratingKey}`, never
  `/library/metadata/{artist}/children`.** The children endpoint under-reports
  for ~15% of artists (8 albums where 13 exist; 0 where 1 exists).
- **`local: true` does not mean reachable.** A server advertises one connection
  per network interface, several of which are virtual adapters. Probe every
  connection concurrently and let reachability decide; rank only breaks ties.
  Probing in rank order stalls for the full timeout on each dead address.
- **`Accept: application/json` is required** or the server answers in XML and
  decoding fails with an unrelated-looking error.
- **`X-Plex-Client-Identifier` must be stable across launches**, or every launch
  registers a new device on the account.
- **`AVPlayer` won't attach custom headers to media requests**, so stream URLs
  carry `?X-Plex-Token=`; everything else uses the header.
- **`forwardUrl` is ignored for a custom scheme.** Nothing redirects back to the
  app, so auth polls while the browser sheet is open and cancels it on success.
- Response typing is loose: `ratingKey` is a string, `hasThumbnail` is `"1"`.
  Write DTOs against captured fixtures, not assumptions.
- A server can expose several libraries of type `artist` (audiobooks included),
  so the section choice is persisted rather than inferred.
- **Ratings: `PUT /:/rate?identifier=com.plexapp.plugins.library&key={ratingKey}&rating=N`**,
  `N` in 0–10, `-1` clears. The app treats only a full 10 as a favorite. Query
  favorite tracks with `/library/sections/{key}/all?type=10&userRating=10` —
  exact match. `userRating>>=10` returns nothing even though `>>=1` works.

## Concurrency hazards hit here

Both of these compiled fine and crashed at runtime:

- **`MPMediaItemArtwork`'s request handler runs on MediaPlayer's own queue.**
  Building that closure in a main-actor context traps the isolation check when
  the lock screen asks for artwork. Build it in a detached task.
- **`MainActor.assumeIsolated` traps** in an `AVPlayer` periodic time observer
  even with `queue: .main`. Hop to the actor instead of asserting isolation.
- `@Observable` rewrites stored properties into computed ones, so
  `nonisolated(unsafe)` silently has no effect unless the property is also
  `@ObservationIgnored`.
- SwiftUI observation registers only properties **read while the body runs**. A
  short-circuited read (`scrubbing ?? player.currentTime`) drops the dependency
  and the view stops updating. Read observable state unconditionally.

## Testing

`MockURLProtocol` registers handlers **per session**, not in a global slot —
swift-testing runs tests in parallel and shared handler state makes tests answer
each other's requests, surfacing as spurious `-1011` errors.

`Tests/PlexKitTests/Fixtures/` holds real server responses with tokens redacted.
Prefer extending these over inventing payloads. `LiveServerTests` is disabled
unless `PLEX_LIVE` is set and reads credentials from `PLEX_DEV_TOKEN` /
`PLEX_DEV_CLIENT_ID`.

## Debug-only hooks

Compiled out of release builds; used to drive the app in a simulator, where
there is no way to tap. Pass via `SIMCTL_CHILD_<VAR>` to `simctl launch`.

| Variable | Effect |
|---|---|
| `CTUNES_DEV_TOKEN` | skips sign-in with a token from the environment |
| `CTUNES_DEV_ALBUM` | `ratingKey\|title\|artist\|artistKey`, pushes that album onto the stack |
| `CTUNES_DEV_AUTOPLAY` | `1` starts playback once tracks load; `last` starts on the final track 3s from its end, so the queue finishes at once |
| `CTUNES_DEV_NOWPLAYING` | `1` opens the Now Playing sheet |
| `CTUNES_DEV_ENQUEUE` | `1` appends the album to the queue again, so Up Next has duplicates |
| `CTUNES_DEV_SEARCH` | `1` activates the search pill a few seconds after launch; any other text also seeds it as the query |
| `CTUNES_DEV_LISTENERS` | seeds "Laura" (listening) and "Kids" onto an empty roster; an artist ratingKey instead of `1` also vetoes it for Laura |
| `CTUNES_DEV_LISTENERS_SHEET` | `1` opens the Listeners sheet once albums load; `detail` opens the first listener's page |
| `CTUNES_DEV_MIX` | `artist` or `album` pushes that mix builder; `artist:2899,649` also preselects those ratingKeys. With `CTUNES_DEV_AUTOPLAY` set, the mix plays once the pool loads |

The dev token lives in 1Password (`op://Private/ctunes dev token`), never on
disk; `scripts/plex-token.sh` reads it and caches each field in the login
keychain for 24h so 1Password prompts once a day, not per make target.
`scripts/plex-token.sh --clear` drops the cache (`make token` does this too).
`.plex-dev.json` is a retired path kept in `.gitignore` as a backstop.
