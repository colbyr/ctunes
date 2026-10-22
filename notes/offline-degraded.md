# Offline on a poor connection: the library is on disk, the screens never read it

## Context

Reports from the road, Oct 2026: the app opened on a weak cellular link with
most of the library downloaded, and still couldn't start playback until the
network came good. Two symptoms seen more than once:

- "Shuffle Favorites" says there are 0 favorites.
- A downloaded album opens to a spinner where the track list should be.

The theory going in was that the tracks are downloaded but the library's
structure only exists with a network. The audit says: half right. The
structure *is* persisted (`notes/offline.md`): the `LibrarySnapshot` (albums,
artists, favorites, history, playlists), a track list per browsed or pinned
album under `<server>/albums/<rk>.json`, the favorites group in
`favorites.json`, the items of every playlist opened. The problem is that all
of it is read through `OfflineLibrary`, and `OfflineLibrary` is installed only
when discovery fails outright. A connection that is bad rather than dead never
takes that path.

## Findings

### 1. A degraded link counts as online, and online never reads disk

Discovery is a `/identity` probe, a few hundred bytes, so on a weak link it
answers and `AppModel.attemptConnect` installs a `PlexLibrary`. From then on
every screen fetches from the server; nothing consults the saved track lists or
`favorites.json` while the library is online.

The album spinner is this path. `TracksView.load` asks the server; the request
sits on the client's 10s timeout; `connectionLost` reprobes, the probe answers
(it is tiny), the generation bumps and the fetch runs again; only a second
failure inside the 15s rediscovery throttle flips to the snapshot. That is
25–45s of spinner when requests time out. When bytes trickle it never ends:
`timeoutIntervalForRequest` is an idle timeout that resets on every packet, and
the session set no `timeoutIntervalForResource`, so a slow transfer of the
album list or the favorites could run for minutes without failing.

### 2. The snapshot overwrote the favorites with an empty list

The likely direct cause of "0 favorites". `MusicView.load` swallowed a
favorites failure (`try? await favoriteTracks`) and then wrote the snapshot
with `favorites ?? []`. `AppModel.snapshot` saved that and also called
`OfflineStore.setFavorites([])`, which with the favorites pin on moves every
favorites file out of the pinned root into the LRU cache
(`TrackCache.unpin`). The next launch on the snapshot read an empty favorites
list: the card said "0 tracks", the tap had nothing to play, and the files
were evictable.

The albums request landing while the favorites request fails is exactly the
Wi-Fi to cellular handoff: the first request goes out on the LAN address, the
second finds it gone.

### 3. A page that loaded from disk went blank when the server was found

Four screens cleared their list on a failed refetch while the library was still
online (`tracks = []` in `TracksView`, `FavoritesView`, `ArtistView`,
`PlaylistView`). So an album opened during `.reconnecting` showed its tracks
from the snapshot, discovery succeeded, the task re-ran on the generation bump,
the fetch failed on the weak link, and the list emptied.

### 4. Connecting piles work onto the thin pipe

On `.signedIn` the model runs `resumeDownloads`, a full favorites refetch for
the pin and every pinned playlist's items, the root issues five fetches
including the multi-megabyte play history, and the player refills its prefetch
window. All of it competes with the one small request the user is waiting on.
A multiplier, not a cause. Not changed here.

### 5. Smaller

- `.reconnecting` shows no banner and doesn't dim the root (`MusicView.offline`
  keys on `.offline`), while the album page does dim rows (`library.isOffline`),
  so there is no telling the app is still looking for the server for up to
  ~35s.
- `checkConnection` on foreground only pings local addresses; a remote address
  on a weak link is left alone and each screen eats the full timeout.
- CarPlay and the Siri intents share the fetch-or-nothing shape.

What holds up: pinned files play locally in every state (`loadCurrentItem`
checks disk first), `Downloads.isAvailable` is a synchronous stat,
`OfflineLibrary` answers albums, artists, favorites and playlists from the
snapshot, and track lists are saved on browse and on pin. The pieces exist; the
wiring picked between them on one boolean.

## Changes (targeted, Oct 2026)

1. **The snapshot never writes a failed fetch.** `AppModel.snapshot` takes the
   favorites and the history as optionals; a nil keeps the last snapshot's
   value, and `setFavorites` is skipped entirely, so the pinned group is only
   ever reconciled against a list the server actually answered.
   `MusicView.load` keeps the previous favorites count on a failure too.
2. **A failed refetch leaves the list standing** in the four screens.
3. **The album page and the favorites read disk first.** `TracksView` seeds its
   list from the saved track list before asking the server, so a page opened on
   a weak link reads at once and the fetch replaces it when it lands.
   `FavoritesView` does the same from `AppModel.savedFavorites()`, and the
   shortcut card's `tracks(of: .favorites)` falls back to it when the server
   doesn't answer, so Shuffle Favorites plays what is on disk instead of
   reporting nothing.
4. **`PlexClient.apiSession` has a 60s resource timeout**, so a transfer that
   trickles fails and falls through to the saved copy rather than running for
   minutes.

## If it is still a problem

It was: the sketch below is built, as `notes/unified-library.md` (Oct 2026).

The real fix is to make every read local-first: a `CachedLibrary` in PlexKit
implementing `LibrarySource` over `OfflineStore` plus an optional
`PlexLibrary`, where each read returns what is saved and starts a coalesced
background fetch that saves on success and bumps a change counter, and the
server behind it is attached or detached by discovery. That removes the
`connectionLost` dance from every screen and the online/offline library swap
altogether, at the cost of splitting the snapshot into per-fetch files, a miss
path for anything never browsed, and a refresh policy that puts what is on
screen first. A day or two, against the hour the changes above took.
